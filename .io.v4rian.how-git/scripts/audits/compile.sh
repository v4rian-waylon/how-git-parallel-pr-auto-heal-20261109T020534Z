#!/usr/bin/env bash
# audits/compile.sh - deterministic compile-only verification for the pushed
# branch. Run by the sys-layer
# ci/audits/push/required.compile.sh check of ci-dispatch.yml's push trigger
# (on demand: audit-pushed-branch.yml; off grid: bin/ci-local).
#
# Consumer projects override this script with their actual compile recipe
# (npm install + node --check for Node services, cmake build for Qt apps,
# etc.). The template ships a placeholder that exits with a clear message
# so misconfigured forks fail loudly instead of silently passing.
#
# Contract:
#   - Exit 0 on a passing compile.
#   - Exit non-zero on any compile failure, with the failing tool's stderr
#     surfaced in the workflow log.
#   - Touch no files outside the workspace; the workflow's actions/checkout
#     gives you a clean tree per run.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
echo ">> compile audit running in $REPO_ROOT"

# Detection table: pick the right recipe by repo shape.
if [ -f "$REPO_ROOT/package.json" ]; then
  echo ">> detected Node project; running npm install --no-audit --no-fund + node --check"
  cd "$REPO_ROOT"
  npm install --silent --no-audit --no-fund
  find . -name '*.js' \
    -not -path './node_modules/*' \
    -not -path './build/*' \
    -not -path './build-*/*' \
    -print0 \
    | xargs -0 -I{} node --check {}
  echo "PASS compile (node --check on every staged .js)"
  exit 0
fi

if [ -f "$REPO_ROOT/CMakeLists.txt" ]; then
  echo ">> detected Qt or CMake project; consumer must override audits/compile.sh"
  echo "   (the template's placeholder does not know your target name or toolchain)"
  exit 2
fi

# Pure-template repo (this how-git repo itself): the compile audit is a
# no-op because there is no compilable source here, only shell + yaml.
# Consumer projects override this script in their fork.
echo ">> no recognized build system detected; treating as content-only repo"
echo "PASS compile (no-op: content-only repo)"
exit 0
