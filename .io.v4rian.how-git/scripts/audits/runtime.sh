#!/usr/bin/env bash
# audits/runtime.sh - deterministic runtime boot verification for the
# pushed branch. Run by the sys-layer
# ci/audits/push/required.runtime.sh check of ci-dispatch.yml's push trigger
# (on demand: audit-pushed-branch.yml; off grid: bin/ci-local).
#
# Consumer projects override this script with their actual runtime smoke
# (boot the service, hit a health endpoint, scan for the expected init
# markers in the log). The template ships a placeholder that exits
# clean for content-only repos and defers to the consumer otherwise.
#
# Contract:
#   - Exit 0 when the service boots and prints its expected init markers.
#   - Exit non-zero when the boot crashes or the init markers are missing,
#     with the failing process's stderr surfaced in the workflow log.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
echo ">> runtime audit running in $REPO_ROOT"

if [ -f "$REPO_ROOT/package.json" ]; then
  # If a project has a runtime smoke script (start:smoke, runtime:check, etc.)
  # honor it. Otherwise demand a consumer override.
  for candidate in "runtime:check" "start:smoke" "smoke"; do
    if grep -q "\"$candidate\"" "$REPO_ROOT/package.json" 2>/dev/null; then
      echo ">> detected npm $candidate script; delegating"
      cd "$REPO_ROOT"
      npm install --silent --no-audit --no-fund
      npm run "$candidate"
      echo "PASS runtime ($candidate reported success)"
      exit 0
    fi
  done
  echo ">> Node project without a runtime smoke script; consumer must override audits/runtime.sh"
  exit 2
fi

if [ -f "$REPO_ROOT/CMakeLists.txt" ]; then
  echo ">> detected Qt or CMake project; consumer must override audits/runtime.sh"
  exit 2
fi

# Pure-template repo: nothing to boot. The closest runtime proxy is
# verifying that every shipped script is at least syntactically valid
# bash, which catches the script-level regressions the prior pre-push
# audits were also catching.
echo ">> walking every shipped script with bash -n as the runtime proxy"

# Enumerate via three single-purpose find invocations and a uniq pass so
# the precedence quirks of mixed -name + -o expressions cannot bite.
{
  find "$REPO_ROOT/.io.v4rian.how-git/scripts" -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null
  find "$REPO_ROOT/.io.v4rian.how-git/githooks" -type f \( -name '*.sh' -o ! -name '*.*' \) 2>/dev/null
  find "$REPO_ROOT/.io.v4rian.how-git/bin" -type f ! -name '*.*' 2>/dev/null
} | sort -u | while IFS= read -r script; do
  [ -x "$script" ] || continue
  # Only bash-syntax-check files whose shebang is a shell.
  head -n1 "$script" 2>/dev/null | grep -qE '^#!.*\b(ba)?sh\b' || continue
  bash -n "$script" 2>&1 || { echo "FAIL bash -n $script"; exit 1; }
done

echo "PASS runtime (every shipped shell script passes bash -n)"
exit 0
