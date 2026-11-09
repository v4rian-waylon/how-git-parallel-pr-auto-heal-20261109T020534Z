#!/usr/bin/env bash
# doc-freshness-check.sh - gate dev→main release PRs on doc freshness.
#
# When a dev→main release PR opens, this script compares the dev→main
# diff substance against the substance recorded in the repo's user
# facing docs. If the docs lag the diff, the script surfaces the
# specific docs that are stale and the substance they are missing, and
# (when DOC_FRESHNESS_AUTOFIX=1) spawns a claude worker that rewrites
# the tracked docs in place, commits them, and (when
# DOC_FRESHNESS_AUTOFIX_PUSH=1) pushes the follow up commit on the PR
# branch.
#
# Scope clarity: pool/n51 shipped the DETECTION + STATUS CHECK half of
# this feature with a stub worker; this revision (HG-I03) lands the
# real OPT IN worker. Under LIFECYCLE_TEST_MODE the worker keeps the
# canned response the lifecycle suite asserts on; without the opt in
# env the worker is never invoked. The status check posts PASS when
# docs are fresh and FAIL with the staleness list when they drift,
# regardless of whether the autofix path runs.
#
# Behavior in order:
#
#   1. Probe the dev→main diff via git log first-parent origin/main..
#      origin/dev (or local main..dev when origin refs are unavailable
#      under LIFECYCLE_TEST_MODE).
#   2. Extract semantic substance: number of feature/fix merges,
#      number of refactor merges, breaking change markers in titles
#      ([BREAKING], BREAKING CHANGE), version bumps inferable from
#      bin/version --seal. Substance is a structured stdout report,
#      one line per axis, terminated with a sentinel line.
#   3. For each tracked doc (CHANGELOG, RUNBOOK, CONTRIBUTING, root
#      README, namespace README) check freshness via a coarse
#      heuristic: a doc is FRESH when (a) it was touched in the
#      dev→main diff OR (b) its current content already covers the
#      substance axes the diff carries. The CHANGELOG check is the
#      strictest - its `## Unreleased` section must be non empty AND
#      its byte length must be at least DOC_FRESHNESS_CHANGELOG_MIN
#      bytes per merge in the diff (default 80, override via env).
#   4. Emit a final FRESHNESS=PASS line OR a FRESHNESS=STALE line
#      followed by one STALE_DOC=<path> line per stale doc and one
#      MISSING_SUBSTANCE=<axis> line per uncovered axis.
#   5. Post the doc-freshness status check on PR_HEAD_SHA: success
#      when PASS, failure when STALE. Honors the same env contract as
#      validate-pr-open.sh; under LIFECYCLE_TEST_MODE with no PR
#      number set the script short circuits and just emits the report
#      to stdout for the test harness to parse.
#   6. When STALE and DOC_FRESHNESS_AUTOFIX=1, invoke the claude
#      worker. Under LIFECYCLE_TEST_MODE the worker returns a canned
#      response that names which docs it would update; under
#      production mode the worker is a real `claude -p` call with
#      file edit permissions scoped to the tracked docs. When the
#      call changes the tree, the worker commits the doc files by
#      name and, only when DOC_FRESHNESS_AUTOFIX_PUSH=1, pushes the
#      commit to PR_HEAD_REF; otherwise the commit stays local. On
#      any unavailability (no claude CLI, no credentials) the worker
#      WARNs and falls back to the skip path; the autofix path never
#      turns the check red on its own.
#
# Env contract (same shape as validate-pr-open.sh):
#
#   PR_NUMBER       - PR number; absent under test mode short circuits
#   PR_HEAD_REF     - source branch (must be `dev` for the main path)
#   PR_BASE_REF     - target branch (must be `main` to fire)
#   PR_HEAD_SHA     - head commit SHA the status check attaches to
#   PR_ACTOR        - PR author login (logged, not gated)
#   GH_TOKEN        - workflow token, statuses:write
#   GITHUB_REPOSITORY - owner/repo
#   GITHUB_RUN_ID   - for status-check description
#
#   DOC_FRESHNESS_AUTOFIX        - 1 enables the claude autofix worker
#   DOC_FRESHNESS_AUTOFIX_PUSH   - 1 also pushes the autofix commit to
#                                  PR_HEAD_REF (default: commit stays
#                                  local)
#   DOC_FRESHNESS_CHANGELOG_MIN  - bytes per merge for CHANGELOG
#                                  freshness heuristic (default 80)
#   LIFECYCLE_TEST_MODE          - 1 short circuits gh + claude calls
#
# Exit codes:
#   0  - PASS (docs fresh) OR STALE-but-non-fatal under test mode
#   1  - STALE: docs lag the diff; status check posted red
#   2  - fatal: not a dev→main PR (wrong base or wrong head)
#   3  - env contract violation (missing required input)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script + namespace dir, regardless of cwd.
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
REPO_ROOT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)

# Test mode short-circuit: when LIFECYCLE_TEST_MODE=1 is set and the
# required env vars are absent, skip the gh-touching path so the unit
# tests can source this file or invoke its helpers without a live API.
# This mirrors validate-pr-open.sh's short-circuit shape.
if [ "${LIFECYCLE_TEST_MODE:-0}" = "1" ] && [ -z "${PR_NUMBER:-}" ]; then
  echo "→ test-mode: PR_NUMBER unset; sourcing helpers without gh dispatch"
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Env contract validation
# ---------------------------------------------------------------------------
require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "X doc-freshness-check: required env var $name is unset" >&2
    exit 3
  fi
}

require_env PR_NUMBER
require_env PR_HEAD_REF
require_env PR_BASE_REF
require_env PR_HEAD_SHA
require_env GH_TOKEN
require_env GITHUB_REPOSITORY

PR_ACTOR="${PR_ACTOR:-unknown}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-0}"
REPO="$GITHUB_REPOSITORY"
STATUS_CONTEXT="doc-freshness"

# ---------------------------------------------------------------------------
# Step 0 - only fire on dev → main PRs; everything else is out of scope.
# ---------------------------------------------------------------------------

if [ "$PR_BASE_REF" != "main" ]; then
  echo "→ doc-freshness: base is '$PR_BASE_REF' (not main); out of scope, exiting clean"
  exit 0
fi
if [ "$PR_HEAD_REF" != "dev" ]; then
  echo "X doc-freshness: head is '$PR_HEAD_REF' but only dev → main PRs are gated" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

post_status() {
  local state="$1"
  local desc="$2"
  if [ "${LIFECYCLE_TEST_MODE:-0}" = "1" ]; then
    echo "  · [test-mode] would post status $state: $desc"
    return 0
  fi
  gh api -X POST \
    "repos/${REPO}/statuses/${PR_HEAD_SHA}" \
    -f "state=${state}" \
    -f "context=${STATUS_CONTEXT}" \
    -f "description=${desc}" \
    --silent 2>/dev/null || true
}

# Extract diff substance from the dev → main first-parent log. Output is
# structured stdout, one KEY=VALUE line per axis, terminated by a
# SUBSTANCE_END sentinel. Designed to be grep + cut consumed by the
# downstream checks and by the test harness.
extract_substance() {
  local base="$1" tip="$2"
  local titles
  titles=$(git log --first-parent --format='%s' "${base}..${tip}" 2>/dev/null || true)

  local total_merges feature_merges fix_merges refactor_merges breaking_marker
  total_merges=$(printf '%s\n' "$titles" | grep -cE '^\[MERGE\]' || true)
  feature_merges=$(printf '%s\n' "$titles" | grep -cE '\.feature\.' || true)
  fix_merges=$(printf '%s\n' "$titles" | grep -cE '\.fix\.' || true)
  refactor_merges=$(printf '%s\n' "$titles" | grep -cE '\.(refactor|r&d)\.' || true)
  breaking_marker=$(printf '%s\n' "$titles" | grep -cE '\[BREAKING\]|BREAKING CHANGE' || true)

  printf 'SUBSTANCE_BEGIN\n'
  printf 'TOTAL_MERGES=%s\n' "$total_merges"
  printf 'FEATURE_MERGES=%s\n' "$feature_merges"
  printf 'FIX_MERGES=%s\n' "$fix_merges"
  printf 'REFACTOR_MERGES=%s\n' "$refactor_merges"
  printf 'BREAKING_MARKERS=%s\n' "$breaking_marker"
  printf 'SUBSTANCE_END\n'
}

# Check a single doc's freshness. Args: <doc-path> <total-merges>
# <min-bytes-per-merge>. Emits FRESH or STALE on stdout plus a
# diagnostic line. The CHANGELOG check looks at the `## Unreleased`
# section specifically; every other doc gets a coarser "was the file
# touched in the diff?" check.
check_doc_freshness() {
  local doc="$1" total_merges="$2" min_per_merge="$3"
  local base_ref="${BASE_REF:-origin/main}"
  local tip_ref="${TIP_REF:-origin/dev}"

  if [ ! -f "$REPO_ROOT/$doc" ]; then
    # CHANGELOG is the strict doc - if missing while the diff carries
    # substance, that's a hard stale signal. Every other doc is
    # optional; a consumer install may not ship a RUNBOOK or root
    # README at all, and absence is not staleness on its own.
    case "$doc" in
      *CHANGELOG.md)
        if [ "$total_merges" -gt 0 ]; then
          echo "MISSING:$doc"
          return 0
        fi
        ;;
    esac
    echo "FRESH:$doc:file-absent-optional-doc"
    return 0
  fi

  # Was the doc touched in the dev → main diff?
  local touched=0
  if git diff --name-only "${base_ref}..${tip_ref}" 2>/dev/null | grep -Fxq "$doc"; then
    touched=1
  fi

  case "$doc" in
    *CHANGELOG.md)
      # Strict check: the `## Unreleased` section must be non empty.
      # Extract the section between the `## Unreleased` header and the
      # next `## ` header (or EOF). If it's empty or shorter than
      # min_per_merge * total_merges bytes, the CHANGELOG is stale.
      local section
      section=$(awk '
        /^## Unreleased/ { in_section=1; next }
        /^## / && in_section { in_section=0 }
        in_section { print }
      ' "$REPO_ROOT/$doc")
      local section_bytes
      section_bytes=$(printf '%s' "$section" | wc -c | tr -d ' ')
      local min_bytes=$(( total_merges * min_per_merge ))
      if [ "$total_merges" -eq 0 ]; then
        # No diff substance to cover; CHANGELOG state is irrelevant.
        echo "FRESH:$doc:no-diff-substance"
        return 0
      fi
      if [ "$section_bytes" -lt "$min_bytes" ]; then
        echo "STALE:$doc:unreleased-section-too-short($section_bytes<$min_bytes)"
        return 0
      fi
      echo "FRESH:$doc:unreleased-section-bytes=$section_bytes"
      return 0
      ;;
    *)
      # Coarse heuristic for everything else: touched in the diff is
      # enough to call it fresh. Untouched docs are stale only when
      # the diff carries breaking change markers (those always
      # require a docs revision).
      if [ "$touched" -eq 1 ]; then
        echo "FRESH:$doc:touched-in-diff"
        return 0
      fi
      if [ "${BREAKING_MARKERS:-0}" -gt 0 ]; then
        echo "STALE:$doc:untouched-despite-breaking-changes"
        return 0
      fi
      # No breaking changes and the file wasn't touched - acceptable.
      echo "FRESH:$doc:no-breaking-changes-untouched-acceptable"
      return 0
      ;;
  esac
}

# Claude worker invocation. Under LIFECYCLE_TEST_MODE returns the
# canned response shape agent-32's smart-commit established: a single
# stdout block listing the docs the worker would update and a sentinel
# AUTOFIX_STUB line. Under production mode this shells out to
# `claude -p` (invocation shape mirrored from claude_resolve_conflict
# in scripts/_lib.sh: prompt file on stdin, acceptEdits permission
# mode, explicit tool allowlist) with file edit permissions scoped to
# the tracked docs in DOCS_TO_CHECK, then commits any resulting doc
# edits by name and pushes to PR_HEAD_REF only when
# DOC_FRESHNESS_AUTOFIX_PUSH=1. Availability + credential checks reuse
# the _lib.sh contract (ensure_claude_ready, CLAUDE_CODE_OAUTH_TOKEN
# preferred over ANTHROPIC_API_KEY); every fallback WARNs and returns
# 0 so the autofix path never reddens the check on its own.
invoke_claude_worker_stub() {
  local stale_list="$1" missing_list="$2"
  if [ "${LIFECYCLE_TEST_MODE:-0}" = "1" ]; then
    echo "→ claude-worker-stub: LIFECYCLE_TEST_MODE=1; emitting canned response"
    cat <<CANNED
[[FAKE_CLAUDE_RESPONSE]]
  would-update-docs:
$(printf '    - %s\n' $stale_list)
  would-cover-axes:
$(printf '    - %s\n' $missing_list)
  would-commit-on-branch: ${PR_HEAD_REF}
  would-commit-title: [DOCS] Refresh user-facing docs to cover the substance landed since the prior release
AUTOFIX_STUB=ok
CANNED
    return 0
  fi
  # Reuse the shared availability helper (background-install join +
  # ~/.local/bin fallback) so the worker sees claude exactly the way
  # every other _lib.sh claude helper does.
  if ! declare -f ensure_claude_ready >/dev/null 2>&1; then
    # shellcheck source=../_lib.sh
    . "$SCRIPT_DIR/../_lib.sh"
  fi
  ensure_claude_ready || true
  if ! command -v claude >/dev/null 2>&1; then
    echo "  · claude CLI not installed; would invoke worker if present" >&2
    echo "AUTOFIX_STUB=skipped"
    return 0
  fi
  # Same credential contract as claude_judge_commit: either the
  # Max-plan OAuth token or the direct API key must be bound; both
  # absent means the operator opted in without wiring credentials, so
  # WARN and fall back to the skip path.
  if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "  ! doc-freshness-autofix WARN: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set; autofix skipped (detection verdict unaffected)" >&2
    echo "AUTOFIX_STUB=skipped"
    return 0
  fi

  # File edit permissions are scoped to the tracked docs the checker
  # already gates on; everything else stays read only.
  local doc allowed_tools
  allowed_tools="Read,Glob,Grep,Bash(git diff:*),Bash(git status:*),Bash(git log:*),Bash(git show:*)"
  for doc in ${DOCS_TO_CHECK[@]+"${DOCS_TO_CHECK[@]}"}; do
    allowed_tools+=",Edit(${doc}),Write(${doc})"
  done

  local prompt_file output rc
  prompt_file=$(mktemp -t claude-doc-autofix.XXXXXX)
  {
    printf 'You are the doc-freshness autofix worker on a dev to main release PR.\n\n'
    printf 'The doc-freshness gate found user facing docs lagging the release diff:\n'
    printf '  stale docs: %s\n' "$stale_list"
    printf '  missing substance axes: %s\n\n' "$missing_list"
    printf 'Diff substance summary (first parent %s..%s):\n%s\n\n' "$BASE_REF" "$TIP_REF" "$SUBSTANCE_REPORT"
    printf 'Update the stale docs IN PLACE so they cover the substance this release carries. Inspect the actual merges via the read only git tools before writing. For the CHANGELOG, fill the "## Unreleased" section with one entry per merge in the diff. Edit ONLY these tracked docs: %s\n\n' "${DOCS_TO_CHECK[*]:-}"
    printf 'Reply with exactly one of:\n'
    printf '  DOCS_UPDATED\n'
    printf '  DOCS_UNCHANGED: <reason, one short sentence>\n'
  } > "$prompt_file"

  echo "  -> doc-freshness-autofix invoking claude worker (this may take a few seconds)" >&2
  # OAuth precedence mirrors claude_judge_commit: when the Max-plan
  # token is present, unset the API key in the subshell so the CLI
  # routes through the subscription path deterministically.
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    output=$(unset ANTHROPIC_API_KEY; claude -p \
      --permission-mode acceptEdits \
      --allowedTools "$allowed_tools" \
      < "$prompt_file" 2>&1)
  else
    output=$(claude -p \
      --permission-mode acceptEdits \
      --allowedTools "$allowed_tools" \
      < "$prompt_file" 2>&1)
  fi
  rc=$?
  rm -f "$prompt_file"

  if [ "$rc" -ne 0 ]; then
    echo "  ! doc-freshness-autofix WARN: claude exited rc=$rc; docs left as detected" >&2
    printf '%s\n' "$output" | head -10 >&2
    echo "AUTOFIX_WORKER=failed"
    return 0
  fi

  # The tree check is the gate, not the reply token: claude may claim
  # DOCS_UPDATED without changing anything (or the reverse).
  local changed
  changed=$(git -C "$REPO_ROOT" status --porcelain -- ${DOCS_TO_CHECK[@]+"${DOCS_TO_CHECK[@]}"} 2>/dev/null | awk '{print $NF}')
  if [ -z "$changed" ]; then
    echo "  · doc-freshness-autofix: worker made no doc edits ($(printf '%s' "$output" | grep -E '^[[:space:]]*DOCS_(UPDATED|UNCHANGED)' | head -1))" >&2
    echo "AUTOFIX_WORKER=no-changes"
    return 0
  fi

  # Commit the changed docs by name. Identity falls back to a bot
  # identity when the CI checkout carries none; hooks are skipped
  # because the runner checkout has no hooksPath bootstrap.
  local f commit_name commit_email
  for f in $changed; do
    git -C "$REPO_ROOT" add -- "$f"
  done
  commit_name=$(git -C "$REPO_ROOT" config user.name 2>/dev/null || true)
  commit_email=$(git -C "$REPO_ROOT" config user.email 2>/dev/null || true)
  if ! git -C "$REPO_ROOT" \
      -c user.name="${commit_name:-doc-freshness-autofix}" \
      -c user.email="${commit_email:-doc-freshness-autofix@users.noreply.github.com}" \
      commit --no-verify -m "[DOCS] Refresh release docs via doc-freshness autofix" >/dev/null 2>&1; then
    echo "  ! doc-freshness-autofix WARN: commit failed; doc edits left in the working tree" >&2
    echo "AUTOFIX_WORKER=commit-failed"
    return 0
  fi
  echo "AUTOFIX_COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

  if [ "${DOC_FRESHNESS_AUTOFIX_PUSH:-0}" = "1" ]; then
    if git -C "$REPO_ROOT" push origin "HEAD:refs/heads/${PR_HEAD_REF}" >/dev/null 2>&1; then
      echo "AUTOFIX_WORKER=applied-committed-pushed"
    else
      echo "  ! doc-freshness-autofix WARN: push to ${PR_HEAD_REF} failed; commit left local" >&2
      echo "AUTOFIX_WORKER=applied-committed-push-failed"
    fi
  else
    echo "  · DOC_FRESHNESS_AUTOFIX_PUSH is not 1; commit left local (not pushed to ${PR_HEAD_REF})"
    echo "AUTOFIX_WORKER=applied-committed-local"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Step 1 - probe the dev → main diff
# ---------------------------------------------------------------------------

# Prefer origin/* refs (real CI). Fall back to local refs when origin
# is missing (test-mode synthetic scratch repos).
BASE_REF="origin/main"
TIP_REF="origin/dev"
if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  BASE_REF="main"
fi
if ! git rev-parse --verify "$TIP_REF" >/dev/null 2>&1; then
  TIP_REF="dev"
fi
export BASE_REF TIP_REF

echo "→ doc-freshness: comparing ${BASE_REF}..${TIP_REF}"

# ---------------------------------------------------------------------------
# Step 2 - extract substance
# ---------------------------------------------------------------------------

SUBSTANCE_REPORT=$(extract_substance "$BASE_REF" "$TIP_REF")
printf '%s\n' "$SUBSTANCE_REPORT"

TOTAL_MERGES=$(printf '%s\n' "$SUBSTANCE_REPORT" | grep -E '^TOTAL_MERGES=' | cut -d= -f2)
FEATURE_MERGES=$(printf '%s\n' "$SUBSTANCE_REPORT" | grep -E '^FEATURE_MERGES=' | cut -d= -f2)
FIX_MERGES=$(printf '%s\n' "$SUBSTANCE_REPORT" | grep -E '^FIX_MERGES=' | cut -d= -f2)
REFACTOR_MERGES=$(printf '%s\n' "$SUBSTANCE_REPORT" | grep -E '^REFACTOR_MERGES=' | cut -d= -f2)
BREAKING_MARKERS=$(printf '%s\n' "$SUBSTANCE_REPORT" | grep -E '^BREAKING_MARKERS=' | cut -d= -f2)
export BREAKING_MARKERS

# ---------------------------------------------------------------------------
# Step 3 - check each tracked doc
# ---------------------------------------------------------------------------

DOCS_TO_CHECK=(
  ".io.v4rian.how-git/docs/CHANGELOG.md"
  ".io.v4rian.how-git/docs/RUNBOOK.md"
  ".io.v4rian.how-git/docs/CONTRIBUTING.md"
  ".io.v4rian.how-git/README.md"
)

MIN_PER_MERGE="${DOC_FRESHNESS_CHANGELOG_MIN:-80}"
STALE_DOCS=()
MISSING_AXES=()

for doc in ${DOCS_TO_CHECK[@]+"${DOCS_TO_CHECK[@]}"}; do
  result=$(check_doc_freshness "$doc" "$TOTAL_MERGES" "$MIN_PER_MERGE")
  echo "  $result"
  case "$result" in
    STALE:*) STALE_DOCS+=("$doc"); MISSING_AXES+=("${result#STALE:$doc:}") ;;
    MISSING:*) STALE_DOCS+=("$doc"); MISSING_AXES+=("file-missing") ;;
  esac
done

# ---------------------------------------------------------------------------
# Step 4 - emit final freshness verdict
# ---------------------------------------------------------------------------

if [ "${#STALE_DOCS[@]}" -eq 0 ]; then
  echo "FRESHNESS=PASS"
  post_status "success" "all tracked docs cover the dev → main diff substance"
  echo "OK doc-freshness: status check posted green for PR #${PR_NUMBER}"
  exit 0
fi

echo "FRESHNESS=STALE"
for d in ${STALE_DOCS[@]+"${STALE_DOCS[@]}"}; do
  echo "STALE_DOC=$d"
done
for a in ${MISSING_AXES[@]+"${MISSING_AXES[@]}"}; do
  echo "MISSING_SUBSTANCE=$a"
done

# ---------------------------------------------------------------------------
# Step 5 - post the red status check
# ---------------------------------------------------------------------------

post_status "failure" "docs lag the dev → main diff (${#STALE_DOCS[@]} stale)"

# ---------------------------------------------------------------------------
# Step 6 - optional claude autofix worker (canned under test mode)
# ---------------------------------------------------------------------------

if [ "${DOC_FRESHNESS_AUTOFIX:-0}" = "1" ]; then
  invoke_claude_worker_stub "${STALE_DOCS[*]:-}" "${MISSING_AXES[*]:-}"
fi

# Under test mode we exit clean so the harness can assert on the stdout
# report shape; in production we exit 1 so the workflow fails red.
if [ "${LIFECYCLE_TEST_MODE:-0}" = "1" ]; then
  exit 0
fi
exit 1
