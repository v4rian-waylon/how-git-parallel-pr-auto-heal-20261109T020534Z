#!/usr/bin/env bash
# audit-retry.sh - body of each audit-pushed-branch job's retry loop.
#
# Wraps a single audit script (compile / coverage / runtime / commit-audit)
# in an exponential-backoff retry loop. Same loop shape for every audit,
# so the jobs share one script instead of duplicating the bash. The audit
# script name is passed as --audit.
#
# Retry classification: not every non-zero rc is worth retrying. Test
# suites that ran to completion with assertions failing, syntax errors,
# panics, and consumer-side `consumer must override audits/X.sh` exits
# are deterministic - retrying them just burns minutes (8 attempts with
# 5/10/20/40/80/160/300/300 second backoff = ~15 minutes wasted on a
# failure that would never have flipped to green). Only transient
# failures (network blips, API rate limits, ephemeral resource pressure)
# benefit from retry.
#
# The wrapped audit script signals "this failure is worth retrying" in
# either of two equivalent ways:
#   (1) exit code 64 (RETRYABLE_EXIT_CODE), OR
#   (2) writing a line matching `^RETRYABLE:` to stderr (the wrapper
#       still expects a non-zero exit; the sentinel just classifies it
#       as transient).
# Anything else - any non-zero rc that is neither 64 nor accompanied by
# a RETRYABLE: stderr line - is treated as deterministic and fails fast
# on the first attempt.
#
# Exit code propagation: the wrapped audit's actual rc is captured
# directly via `bash cmd; rc=$?` (NOT via `if bash cmd; then exit 0; fi`
# which always reads rc=0 on the else branch - pool/n42's regression
# guard catches that pattern via the lifecycle suite).
#
# Usage:
#   audit-retry.sh --audit compile|coverage|runtime|commit-audit
#
# Environment:
#   MAX_ATTEMPTS  default 8
#   BASE_DELAY    default 5  (seconds; doubles per attempt)
#   MAX_DELAY     default 300 (cap on backoff)

set -uo pipefail

# Exit code sentinel for "this failure is transient; retry me". Chosen to
# avoid clashing with conventional bash exits (0 ok, 1 generic fail, 2
# misuse, 126 not executable, 127 not found, 128+N signal). 64 is in the
# sysexits.h "EX_USAGE" range and is unused by every audit we ship.
RETRYABLE_EXIT_CODE=64

AUDIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --audit) AUDIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "X audit-retry.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

if [ -z "$AUDIT" ]; then
  echo "X audit-retry.sh: --audit <name> is required" >&2
  exit 2
fi

case "$AUDIT" in
  compile|coverage|runtime|commit-audit) ;;
  *) echo "X audit-retry.sh: --audit must be compile, coverage, runtime, or commit-audit (got '$AUDIT')" >&2; exit 2 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
AUDIT_SCRIPT="$REPO_ROOT/.io.v4rian.how-git/scripts/audits/${AUDIT}.sh"
if [ ! -x "$AUDIT_SCRIPT" ]; then
  echo "X audit-retry.sh: audit script not found or not executable at $AUDIT_SCRIPT" >&2
  exit 2
fi

MAX_ATTEMPTS="${MAX_ATTEMPTS:-8}"
BASE_DELAY="${BASE_DELAY:-5}"
MAX_DELAY="${MAX_DELAY:-300}"
delay=$BASE_DELAY

# Per-attempt stderr capture so we can grep for the RETRYABLE: sentinel
# without rerouting stderr away from the workflow log. We `tee` stderr to
# both the original fd 2 (workflow log) and a per-run tmpfile that we
# scan after the attempt completes.
STDERR_CAPTURE=$(mktemp -t "audit-retry-stderr-XXXXXX")
trap 'rm -f "$STDERR_CAPTURE"' EXIT

is_retryable() {
  # rc=64 OR stderr contains a RETRYABLE: line => transient, retry.
  # Anything else => deterministic, fail fast.
  local rc="$1"
  local stderr_file="$2"
  if [ "$rc" -eq "$RETRYABLE_EXIT_CODE" ]; then
    return 0
  fi
  if [ -f "$stderr_file" ] && grep -q '^RETRYABLE:' "$stderr_file"; then
    return 0
  fi
  return 1
}

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "=== ${AUDIT} attempt $attempt of $MAX_ATTEMPTS ==="
  : > "$STDERR_CAPTURE"
  bash "$AUDIT_SCRIPT" 2> >(tee -a "$STDERR_CAPTURE" >&2)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    exit 0
  fi
  if ! is_retryable "$rc" "$STDERR_CAPTURE"; then
    echo "${AUDIT} failed with deterministic rc=$rc on attempt $attempt; not retrying (use exit $RETRYABLE_EXIT_CODE or write 'RETRYABLE: <reason>' to stderr to mark a failure transient)"
    exit "$rc"
  fi
  if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
    echo "${AUDIT} failed transiently after $MAX_ATTEMPTS attempts (last rc=$rc)"
    exit "$rc"
  fi
  echo "${AUDIT} attempt $attempt failed transiently (rc=$rc); sleeping ${delay}s before retry"
  sleep "$delay"
  delay=$(( delay * 2 ))
  if [ "$delay" -gt "$MAX_DELAY" ]; then delay=$MAX_DELAY; fi
done
