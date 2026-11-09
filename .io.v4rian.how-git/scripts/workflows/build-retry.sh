#!/usr/bin/env bash
# build-retry.sh - body of build-on-tag.yml's "Run build.sh with
# exponential backoff retry" step. Same retry shape as the audit jobs;
# additionally writes a success block to GITHUB_STEP_SUMMARY when the
# build clears.
#
# Exit code propagation: separate `bash cmd; rc=$?` (see pool/n42 for
# the regression guard against `if bash cmd; then ...; fi; rc=$?`).
#
# Environment:
#   TAG                   the v* tag being built (for the summary block)
#   GITHUB_STEP_SUMMARY   workflow-provided file for the per-step summary
#   MAX_ATTEMPTS          default 8
#   BASE_DELAY            default 5  (seconds; doubles per attempt)
#   MAX_DELAY             default 300 (cap on backoff)
#
# Exports to build.sh:
#   BUILD_TYPE=release    every v* tag build is a release-type compile.
#                         The release ceremony reuses the dev tag's artifact
#                         at main promotion (same code = same version = same
#                         artifact, no rebuild), so the tag build is the only
#                         point where release configuration is enforceable:
#                         debug code and debug builds are banned from
#                         build/artifacts/ and rejected downstream by the
#                         release artifact audit.

set -uo pipefail

: "${TAG:?TAG is required (set from the resolve step output)}"

export BUILD_TYPE="${BUILD_TYPE:-release}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BUILD_SCRIPT="$REPO_ROOT/.io.v4rian.how-git/scripts/build.sh"
if [ ! -x "$BUILD_SCRIPT" ]; then
  echo "X build-retry.sh: build.sh not found or not executable at $BUILD_SCRIPT" >&2
  exit 2
fi

MAX_ATTEMPTS="${MAX_ATTEMPTS:-8}"
BASE_DELAY="${BASE_DELAY:-5}"
MAX_DELAY="${MAX_DELAY:-300}"
delay=$BASE_DELAY

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "=== build attempt $attempt of $MAX_ATTEMPTS ==="
  bash "$BUILD_SCRIPT"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        echo "## build-on-tag (success)"
        echo ""
        echo "Tag \`$TAG\` built on attempt $attempt. Artifacts under \`build/artifacts/\` for the distribution bundle to pick up."
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
    echo "build failed after $MAX_ATTEMPTS attempts (last rc=$rc)"
    exit "$rc"
  fi
  echo "build attempt $attempt failed (rc=$rc); sleeping ${delay}s before retry"
  sleep "$delay"
  delay=$(( delay * 2 ))
  if [ "$delay" -gt "$MAX_DELAY" ]; then delay=$MAX_DELAY; fi
done
