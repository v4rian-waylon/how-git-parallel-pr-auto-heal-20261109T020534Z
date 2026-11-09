#!/usr/bin/env bash
# claim-retry.sh — body of the in-workflow retry loop wrapping the
# canonical claim script (claim-dev-merge.sh or claim-main-release.sh).
#
# Same shape for both targets so claim-on-merge-dev.yml and
# claim-on-merge-main.yml share one body. The claim script is
# idempotent (tag-exists check prevents double-tagging on re-run) so
# every attempt is safe.
#
# Exit code propagation: the wrapped claim's actual rc is captured
# directly via `bash cmd; rc=$?` (NOT via `if bash cmd; then exit 0; fi`
# which always reads rc=0 on the else branch — see pool/n42).
#
# Usage:
#   claim-retry.sh --target dev|main
#
# Environment:
#   MAX_ATTEMPTS  default 8
#   BASE_DELAY    default 5  (seconds; doubles per attempt)
#   MAX_DELAY     default 300 (cap on backoff)

set -uo pipefail

TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "X claim-retry.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

case "$TARGET" in
  dev)  CLAIM_SCRIPT="claim-dev-merge.sh" ;;
  main) CLAIM_SCRIPT="claim-main-release.sh" ;;
  *) echo "X claim-retry.sh: --target must be dev or main (got '$TARGET')" >&2; exit 2 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CLAIM_PATH="$REPO_ROOT/.io.v4rian.how-git/scripts/$CLAIM_SCRIPT"
if [ ! -x "$CLAIM_PATH" ]; then
  echo "X claim-retry.sh: claim script not found or not executable at $CLAIM_PATH" >&2
  exit 2
fi

MAX_ATTEMPTS="${MAX_ATTEMPTS:-8}"
BASE_DELAY="${BASE_DELAY:-5}"
MAX_DELAY="${MAX_DELAY:-300}"
attempt=1
delay=$BASE_DELAY

while : ; do
  echo "→ claim attempt $attempt of $MAX_ATTEMPTS (target=$TARGET)"
  bash "$CLAIM_PATH" --skip-pull
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "✓ claim succeeded on attempt $attempt"
    exit 0
  fi
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "✗ claim failed on final attempt $attempt (exit $rc); giving up" >&2
    exit "$rc"
  fi
  echo "→ attempt $attempt failed (exit $rc); sleeping ${delay}s before retry"
  sleep "$delay"
  attempt=$((attempt + 1))
  delay=$((delay * 2))
  [ "$delay" -gt "$MAX_DELAY" ] && delay=$MAX_DELAY
done
