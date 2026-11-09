#!/usr/bin/env bash
# distribute-public.sh - attach a built artifact to the PUBLIC channel.
#
# ============================================================================
# DESIGN DOC (read before editing this file or its consumer override)
# ============================================================================
#
# Purpose
#   The public channel is the end user surface. The default body uploads
#   every artifact under ./out/ to the corresponding GitHub Release object,
#   which is the framework's canonical public destination. Consumer projects
#   typically layer additional public hops on top of the Release upload -
#   CDN sync, public registry publish (npm latest, brew tap update, Docker
#   Hub push), website asset bump, announcement ping to a Slack channel or
#   social account. Those extras live in the EXTRAS section at the bottom.
#
# Triggers
#   Called by the distribution bundle ONLY for tags whose commit is
#   reachable from origin/main. Pre-release dev tags (vYEAR.SERIES.DEV-b.N)
#   never reach this script; only the release tag vYEAR.SERIES.DEV does,
#   and only after claim-main-release.sh has promoted the dev tag to a
#   public Release object. The build half of the lifecycle is intentionally
#   distribution-free; build-on-tag.yml must NOT invoke this script (the
#   lifecycle test suite enforces that).
#
# Inputs
#   $TAG         release tag being distributed (e.g. v2026.0.7)
#   $GH_TOKEN    credential for `gh release upload`; the calling workflow
#                exposes it via secrets, never read from a file in the repo
#   ./out/       artifact directory populated by build.sh (canonical path
#                is build/artifacts/; the distribution bundle stages it as
#                ./out/ before invoking this script)
#
# Outputs
#   GitHub Release assets attached to the existing Release object for $TAG.
#   The Release object itself is created by claim-main-release.sh; this
#   script only ATTACHES files. If the Release does not yet exist (e.g.
#   off-grid local distribution), it is created with `--generate-notes`
#   as a defensive fallback so the upload has somewhere to land.
#   Optional consumer extras in the EXTRAS section produce side-effects
#   at additional public destinations (CDN, registries, announcements).
#
# Design tips
#   - IDEMPOTENT BY TAG. `gh release upload --clobber` overwrites by
#     filename, so re-running for the same $TAG with the same artifact
#     set yields the same final state. EXTRAS sections should preserve
#     this property: skip-if-present at every additional destination,
#     never blindly append.
#   - ATOMIC OR NO-OP. Public destinations are user-facing; a half-
#     published Release is worse than a clean retry. The default `gh
#     release upload` is per-file atomic; bunch your EXTRAS in single
#     publish operations where possible (one CDN invalidation at the
#     end, one npm publish, one tweet).
#   - RETRY-FRIENDLY. Exit non-zero on transient failures so the calling
#     workflow's exponential backoff covers them. Exit zero only when
#     every requested destination is in the final state.
#   - CREDENTIAL HANDLING. $GH_TOKEN and any extra-channel secrets come
#     from env vars set by the workflow. Never write them to disk, never
#     log them, never embed them in the script. The PLACEHOLDER_MARKER
#     guard at the bottom is metadata, not a secret.
#   - PRE-FLIGHT THE RELEASE. The script defensively creates the Release
#     object if missing, but the canonical flow is claim-main-release.sh
#     making it first. Treat the on-the-fly create as a fallback for
#     off-grid mode and disaster-recovery scenarios.
#
# What this is NOT
#   - NOT the build. build.sh produces the artifact at build/artifacts/;
#     this script ships it. If you find yourself compiling here, push the
#     work back into build.sh.
#   - NOT the version claim. claim-main-release.sh owns Release object
#     creation against the existing dev tag. This script attaches assets
#     to an already-promoted Release; it does not mint tags, does not
#     amend the merge subject, does not flip prerelease flags.
#   - NOT the internal channel. distribute-internal.sh runs first on
#     every v* tag; this script runs only after main promotion. Do not
#     duplicate internal-only destinations here.
#   - NOT a verification gate. Runtime / smoke / coverage checks belong
#     in audit-pushed-branch.yml, not in a public distribution step.
#
# Override pattern (consumers extend or replace)
#   The template ships a DEFAULT body that does the right thing for the
#   common case (Release asset upload) and a PLACEHOLDER_MARKER guard
#   around an EXTRAS section so a consumer who wants ONLY the default
#   behavior simply deletes the PLACEHOLDER_GUARD block. Consumers who
#   want extra public hops (CDN sync, public registry publish, etc.)
#   replace the EXTRAS body with their real commands. The DESIGN DOC
#   stays - it is the contract every consumer signs by using the
#   framework.
#
# ============================================================================

set -euo pipefail

if [ ! -d out ] || [ -z "$(ls -A out 2>/dev/null)" ]; then
  echo "warn: no artifacts in ./out/ to attach to Release $TAG"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "::error::gh CLI not available - cannot upload Release assets"
  exit 1
fi

if ! gh release view "$TAG" >/dev/null 2>&1; then
  echo "-> Release $TAG does not yet exist, creating it"
  gh release create "$TAG" --generate-notes --title "$TAG" || {
    echo "::error::failed to create Release $TAG"; exit 1; }
fi

echo "-> uploading ./out/* as assets on Release $TAG"
gh release upload "$TAG" out/* --clobber

PLACEHOLDER_MARKER='PLACEHOLDER_DISTRIBUTE_PUBLIC_EXTRAS_NOT_YET_FILLED'

if grep -q "$PLACEHOLDER_MARKER" "$0"; then
  cat >&2 <<'EOF'
=========================================================================
distribute-public.sh uploaded the artifact(s) to the GitHub Release
for $TAG, but the EXTRAS section is still the v4rian template
PLACEHOLDER. If you have no extra public-channel steps, delete the
PLACEHOLDER_GUARD block.

Otherwise replace with your CDN sync / public registry publish /
announcement ping commands.
=========================================================================
EOF
  exit 1
fi

echo "-> distribute-public.sh: extras complete for $TAG"
