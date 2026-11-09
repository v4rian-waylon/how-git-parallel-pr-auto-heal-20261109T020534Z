#!/usr/bin/env bash
# required.coverage.sh - push gate: the pushed head meets its test coverage.
#
# Usage:
#   .io.v4rian.how-git/ci/audits/push/required.coverage.sh       run the gate
#   .io.v4rian.how-git/ci/audits/push/required.coverage.sh -h|--help
# No arguments; run from inside the repo.
#
# How it runs:
#   ci-dispatch.yml runs every ci/audits/push/required.*.sh on each pushed
#   head SHA; the check posts under the file's basename minus .sh. The
#   required. prefix makes bin/bootstrap-ci bind it as a required status
#   check on PRs into dev. PRs reuse the push result for the head SHA; the
#   pr-open event does not rerun it. In off-grid mode bin/ci-local runs the
#   same scripts locally.
#
# Retry: delegates to scripts/workflows/audit-retry.sh --audit coverage, which
# retries only transient failures (exit 64, or a "RETRYABLE: <reason>" line on
# stderr) with 5 s doubling backoff capped at 300 s, MAX_ATTEMPTS (default 8).
# Any other non-zero exit fails fast on the first attempt.
#
# Recipe (scripts/audits/coverage.sh, picked by repo shape):
#   package.json with a test:coverage script: npm install, npm run test:coverage.
#   Node project without it, or a CMakeLists.txt repo: refuses with exit 2
#     until the consumer overrides audits/coverage.sh.
#   Framework source repo (FRAMEWORK_REPO marker present): runs
#     framework-tests/test-lifecycle.sh and test-hooks.sh as the proxy.
#   Anything else (no recognised project type): prints an "N/A coverage"
#     line and passes. A consumer never inherits the framework's own tests
#     as its coverage signal.
#
# Exit codes:
#   0  coverage met, or N/A (no recognised project type)
#   1  tests or the threshold failed
#   2  consumer must override audits/coverage.sh, or the recipe is missing
#   64 transient failure after every retry

set -uo pipefail

case "${1:-}" in
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac
exec bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/workflows/audit-retry.sh" --audit coverage
