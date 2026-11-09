#!/usr/bin/env bash
# heal.sh - restore the template's expected state when something has drifted.
#
# Not a first-time-install requirement. The template works out of the box -
# in-repo scripts auto-activate hooks on first run, VERSION is lazily inited,
# git preserves executable bits. heal.sh is for REPAIR:
#
#   - core.hooksPath has drifted (overwritten by another tool or another repo
#     config edit) → reasserts .io.v4rian.how-git/githooks.
#   - a hook or script lost its executable bit (rare, but possible if a tool
#     copied files without preserving mode, or a tarball was extracted without
#     -p) → re-chmods all the executables shipped by the template.
#
# heal.sh DOES NOT touch VERSION anymore. Tags are the canonical version
# state; there is no live VERSION file at repo root. For runtime/build
# identifiers on unmerged work, use `.io.v4rian.how-git/bin/version`.
#
# Idempotent and safe to run repeatedly. Surfaces what it changed and what
# was already correct.
#
# Usage:
#   heal.sh                 do the heal
#   heal.sh --dry-run       show what would be changed, no mutations
#   heal.sh -h | --help     print this help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS_DIR=$(basename "$(dirname "$SCRIPT_DIR")")
REPO_ROOT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "✗ heal.sh: not inside a git repo" >&2
  exit 2
fi

DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    -h|--help)   sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done

run() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    eval "$@"
  fi
}

cd "$REPO_ROOT"

# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# --- core.hooksPath -------------------------------------------------------
EXPECTED_HOOKS="$NS_DIR/githooks"
CURRENT_HOOKS=$(git config core.hooksPath 2>/dev/null || true)
if [ "$CURRENT_HOOKS" = "$EXPECTED_HOOKS" ]; then
  echo "  ✓ core.hooksPath = $EXPECTED_HOOKS (no drift)"
else
  echo "  → core.hooksPath = [${CURRENT_HOOKS:-unset}], correcting to $EXPECTED_HOOKS"
  run "git config core.hooksPath $EXPECTED_HOOKS"
fi

# --- fallback post-merge (claims a merge made while core.hooksPath is unset)
if [ -z "$(merge_hook_fallback_issue)" ]; then
  echo "  ✓ fallback post-merge in place (or a consumer hook owns the slot)"
else
  echo "  → installing the fallback post-merge in the default hooks dir"
  run "ensure_merge_hook_fallback"
fi

# --- legacy requirement lanes ----------------------------------------------
# Lanes allocated before per-lane requirement files carry the shared
# active-requirement and collide on it when they merge into dev. heal never
# rewrites a branch; it names them and the one command that migrates them.
LEGACY_LANES=$(hg_legacy_requirement_lanes | tr '\n' ' ')
if [ -n "$(printf '%s' "$LEGACY_LANES" | tr -d ' ')" ]; then
  echo "  → legacy shared active-requirement on: $LEGACY_LANES"
  echo "    migrate them (one commit per lane, nothing pushed): bash $NS_DIR/scripts/migrate-active-requirement.sh"
else
  echo "  ✓ no lane carries the legacy shared active-requirement"
fi

# --- executable bits ------------------------------------------------------
EXECUTABLES=(
  "$NS_DIR/githooks/pre-push"
  "$NS_DIR/githooks/post-checkout"
  "$NS_DIR/githooks/commit-msg"
  "$NS_DIR/scripts/apply-repo-rules.sh"
  "$NS_DIR/scripts/build.sh"
  "$NS_DIR/scripts/distribute-internal.sh"
  "$NS_DIR/scripts/distribute-public.sh"
  "$NS_DIR/scripts/open-pr.sh"
  "$NS_DIR/scripts/verify-template.sh"
  "$NS_DIR/scripts/claim-dev-merge.sh"
  "$NS_DIR/scripts/claim-main-release.sh"
  "$NS_DIR/scripts/heal.sh"
  "$NS_DIR/scripts/migrate-active-requirement.sh"
  "$NS_DIR/scripts/allocate-pool-branch.sh"
  "$NS_DIR/bin/create-pool-branch"
  "$NS_DIR/bin/version"
  "$NS_DIR/bin/status"
  "$NS_DIR/bin/ship"
  "$NS_DIR/bin/release-of"
  "$NS_DIR/bin/doctor"
  "$NS_DIR/bin/queue"
  "$NS_DIR/bin/changelog"
  "$NS_DIR/bin/preview-merge"
  "$NS_DIR/bin/bootstrap-ci"
  "$NS_DIR/framework-tests/test-hooks.sh"
)
chmod_fail=0
for f in ${EXECUTABLES[@]+"${EXECUTABLES[@]}"}; do
  if [ ! -e "$f" ]; then
    echo "  ⚠ $f: not present (expected to ship with the template)"
    continue
  fi
  if [ -x "$f" ]; then
    echo "  ✓ $f executable"
  else
    echo "  → $f not executable, chmod +x"
    run "chmod +x $f" || chmod_fail=1
  fi
done
[ $chmod_fail -eq 0 ] || { echo "✗ chmod failed on one or more files" >&2; exit 1; }

# --- VERSION file presence guard -----------------------------------------
# Tags are the canonical version state. If a stray VERSION file is left at
# repo root (e.g. from a pre-redesign checkout), surface it so the user can
# clean it up. heal does not delete it automatically - destructive ops on
# user-authored files require an explicit confirmation, not a heal step.
if [ -f VERSION ]; then
  echo "  ⚠ a VERSION file is present at repo root."
  echo "    Tags are the canonical version state in this model; VERSION is no"
  echo "    longer tracked. If this file was left over from a pre-redesign"
  echo "    checkout, delete it: rm VERSION"
else
  echo "  ✓ no live VERSION file (canonical version lives in tags)"
fi

echo ""
echo "✓ heal complete"
