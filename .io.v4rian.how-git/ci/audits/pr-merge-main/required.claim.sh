#!/usr/bin/env bash
# required.claim.sh (pr-merge-main) - claims a dev merge into main (release).
#
# MUTATES THE REMOTE: run only from the CI trigger after a dev to main PR
# merged, or by an admin repeating a failed claim. Never as a probe.
#
# Usage:
#   .io.v4rian.how-git/ci/audits/pr-merge-main/required.claim.sh  run the claim
#   .io.v4rian.how-git/ci/audits/pr-merge-main/required.claim.sh -h|--help
#
# What it does (scripts/claim-main-release.sh): amends the merge commit,
# force-pushes main with lease keeping the merger's identity, promotes the
# dev tag to the main release (same code, same version, no new tag) and
# archives the merged dev state. Safety/* anchors stay forever.
#
# Environment (set by ci-dispatch.yml): CI_TRIGGER, CI_LAYER=sys,
# CI_KIND=audits, CI_CHECK_NAME=required.claim, and a GITHUB_TOKEN with
# contents:write for the force-push and tag push. A consumer shadows this
# script by shipping its own usr-layer ci/audits/pr-merge-main/claim.sh.
#
# Retry: delegates to scripts/workflows/claim-retry.sh --target main, which
# retries with 5 s doubling backoff capped at 300 s, MAX_ATTEMPTS (default
# 8). The claim is idempotent (an existing tag is never re-created), so
# every attempt is safe.
#
# Exit codes:
#   0  claimed (or already claimed)
#   1  claim-retry.sh is missing
#   2  the claim script is missing
#   N  the claim's own exit code after the last failed attempt

set -uo pipefail

case "${1:-}" in
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RETRY="$REPO_ROOT/.io.v4rian.how-git/scripts/workflows/claim-retry.sh"

if [ ! -x "$RETRY" ]; then
  echo "X required.claim: claim-retry.sh missing or not executable at $RETRY" >&2
  exit 1
fi

exec bash "$RETRY" --target main
