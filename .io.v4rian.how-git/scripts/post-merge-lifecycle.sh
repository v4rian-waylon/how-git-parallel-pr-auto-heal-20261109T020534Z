#!/usr/bin/env bash
# post-merge-lifecycle.sh - complete the ruleset protected lifecycle
# transitions locally, under the admin operator's own gh session.
#
# The merge triggered claim (CI) amends the merge subject and places the
# dev tag, but the workflow GITHUB_TOKEN holds no ruleset bypass, so the
# protected transitions - vault/* creation, pool/* deletion at archive,
# pool/*.reconcile.* candidate publication - cannot land from CI unless
# the optional CI bot App token is configured. This tool is the
# framework's answer: the ADMIN runs it from their shell, the pushes ride
# the operator's own credentials (the gh session OAuth resolved by git's
# credential helper - never a token input, never a stored secret), and
# the admin clears the rulesets through the RepositoryRole and
# OrganizationAdmin bypass.
#
# What it does, in order:
#   1. Verifies the operator holds admin permission on origin (the same
#      probe bin/lockdown uses). Non-admins are refused before any push.
#   2. Archives every pool/* branch whose tip is already merged into
#      origin/dev and whose vault/* twin does not exist yet (the exact
#      rename the claim's archive step could not land from CI), via
#      archive-pool-branch.sh.
#   3. Runs the auto-rebase reconcile pass (auto-rebase-pools-after-dev-
#      merge.sh) so every open pool PR gets its reconcile candidate
#      published - the candidate branches now actually land on origin.
#
# Usage:
#   post-merge-lifecycle.sh             run the full pass
#   post-merge-lifecycle.sh --dry-run   report what would happen, push nothing
#   post-merge-lifecycle.sh --skip-reconcile   archive only (no L1-L5 ladder)
#   post-merge-lifecycle.sh -h | --help
#
# Refuses in off-grid mode (bin/finalize-pool-merge closes up there) and
# for a non-admin operator (only admins bypass the rulesets it pushes past).
#
# Exit codes:
#   0  pass complete (or --dry-run report printed, or help)
#   1  at least one archive or the reconcile pass failed (see output)
#   2  not a git repo, unknown flag, off-grid mode, gh CLI missing, owner
#      or repo not derivable from origin, or operator is not an admin

# --help works anywhere and before _lib.sh or the repo check run.
for _arg in "$@"; do
  case "$_arg" in -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"
REPO_ROOT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "X post-merge-lifecycle.sh: not inside a git repo" >&2
  exit 2
fi
cd "$REPO_ROOT"

DRY_RUN=false
SKIP_RECONCILE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)        DRY_RUN=true; shift ;;
    --skip-reconcile) SKIP_RECONCILE=true; shift ;;
    -h|--help)        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "X unknown flag: $1" >&2; exit 2 ;;
  esac
done

MODE_VAL=$(get_mode 2>/dev/null || echo "connected")
if [ "$MODE_VAL" = "off-grid" ]; then
  echo "X post-merge-lifecycle: off-grid repos close up via bin/finalize-pool-merge; this tool is connected mode only" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "X post-merge-lifecycle: gh CLI required (admin verification + PR comments)" >&2
  exit 2
fi

OWNER_REPO=$(git config --get remote.origin.url 2>/dev/null \
  | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
if [ -z "$OWNER_REPO" ]; then
  echo "X post-merge-lifecycle: cannot derive owner/repo from origin" >&2
  exit 2
fi

# Admin gate: the whole point of this tool is to exercise the admin's
# ruleset bypass; a non-admin run would push straight into rejections.
ACTOR=$(gh api /user --jq .login 2>/dev/null || true)
PERM=$(gh api "/repos/$OWNER_REPO/collaborators/$ACTOR/permission" --jq .permission 2>/dev/null || echo unknown)
if [ "$PERM" != "admin" ]; then
  echo "X post-merge-lifecycle: actor '${ACTOR:-unknown}' has permission '$PERM' on $OWNER_REPO; admin required" >&2
  exit 2
fi
echo "-> post-merge-lifecycle on $OWNER_REPO (actor: $ACTOR, admin)"

git fetch origin --quiet --prune

# ---- step 2: archive merged-but-unvaulted pools ----------------------------
ARCHIVED=0
FAILED=0
while IFS= read -r ref; do
  pool="${ref#refs/heads/}"
  case "$pool" in pool/*.reconcile.*) continue ;; esac
  tip=$(git ls-remote origin "refs/heads/$pool" | cut -f1)
  [ -n "$tip" ] || continue
  if ! git merge-base --is-ancestor "$tip" origin/dev 2>/dev/null; then
    continue
  fi
  vault="vault/${pool#pool/}"
  if git ls-remote --heads origin "$vault" | grep -q .; then
    continue
  fi
  if $DRY_RUN; then
    echo "  [dry-run] would archive $pool -> $vault"
    continue
  fi
  echo "-> archiving merged pool $pool"
  if bash "$SCRIPT_DIR/archive-pool-branch.sh" "$pool"; then
    ARCHIVED=$((ARCHIVED + 1))
  else
    echo "  X archive failed for $pool" >&2
    FAILED=$((FAILED + 1))
  fi
done < <(git ls-remote --heads origin "pool/*" | awk '{print $2}')
echo "-> archive pass: $ARCHIVED archived, $FAILED failed"

# ---- step 3: reconcile pass -------------------------------------------------
if $SKIP_RECONCILE; then
  echo "-> reconcile pass skipped (--skip-reconcile)"
elif $DRY_RUN; then
  echo "  [dry-run] would run auto-rebase-pools-after-dev-merge.sh"
else
  git checkout --quiet "$(git rev-parse origin/dev)" 2>/dev/null || true
  bash "$SCRIPT_DIR/auto-rebase-pools-after-dev-merge.sh" || {
    echo "  X reconcile pass reported failure; see output above" >&2
    FAILED=$((FAILED + 1))
  }
  git checkout --quiet - 2>/dev/null || true
fi

if [ "$FAILED" -gt 0 ]; then
  echo "X post-merge-lifecycle finished with $FAILED failure(s)" >&2
  exit 1
fi
echo "ok post-merge-lifecycle complete"
