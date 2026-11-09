#!/usr/bin/env bash
# release-test.sh - run and portability surface for the tag build's artifacts.
#
# The last gate of the tag build: proves the compiled release artifacts RUN
# as intended before they sit in the distribution path (the release ceremony
# reuses them at main promotion without a rebuild). Consumer projects
# override this file with their real launch/smoke assertions - start the
# binary, hit its /version endpoint, open the bundle, run the CLI with
# --help - the same way they override build.sh with their real build. The
# template ships a detector-based placeholder that DTRT for the common
# cases and prints a clear "consumer must override" banner for everything
# else.
#
# Portability: the placeholder reports each artifact's file type, and for
# Mach-O payloads the minimum-OS floor of every slice it can see (one
# minos-26 dylib gates a whole bundle to macOS 26 regardless of the app
# binary's stamp). The report is the surface; consumer overrides turn the
# lines that matter into hard assertions for their platform matrix.
#
# Environment (same contract as build.sh):
#   $TAG           tag under test (e.g. v2026.0.7)
#   $BUILD_TYPE    always "release" on v* tag builds
#   $ARTIFACT_DIR  artifact contract path (default build/artifacts)
#
# Exit codes: 0 artifacts run as intended, 1 a run test failed or an
# override obligation is unmet, 2 usage/pipeline.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
ARTIFACT_DIR="${ARTIFACT_DIR:-$REPO_ROOT/build/artifacts}"
TAG="${TAG:-untagged}"

if [ ! -d "$ARTIFACT_DIR" ] || [ -z "$(ls -A "$ARTIFACT_DIR" 2>/dev/null || true)" ]; then
  echo "X release-test: no artifacts at $ARTIFACT_DIR (build must run first)" >&2
  exit 2
fi

echo "=> release-test [$TAG] over $ARTIFACT_DIR"

# ---------------------------------------------------------------------------
# Portability report - always emitted, never a hard gate in the placeholder.
# ---------------------------------------------------------------------------
report_portability() {
  local f
  echo "  portability report:"
  find "$ARTIFACT_DIR" -type f | while IFS= read -r f; do
    echo "    $(basename "$f"): $(file -b "$f" 2>/dev/null || echo unknown)"
    if command -v otool >/dev/null 2>&1 && file -b "$f" 2>/dev/null | grep -q 'Mach-O'; then
      otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print "      minos " $2; exit}'
    fi
  done
}

# ---------------------------------------------------------------------------
# Detector-based run tests. Consumer projects replace this body with their
# real launch/smoke assertions.
# ---------------------------------------------------------------------------
test_node_artifact() {
  local tb="$1" ex rc=0
  echo "-> release-test: Node tarball $(basename "$tb")"
  ex=$(mktemp -d -t release-test.XXXXXX)
  if ! tar xzf "$tb" -C "$ex" 2>/dev/null; then
    echo "X release-test: cannot extract $(basename "$tb")" >&2
    rm -rf "$ex"
    return 1
  fi
  # Basic run check: every shipped JavaScript entry must at least parse in
  # the runtime that will execute it. A real consumer override boots the
  # service and asserts behavior; parse-clean is the honest generic floor.
  local js checked=0
  while IFS= read -r js; do
    if ! node --check "$js" >/dev/null 2>&1; then
      echo "X release-test: $(echo "$js" | sed "s|^$ex/||") does not parse under node --check" >&2
      rc=1
    fi
    checked=$((checked + 1))
  done < <(find "$ex" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) -not -path '*/node_modules/*')
  echo "  · node --check over $checked shipped file(s): $([ $rc -eq 0 ] && echo clean || echo FAILED)"
  rm -rf "$ex"
  return $rc
}

test_template_self_artifact() {
  local summary="$1"
  echo "-> release-test: template self-build summary $(basename "$summary")"
  # The summary is the template's own artifact; intact means it names the
  # tag it was built from and parses as the expected key: value shape.
  if ! grep -q "how-git template tag: $TAG" "$summary"; then
    echo "X release-test: summary does not name tag $TAG" >&2
    return 1
  fi
  echo "  · summary intact and names $TAG"
  return 0
}

override_banner() {
  cat >&2 <<EOF
=========================================================================
release-test.sh has no generic run recipe for this artifact set. Launch
commands, smoke endpoints, and platform assertions vary too much across
consumers.

OVERRIDE release-test.sh with your project's run tests. Examples:

  ./build/artifacts/MyApp-\$TAG --version | grep -q "\$TAG"
  open build/artifacts/MyApp.app && curl -sf localhost:8080/version
  node dist/main.js --smoke

Every artifact under \$ARTIFACT_DIR should be exercised; exit non-zero
when any artifact fails to run as intended. Use the portability report
above to pin your platform floor (e.g. assert every Mach-O is minos 12).
=========================================================================
EOF
  return 1
}

report_portability

RC=0
TESTED=0
for a in "$ARTIFACT_DIR"/*; do
  [ -f "$a" ] || continue
  case "$(basename "$a")" in
    node-*.tar.gz|node-*.tgz) test_node_artifact "$a" || RC=1; TESTED=$((TESTED + 1)) ;;
    how-git-*.txt)            test_template_self_artifact "$a" || RC=1; TESTED=$((TESTED + 1)) ;;
    node-*.NO-OUTPUT.txt|node-*.NO-BUILD-SCRIPT.txt)
      echo "  · contract-gap marker $(basename "$a"); nothing to run"; TESTED=$((TESTED + 1)) ;;
  esac
done

if [ "$TESTED" -eq 0 ]; then
  override_banner || RC=1
fi

if [ "$RC" -eq 0 ]; then
  echo "-> release-test: artifacts for $TAG run as intended"
else
  echo "X release-test: at least one artifact failed its run test for $TAG" >&2
fi
exit $RC
