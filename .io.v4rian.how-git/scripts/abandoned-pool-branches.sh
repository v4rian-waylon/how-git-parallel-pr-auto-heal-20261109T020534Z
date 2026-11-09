#!/usr/bin/env bash
# abandoned-pool-branches.sh - enumerate pool branches that look abandoned.
#
# READ-ONLY institutional-memory reporter. Walks origin's pool/v*/n*.*
# refs (the v4rian Pattern-1 working-branch shape), classifies each one
# via _lib.sh::classify_pool_branch, and prints the candidates as either
# a markdown table or a JSON array. NEVER deletes anything; never
# mutates anything; never touches safety/, vault/, or main/dev refs.
# The operator reads the report and decides what to do with each branch.
#
# Per feedback_safety_anchors_stay_forever, safety anchors stay forever
# regardless of whether their paired pool branch was released, is in
# flight, or was abandoned. This reporter mirrors that policy: the
# safety anchor is the institutional record of where the pool was
# allocated, so the reporter uses the anchor's commit date as the
# canonical allocation timestamp but never proposes deleting it. Only
# the pool branch itself is the subject of any operator decision, and
# even then the decision (archive, hand off, drop) is the operator's
# alone - this script does not act.
#
# Excludes:
#   - Reconcile sub-branches (pool/v*/nN.reconcile.* and the older
#     pool/v*/nN.*.reconcile.* shape). Reconciles are auto-cut by the
#     auto-rebase ladder when dev advances under an open pool PR; they
#     are receipts of the rebase event, not original work. The original
#     branch carries the abandonment signal; the reconcile is downstream.
#   - Pool tips reachable from origin/main (already released).
#   - Pool branches with at least one merged PR (semantically shipped
#     even when the squash-merged SHA is no longer reachable).
#   - Branches already vaulted on origin (vault/* refs are scanned and
#     their suffix is matched against the pool name; a vaulted pool
#     never appears in the report).
#
# Output modes:
#   --table (default)  human-readable markdown table.
#   --json             JSON array of objects with the same fields.
#
# Other flags:
#   --days N           abandonment threshold in days; default 30. A pool
#                      with a more recent commit than N days is classified
#                      as "fresh" and excluded.
#   --include-non-candidate
#                      include "fresh", "active", and "merged" rows in the
#                      output so the operator can see why each branch was
#                      excluded. Useful for diagnosing classification
#                      decisions; the default is candidates only because
#                      the report is meant to drive follow-up, not audit.
#   --repo OWNER/REPO  override the auto-resolved owner/repo (default:
#                      derived from `git config --get remote.origin.url`).
#   -h | --help        show this header and exit.
#
# Usage:
#   .io.v4rian.how-git/bin/abandoned-pool-branches
#   .io.v4rian.how-git/bin/abandoned-pool-branches --days 7
#   .io.v4rian.how-git/bin/abandoned-pool-branches --json
#   .io.v4rian.how-git/bin/abandoned-pool-branches --json --days 90
#
# Exit codes:
#   0  report emitted successfully (regardless of whether any candidates
#      were found; an empty report is a healthy state, not a failure).
#   2  bad CLI input.
#   3  missing dependency (gh required for PR state lookups).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_lib.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MODE="table"
DAYS=30
INCLUDE_NON_CANDIDATE=false
OWNER_REPO=""

usage() {
  sed -n '2,68p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --table)                   MODE="table"; shift ;;
    --json)                    MODE="json"; shift ;;
    --days)                    DAYS="${2:-}"; shift 2 ;;
    --include-non-candidate)   INCLUDE_NON_CANDIDATE=true; shift ;;
    --repo)                    OWNER_REPO="${2:-}"; shift 2 ;;
    -h|--help)                 usage 0 ;;
    *) echo "X abandoned-pool-branches: unknown flag: $1" >&2; usage 2 ;;
  esac
done

case "$DAYS" in
  ''|*[!0-9]*) echo "X abandoned-pool-branches: --days expects a positive integer; got: '$DAYS'" >&2; exit 2 ;;
esac

# gh is the only hard dependency. The reporter still emits a table when
# gh is missing - the classifier degrades the PR state to "none" - but
# that defeats the point of the report (the PR probe is the strongest
# signal). Refuse rather than silently mis-classify.
if ! ensure_dep gh; then
  exit 3
fi

# ---------------------------------------------------------------------------
# Resolve repo coordinates
# ---------------------------------------------------------------------------
if [ -z "$OWNER_REPO" ]; then
  REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
  OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
fi
if [ -z "$OWNER_REPO" ]; then
  precondition_banner "abandoned-pool-branches" \
    "Cannot resolve owner/repo from origin URL." \
    "Pass --repo OWNER/REPO explicitly, or set the origin remote:" \
    "  git remote set-url origin <url>"
  exit 2
fi

# Refresh origin's view of refs before classifying. The report is about
# what's on origin, not what happens to be cached locally; without this
# fetch a recently-vaulted pool would still appear as a candidate.
# GIT_TERMINAL_PROMPT=0 prevents the fetch from blocking on a credential
# prompt when the operator's git config has no cached credential helper
# for the origin URL; rather than hang the report indefinitely we let
# the fetch fail silently and continue with the locally cached view.
GIT_TERMINAL_PROMPT=0 git fetch --prune --no-tags origin >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Enumerate vaulted suffixes so vaulted-but-still-named-pool refs (rare,
# transient between the vault push and the pool delete) are excluded.
# vault/* refs use the same nN.kind.short suffix as their original pool,
# under either vault/vYYYY.MAIN/<suffix> or the legacy flat vault/<suffix>
# layout. Scanning once up front lets the per-branch classify call stay
# O(1) instead of running a vault-membership probe per pool.
# ---------------------------------------------------------------------------
VAULTED_SUFFIXES=$(git for-each-ref refs/remotes/origin/vault/ --format='%(refname:short)' 2>/dev/null \
  | sed -E 's|^origin/vault/||; s|^v[0-9]{4}\.[0-9]+/||' \
  | sort -u || true)

is_vaulted() {
  local pool_name="$1"
  # pool/v2026.0/nN.kind.short -> nN.kind.short for matching against the
  # vault suffix set. Drop the optional vMAJOR/ prefix to support both
  # the layered pool/v2026.0/nN.* shape and the legacy flat pool/nN.*.
  local suffix="${pool_name#pool/}"
  case "$suffix" in
    v[0-9]*) suffix="${suffix#*/}" ;;
  esac
  if [ -z "$VAULTED_SUFFIXES" ]; then
    return 1
  fi
  printf '%s\n' "$VAULTED_SUFFIXES" | grep -qFx "$suffix"
}

# ---------------------------------------------------------------------------
# Enumerate pool branches on origin
# ---------------------------------------------------------------------------
# Two patterns cover the v4rian layout: the layered pool/v2026.0/nN.*
# shape (post-n51) and the legacy flat pool/nN.* shape (pre-n51).
POOL_REFS=$(git for-each-ref \
  --format='%(refname:short)' \
  'refs/remotes/origin/pool/v*/n*.*' \
  'refs/remotes/origin/pool/n*.*' \
  2>/dev/null \
  | sed -E 's|^origin/||' \
  | sort -u || true)

# ---------------------------------------------------------------------------
# Walk and classify; accumulate rows for the chosen output mode.
#
# INSPECTED counts every pool ref the classifier actually scored (post the
# reconcile-suffix and vault-suffix exclusions). CANDIDATES counts the
# subset whose verdict was "candidate". The header reports both so the
# operator can see how many pools were considered vs how many landed in
# the report.
# ---------------------------------------------------------------------------
ROWS_TSV=""
INSPECTED=0
CANDIDATES=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  # Skip reconcile sub-branches; they are auto-rebase receipts, not
  # original work.
  case "$ref" in
    pool/*reconcile*) continue ;;
  esac
  # Skip already-vaulted branches.
  if is_vaulted "$ref"; then
    continue
  fi
  row=$(classify_pool_branch "$ref" "$DAYS" "$OWNER_REPO" || true)
  [ -n "$row" ] || continue
  INSPECTED=$((INSPECTED + 1))
  classification=$(printf '%s' "$row" | cut -f2)
  if [ "$classification" = "candidate" ]; then
    CANDIDATES=$((CANDIDATES + 1))
  fi
  if [ "$INCLUDE_NON_CANDIDATE" = false ] && [ "$classification" != "candidate" ]; then
    continue
  fi
  if [ -z "$ROWS_TSV" ]; then
    ROWS_TSV="$row"
  else
    ROWS_TSV="$ROWS_TSV
$row"
  fi
done <<EOF
$POOL_REFS
EOF

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
if [ "$MODE" = "json" ]; then
  # Build the JSON via python3 (already required by other framework
  # scripts; avoids hand-rolled escaping for the reason text which may
  # contain quotes). No external jq dependency: python3 is on the
  # ensure_dep allowlist via stdlib presence on every supported platform.
  printf '%s\n' "$ROWS_TSV" \
    | python3 - "$OWNER_REPO" "$DAYS" "$INSPECTED" "$CANDIDATES" <<'PY'
import json, sys
owner_repo = sys.argv[1]
threshold_days = int(sys.argv[2])
inspected = int(sys.argv[3])
candidate_count = int(sys.argv[4])
rows = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) != 7:
        continue
    rows.append({
        "branch": parts[0],
        "classification": parts[1],
        "alloc_date": parts[2],
        "last_commit": parts[3],
        "last_pr_state": parts[4],
        "owner": parts[5],
        "reason": parts[6],
    })
out = {
    "repo": owner_repo,
    "threshold_days": threshold_days,
    "inspected": inspected,
    "candidate_count": candidate_count,
    "rows": rows,
}
print(json.dumps(out, indent=2, sort_keys=False))
PY
  exit 0
fi

# Markdown table mode (default).
printf '# Abandoned pool-branch report\n\n'
printf 'Repo: `%s`\n' "$OWNER_REPO"
printf 'Threshold: last commit older than %s days\n' "$DAYS"
printf 'Candidates: %s of %s pool refs inspected\n\n' "$CANDIDATES" "$INSPECTED"
if [ -z "$ROWS_TSV" ]; then
  printf '_No rows; either no pool branches on origin, or every pool branch was excluded by the classifier (reconcile sub-branches, vaulted, reachable from main, merged via PR, or fresher than the threshold)._\n'
  exit 0
fi
printf '| branch | class | alloc | last commit | last PR | owner | reason |\n'
printf '|---|---|---|---|---|---|---|\n'
printf '%s\n' "$ROWS_TSV" | awk -F'\t' '{ printf("| %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7) }'
exit 0
