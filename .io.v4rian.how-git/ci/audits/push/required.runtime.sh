#!/usr/bin/env bash
# required.runtime.sh - push gate: the pushed head boots.
#
# Usage:
#   .io.v4rian.how-git/ci/audits/push/required.runtime.sh        run the gate
#   .io.v4rian.how-git/ci/audits/push/required.runtime.sh -h|--help
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
# Retry: delegates to scripts/workflows/audit-retry.sh --audit runtime, which
# retries only transient failures (exit 64, or a "RETRYABLE: <reason>" line on
# stderr) with 5 s doubling backoff capped at 300 s, MAX_ATTEMPTS (default 8).
# Any other non-zero exit fails fast on the first attempt.
#
# Recipe (scripts/audits/runtime.sh, picked by repo shape):
#   package.json with a runtime:check, start:smoke or smoke npm script (first
#     found): npm install --silent --no-audit --no-fund && npm run <script>.
#     Node project without one: refuses with exit 2 (override required).
#   CMakeLists.txt: refuses with exit 2 until the consumer overrides
#     audits/runtime.sh.
#   Neither: bash -n over every executable shell script in scripts/,
#     githooks/ and bin/ of the framework.
# Override recipes by repo type (the boot check a consumer writes):
#   Node service: node <entry> in the background, wait ~5 s, fail if the
#     process died, kill it, then require the declared init markers in its log.
#   Node CLI, Go CLI, Rust binary: run <bin> --help; exit 0 with usage printed.
#   Qt app (macOS): open build/<X>.app, sleep 3, pgrep -f <X> must find it,
#     then pkill -KILL -f <X>. Qt app (Linux): ./build/<X> &, sleep 3, alive.
#   Static libs and Rust libs: no runtime step; compile is the gate.
#   Go or Python service: start it, wait ~4 s, require the listen line.
# Pass rule when no markers are declared: the process stays alive for the
# window and no Error, EADDRINUSE, ENOMODULE, ImportError, Traceback, panic:,
# Segmentation fault or Killed line appears. Tolerable markers (declare them
# in the workspace CLAUDE.md): missing Application Default Credentials,
# invalid_grant / invalid_rapt, Connection refused or ENOTFOUND for
# downstream services absent from the check environment.
#
# Exit codes:
#   0  boot passed (or bash -n proxy passed)
#   1  boot crashed, markers missing, or a script failed bash -n
#   2  consumer must override audits/runtime.sh, or the recipe is missing
#   64 transient failure after every retry

set -uo pipefail

case "${1:-}" in
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac
exec bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/workflows/audit-retry.sh" --audit runtime
