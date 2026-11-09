#!/usr/bin/env bash
# required.build.sh - tag gate: builds the v* tag's release artifacts and
# proves they ship clean and run.
#
# Usage:
#   .io.v4rian.how-git/ci/audits/tag/required.build.sh            run the gate
#   .io.v4rian.how-git/ci/audits/tag/required.build.sh -h|--help
# No arguments. TAG defaults to GITHUB_REF_NAME (the v* tag on the
# ci-dispatch tag trigger); set TAG to run it by hand.
#
# Steps, in one job because build/artifacts/ exists only in this workspace:
#   1. scripts/workflows/build-retry.sh runs scripts/build.sh in an
#      eight-attempt backoff envelope; output lands in build/artifacts/.
#      BUILD_IDEMPOTENCY_CHECK=1 short-circuits an already-built tag.
#   2. scripts/workflows/release-artifact-audit.sh refuses debug output
#      (*.dSYM, *.pdb, *.debug, -debug/_debug names, *.map next to .js,
#      debugger; statements), plus a claude judgment layer that WARNs when
#      claude is unavailable.
#   3. scripts/release-test.sh proves the artifacts run (consumers override
#      it with their launch or --help smoke) and reports Mach-O minos floors.
# Distribution (GitHub Release, promotion) is not this gate's job. Same code
# is the same version and the same artifact: built once at the dev tag and
# reused at main promotion without a rebuild.
#
# Environment: GITHUB_TOKEN with contents:read is enough.
#
# Exit codes:
#   0  built, audited clean, run test passed
#   1  a helper script is missing, or a step failed (the failing step's own
#      exit code is propagated)

set -uo pipefail

case "${1:-}" in
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RETRY="$REPO_ROOT/.io.v4rian.how-git/scripts/workflows/build-retry.sh"

if [ ! -x "$RETRY" ]; then
  echo "X required.build: build-retry.sh missing or not executable at $RETRY" >&2
  exit 1
fi

# build-retry.sh requires TAG (the v* ref being built) for its summary block.
# On the ci-dispatch tag trigger the ref name IS the tag, so derive it here.
# This replaces the resolve-step output the legacy build-on-tag.yml provided;
# without it build-retry.sh aborts immediately on every real tag build.
export TAG="${TAG:-${GITHUB_REF_NAME:-${GITHUB_REF#refs/tags/}}}"

# The post-build gates run in THIS job because build/artifacts/ only exists
# in the build job's workspace (matrix siblings check out clean). Order:
# build -> release artifact audit (no debug output ships) -> release test
# (the artifacts run as intended).
bash "$RETRY" || exit $?

AUDIT="$REPO_ROOT/.io.v4rian.how-git/scripts/workflows/release-artifact-audit.sh"
if [ ! -x "$AUDIT" ]; then
  echo "X required.build: release-artifact-audit.sh missing or not executable at $AUDIT" >&2
  exit 1
fi
bash "$AUDIT" || exit $?

RELEASE_TEST="$REPO_ROOT/.io.v4rian.how-git/scripts/release-test.sh"
if [ ! -x "$RELEASE_TEST" ]; then
  echo "X required.build: release-test.sh missing or not executable at $RELEASE_TEST" >&2
  exit 1
fi
exec bash "$RELEASE_TEST"
