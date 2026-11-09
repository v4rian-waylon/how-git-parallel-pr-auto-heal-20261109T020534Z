#!/usr/bin/env bash
# offline-test.sh - body of the offline-test workflow's lifecycle job.
#
# Default mode runs the framework's own internal test suites (lifecycle +
# hooks) when this repo is the framework source (detected via the
# FRAMEWORK_REPO marker file). On a consumer repo that has adopted the
# framework, the marker is absent and the suites SHOULD NOT run - those
# tests verify the framework's own machinery, not the consumer's project.
#
# The marker file gate is the single source of truth for "is this the
# framework's home repo?" Read it here, check it in audit scripts that
# fall through to framework-internal recipes, drop it via bootstrap-ci
# consumer-cleanup, restore it on the framework source. No other source
# of truth, no environment variable, no remote-URL guess. This
# self-detection is what the default (no-flag) path preserves exactly.
#
# --throwaway mode reproduces the ENTIRE suite on an external throwaway
# repo - the consumer main use case - as a fully independent sandbox. It
# creates a real throwaway repo under the resolved token's account,
# pushes the CURRENT local tree to its main, clones it, and runs the
# plain suite FROM that clone. The clone resolves its own TEMPLATE_ROOT,
# origin, and workflows, so the run exercises only the tooling installed
# in the throwaway and never reaches back into this repo's CI, scripts,
# or origin. The throwaway's own Actions are disabled so the run costs no
# Actions minutes. Operator / pre-release use; NOT wired to per-push CI.
#
# Usage:
#   offline-test.sh                  default: marker-gated in-place suites
#   offline-test.sh --throwaway      full suite on an external throwaway repo
#   offline-test.sh --throwaway --keep      leave the throwaway alive
#   offline-test.sh --throwaway --dry-run   print the plan; no network
#
# Exit codes:
#   0  marker absent (consumer mode) -> skip is clean
#   0  marker present + both suites green
#   0  --throwaway with no resolvable token -> clean skip (never red)
#   non-zero  any suite red, or a throwaway provisioning step failed
#
# Environment:
#   LIFECYCLE_TEST_MODE  passed through to the suites so the claude/gh
#                        mocks engage; defaults to 1 in throwaway mode.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
NS=".io.v4rian.how-git"

THROWAWAY=false
KEEP=false
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --throwaway) THROWAWAY=true; shift ;;
    --keep)      KEEP=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    *) echo "X offline-test: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

run_in_place_suites() {
  local marker="$REPO_ROOT/$NS/FRAMEWORK_REPO"
  if [ ! -f "$marker" ]; then
    echo "=> offline-test: FRAMEWORK_REPO marker not present; this repo consumes the framework but does not host its tests. Skipping."
    exit 0
  fi

  echo "=> offline-test: FRAMEWORK_REPO marker present; running framework-internal suites"

  echo "=> running lifecycle suite"
  bash "$REPO_ROOT/$NS/framework-tests/test-lifecycle.sh"
  local lifecycle_rc=$?

  echo "=> running hooks suite"
  bash "$REPO_ROOT/$NS/framework-tests/test-hooks.sh"
  local hooks_rc=$?

  echo "=> running agent-hooks suite"
  bash "$REPO_ROOT/$NS/framework-tests/test-agent-hooks.sh"
  local agent_rc=$?

  if [ "$lifecycle_rc" -ne 0 ] || [ "$hooks_rc" -ne 0 ] || [ "$agent_rc" -ne 0 ]; then
    echo "=> offline-test: lifecycle_rc=$lifecycle_rc hooks_rc=$hooks_rc agent_rc=$agent_rc; a suite failed"
    exit 1
  fi

  echo "=> offline-test: both framework suites green"
  exit 0
}

run_throwaway_suite() {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/$NS/scripts/_throwaway_lib.sh"

  local name
  name=$(throwaway_default_name "howgit-suite-e2e")

  if $DRY_RUN; then
    echo "=> offline-test --throwaway (dry-run): planned steps, no network calls"
    echo "   1. resolve a GitHub token (GH_TOKEN / CREATE_POOL_BRANCH_TOKEN / gh auth / GCM store)"
    echo "   2. create an empty private throwaway '$name' under the token's account"
    echo "   3. disable Actions on the throwaway (no Actions-minutes spend)"
    echo "   4. push the current local HEAD to the throwaway's main"
    echo "   5. clone the throwaway and run the plain suite FROM the clone"
    echo "      (clone self-detects FRAMEWORK_REPO; its own TEMPLATE_ROOT / origin / workflows are the targets)"
    echo "   6. best-effort delete the throwaway (needs delete_repo scope) unless --keep"
    echo "=> offline-test --throwaway (dry-run): plan only; exiting 0"
    exit 0
  fi

  throwaway_check_deps

  local token
  if ! token=$(throwaway_resolve_token); then
    echo "=> offline-test --throwaway: no GitHub token resolvable (GH_TOKEN / CREATE_POOL_BRANCH_TOKEN / gh auth / GCM store all empty). Clean skip."
    exit 0
  fi

  local account
  account=$(curl -sS -H "Authorization: token $token" "https://api.github.com/user" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('login',''))" 2>/dev/null || true)
  if [ -z "$account" ]; then
    echo "=> offline-test --throwaway: token does not authenticate to /user. Clean skip."
    exit 0
  fi
  echo "=> offline-test --throwaway: provisioning '$account/$name'"

  if ! throwaway_create_empty "$token" "$name" >/dev/null; then
    echo "X offline-test --throwaway: could not create the throwaway repo" >&2
    exit 1
  fi

  local auth_url="https://x-access-token:$token@github.com/$account/$name.git"

  # Disable Actions on the throwaway so its workflows do not fire (and do
  # not spend Actions minutes) when we push the framework tree. The
  # sandbox suite runs locally in the clone, not via the throwaway's CI.
  curl -sS -o /dev/null -X PUT \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d '{"enabled":false}' \
    "https://api.github.com/repos/$account/$name/actions/permissions" || true

  local teardown_done=false
  teardown() {
    $teardown_done && return 0
    teardown_done=true
    if $KEEP; then
      echo "=> offline-test --throwaway: --keep set; leaving https://github.com/$account/$name alive"
      return 0
    fi
    local code
    code=$(throwaway_delete "$token" "$account" "$name")
    if [ "$code" = "204" ]; then
      echo "=> offline-test --throwaway: deleted throwaway $account/$name"
    else
      echo "=> offline-test --throwaway: could not delete $account/$name (HTTP $code; token may lack delete_repo scope) - delete it manually" >&2
    fi
  }
  trap teardown EXIT

  # Push the CURRENT local tree (this branch's HEAD) to the throwaway's
  # main so the sandbox carries exactly what we are validating, WITHOUT
  # pushing to this repo's own origin.
  if ! git push -q "$auth_url" HEAD:refs/heads/main; then
    echo "X offline-test --throwaway: failed to push the local tree to the throwaway main" >&2
    exit 1
  fi

  local td repo
  td=$(mktemp -d -t howgit-throwaway-XXXXXX)
  repo="$td/repo"
  if ! throwaway_clone_with_retry "$auth_url" "$repo" >/dev/null; then
    echo "X offline-test --throwaway: throwaway clone never populated" >&2
    rm -rf "$td"
    exit 1
  fi

  echo "=> offline-test --throwaway: running the full suite FROM the sandbox clone"
  local rc=0
  ( cd "$repo" && LIFECYCLE_TEST_MODE="${LIFECYCLE_TEST_MODE:-1}" \
      bash "$NS/scripts/workflows/offline-test.sh" ) || rc=$?

  rm -rf "$td"

  if [ "$rc" -ne 0 ]; then
    echo "=> offline-test --throwaway: sandbox suite FAILED (rc=$rc)"
    exit "$rc"
  fi
  echo "=> offline-test --throwaway: sandbox suite GREEN on the external throwaway"
  exit 0
}

if $THROWAWAY; then
  run_throwaway_suite
else
  run_in_place_suites
fi
