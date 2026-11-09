#!/usr/bin/env bash
# distribute-internal.sh - ship a built artifact to the INTERNAL channel.
#
# ============================================================================
# DESIGN DOC (read before editing this file or its consumer override)
# ============================================================================
#
# Purpose
#   The internal channel is for the team and trusted beta testers, not the
#   end user public. Every v* tag flows through here (both dev pre-release
#   tags like v2026.0.7-b.3 and main release tags like v2026.0.7) so the
#   people building the product can hold the exact bits that the build job
#   produced before any of them are promoted to the public channel. Typical
#   destinations: TestFlight, internal Docker registry, npm dist-tag dev,
#   private S3 bucket, internal artifact store.
#
# Triggers
#   Called by the distribution bundle (a workflow that runs AFTER
#   build-on-tag has placed artifacts at the contract path). The build half
#   of the lifecycle is intentionally distribution-free; build-on-tag.yml
#   must NOT invoke this script (the lifecycle test suite enforces that).
#   Internal distribution fires on EVERY v* tag - pre-release AND release -
#   because the internal channel always wants the latest bits regardless of
#   public promotion state.
#
# Inputs
#   $TAG         tag name being distributed (e.g. v2026.0.7 or v2026.0.7-b.3)
#   $CHANNEL     channel label ("internal"); reserved for future fan-out
#   ./out/       artifact directory populated by build.sh (canonical path
#                is build/artifacts/; the distribution bundle stages it as
#                ./out/ before invoking this script for parity with
#                distribute-public.sh)
#   credentials  whatever the consumer's destination needs (TestFlight API
#                key, registry token, S3 access key) - read from secrets
#                via env vars set by the calling workflow, NEVER from a
#                file in the repo
#
# Outputs
#   Side-effect upload to the internal destination. No files written back
#   into the repo. Exit 0 on success, non-zero on failure (the workflow's
#   retry shape catches transient failures; persistent failures surface to
#   the operator).
#
# Design tips
#   - IDEMPOTENT BY TAG. Re-running this script for an already-distributed
#     $TAG must be a no-op (or a clearly logged "already there"). Internal
#     destinations vary in how they enforce this; pick one:
#       * TestFlight: query existing builds, skip if $TAG already uploaded
#       * Docker: skip if `docker manifest inspect registry/app:$TAG` exists
#       * S3: skip if `aws s3api head-object` returns 200 for the target key
#     Never blindly overwrite - a re-run should not change what testers see.
#   - ATOMIC OR NO-OP. Either the artifact lands fully or not at all. Half-
#     uploaded states are worse than a clean retry. Prefer destination APIs
#     that publish atomically (TestFlight processing queue, registry tag
#     commit) over multi-step uploads that can leave partials.
#   - RETRY-FRIENDLY. The calling workflow wraps invocations in exponential
#     backoff. This script should exit non-zero on transient failures
#     (network, 5xx) and zero on "already distributed" so the wrapper does
#     the right thing without parsing logs.
#   - CREDENTIAL HANDLING. Read from env vars only. Never write tokens to
#     disk, never log them, never commit a service-account JSON next to the
#     script. The repo is public-facing for the framework's own template;
#     consumer forks may be private but the discipline travels.
#   - NO PROMOTION DECISIONS. This script does not decide whether $TAG
#     should be public. That call belongs to distribute-public.sh, which
#     runs only when the tag's commit is reachable from origin/main.
#
# What this is NOT
#   - NOT the build. build.sh produces the artifact; this script ships it.
#     If you find yourself compiling here, push the work back into build.sh.
#   - NOT the version claim. claim-dev-merge.sh + claim-main-release.sh own
#     tag creation and Release object lifecycle. Do not create tags here.
#     Do not create GitHub Releases here (distribute-public.sh handles the
#     Release object only for tags reachable from main).
#   - NOT a verification gate. If you need to confirm the artifact works
#     before shipping it, that belongs in audit-pushed-branch.yml's runtime
#     audit, not buried inside a distribution step.
#
# Override pattern (consumers replace this script's body)
#   The template ships a placeholder body that exits non-zero with a clear
#   banner. Consumer projects fork the file and replace everything below
#   the DESIGN DOC line with their real recipe (TestFlight upload, Docker
#   push, npm publish --tag dev, S3 sync, etc.). The DESIGN DOC stays -
#   it is the contract every consumer signs by using the framework. The
#   PLACEHOLDER_MARKER guard auto-fails the placeholder so a forgotten
#   override cannot silently distribute nothing.
#
# ============================================================================

set -euo pipefail

PLACEHOLDER_MARKER='PLACEHOLDER_DISTRIBUTE_INTERNAL_NOT_YET_FILLED'

if grep -q "$PLACEHOLDER_MARKER" "$0"; then
  cat >&2 <<'EOF'
=========================================================================
distribute-internal.sh is still the v4rian template PLACEHOLDER. Replace
with your project's internal-channel distribution command(s).

Examples:
  - TestFlight (iOS):     xcrun altool --upload-app -f "out/${TAG}.ipa" ...
  - Internal Docker reg:  docker push "registry.internal/app:${TAG}"
  - npm dist-tag dev:     npm publish --tag dev
  - S3 / artifact store:  aws s3 cp out/ "s3://internal-artifacts/${TAG}/" --recursive
=========================================================================
EOF
  exit 1
fi

echo "-> distribute-internal.sh: shipping $TAG"
echo "::error::distribute-internal.sh has no real distribution steps yet"
exit 1
