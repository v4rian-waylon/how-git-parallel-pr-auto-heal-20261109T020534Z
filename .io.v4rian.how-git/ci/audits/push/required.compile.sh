#!/usr/bin/env bash
# required.compile.sh - push gate: the pushed head compiles.
#
# Usage:
#   .io.v4rian.how-git/ci/audits/push/required.compile.sh        run the gate
#   .io.v4rian.how-git/ci/audits/push/required.compile.sh -h|--help
# No arguments; run from inside the repo (the recipe resolves the repo root
# with git rev-parse --show-toplevel).
#
# How it runs:
#   ci-dispatch.yml runs every ci/audits/push/required.*.sh on each pushed
#   head SHA; the check posts under the file's basename minus .sh. The
#   required. prefix makes bin/bootstrap-ci bind it as a required status
#   check on PRs into dev. PRs reuse the push result for the head SHA; the
#   pr-open event does not rerun it. In off-grid mode bin/ci-local runs the
#   same scripts locally.
#
# Retry: delegates to scripts/workflows/audit-retry.sh --audit compile, which
# retries only transient failures (exit 64, or a "RETRYABLE: <reason>" line on
# stderr) with 5 s doubling backoff capped at 300 s, MAX_ATTEMPTS (default 8).
# Any other non-zero exit fails fast on the first attempt.
#
# Recipe (scripts/audits/compile.sh, picked by repo shape):
#   package.json present (Node):
#     npm install --silent --no-audit --no-fund
#     find . -name '*.js' -not -path './node_modules/*' -not -path './build/*' \
#       -not -path './build-*/*' -print0 | xargs -0 -I{} node --check {}
#     Pass: install resolves the lock file and every .js parses.
#   CMakeLists.txt present (Qt or CMake): refuses with exit 2 until the
#     consumer overrides audits/compile.sh, because the template cannot know
#     the target or toolchain. The override recipe:
#       Qt static lib: cmake -S . -B build -G Ninja && cmake --build build --parallel;
#         pass when build/lib<Name>.a (and any QML plugin lib) exists.
#       Qt app: the same build with every add_subdirectory(../<lib>) repo
#         cloned at its adjacent path, each lib at the latest preflight dated
#         on or before the app revision; pass when build/<Name>.app exists.
#       Only the cmake --build exit code decides; warnings are not failures.
#   Neither: content-only repo (this framework), passes as a no-op.
# Never skip npm install because node_modules exists: the install is what
# proves the lock file is consistent.
#
# Exit codes:
#   0  compile passed (or content-only no-op)
#   1  a compile step failed (the failing tool's stderr is in the log)
#   2  consumer must override audits/compile.sh (CMake repo), or the recipe
#      script is missing
#   64 transient failure after every retry

set -uo pipefail

case "${1:-}" in
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac
exec bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/workflows/audit-retry.sh" --audit compile
