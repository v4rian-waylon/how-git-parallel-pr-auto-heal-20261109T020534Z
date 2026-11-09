#!/usr/bin/env bash
# release-artifact-audit.sh - no-debug gate over the tag build's artifacts.
#
# Every v* artifact is a release candidate (the release ceremony reuses the
# dev tag's artifact at main promotion without a rebuild), so debug code and
# debug builds are banned from build/artifacts/ at the only point they can
# be enforced: right after build.sh runs. Invoked by the tag trigger's
# required.build gate, after the build and before the release test surface.
#
# Two layers, mirroring the commit-audit posture:
#
#   1. Deterministic scan (the hard gate). High-precision debug signatures
#      only - a hit here is red with no judgment involved:
#        - debug build outputs by name: *.dSYM, *.pdb, *.debug, plus
#          -debug / _debug artifact name segments
#        - JavaScript source maps (*.map) riding next to shipped .js
#        - `debugger;` statements in shipped JavaScript text
#      Tarball artifacts (*.tar.gz / *.tgz) are extracted to a temp dir and
#      scanned as content - the payload is what ships, not the wrapper.
#
#   2. Claude inspection (the semantic layer, additive per the framework's
#      claude posture). The artifact listing plus a sample of debug-flavored
#      lines is handed to claude, which judges whether real debug leftovers
#      ship in the artifacts. FAIL verdict is enforcing when claude runs;
#      unavailability (no CLI, no credentials, transient error) WARNs and
#      passes - the deterministic layer stays the only hard line, and the
#      pipeline never turns red because claude was absent.
#
# Environment:
#   ARTIFACT_DIR          artifact contract path (default build/artifacts)
#   TAG                   the v* tag under audit (for messages)
#   LIFECYCLE_TEST_MODE   1 = canned claude verdict, no API call
#   RELEASE_AUDIT_TEST_OUTCOME  test-mode verdict: CLEAN (default) | DEBUG
#   CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY   claude credentials
#
# Exit codes: 0 clean (or claude-skip), 1 debug findings, 2 usage/pipeline.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# shellcheck source=../_lib.sh
. "$SCRIPT_DIR/../_lib.sh"

ARTIFACT_DIR="${ARTIFACT_DIR:-$REPO_ROOT/build/artifacts}"
TAG="${TAG:-untagged}"

if [ ! -d "$ARTIFACT_DIR" ] || [ -z "$(ls -A "$ARTIFACT_DIR" 2>/dev/null || true)" ]; then
  echo "X release-artifact-audit: no artifacts at $ARTIFACT_DIR (build must run first)" >&2
  exit 2
fi

echo "=> release-artifact-audit [$TAG] scanning $ARTIFACT_DIR"

# ---------------------------------------------------------------------------
# Materialize the audit surface: the artifact dir itself, plus every tarball
# extracted so the shipped payload is scanned, not the wrapper.
# ---------------------------------------------------------------------------
SCAN_DIR=$(mktemp -d -t release-artifact-audit.XXXXXX)
cleanup() { rm -rf "$SCAN_DIR"; }
trap cleanup EXIT

cp -Rp "$ARTIFACT_DIR/." "$SCAN_DIR/"
# Retention trash is recoverable history, not shipped payload - never audited.
rm -rf "$SCAN_DIR/.trash"
find "$SCAN_DIR" -type f \( -name '*.tar.gz' -o -name '*.tgz' \) | while IFS= read -r tb; do
  ex="${tb}.extracted"
  mkdir -p "$ex"
  tar xzf "$tb" -C "$ex" 2>/dev/null || echo "  ! could not extract $(basename "$tb"); scanning wrapper only" >&2
done

# ---------------------------------------------------------------------------
# Layer 1 - deterministic debug signatures (hard gate)
# ---------------------------------------------------------------------------
FINDINGS=""

# Debug build outputs by name.
NAME_HITS=$(find "$SCAN_DIR" \( -name '*.dSYM' -o -name '*.pdb' -o -name '*.debug' \
  -o -name '*-debug*' -o -name '*_debug*' \) | sed "s|^$SCAN_DIR/||")
[ -n "$NAME_HITS" ] && FINDINGS="${FINDINGS}debug build output(s) by name:
$(printf '%s\n' "$NAME_HITS" | sed 's/^/    /')
"

# Source maps shipping beside JavaScript.
MAP_HITS=$(find "$SCAN_DIR" -name '*.map' -type f | while IFS= read -r m; do
  [ -e "${m%.map}" ] || ls "$(dirname "$m")"/*.js >/dev/null 2>&1 || continue
  printf '%s\n' "${m#"$SCAN_DIR"/}"
done)
[ -n "$MAP_HITS" ] && FINDINGS="${FINDINGS}source map(s) beside shipped JavaScript:
$(printf '%s\n' "$MAP_HITS" | sed 's/^/    /')
"

# `debugger;` statements in shipped JavaScript.
DBG_HITS=$(find "$SCAN_DIR" -name '*.js' -type f -exec grep -l -E '^[[:space:]]*debugger[[:space:]]*;' {} \; 2>/dev/null | sed "s|^$SCAN_DIR/||")
[ -n "$DBG_HITS" ] && FINDINGS="${FINDINGS}debugger statement(s) in shipped JavaScript:
$(printf '%s\n' "$DBG_HITS" | sed 's/^/    /')
"

if [ -n "$FINDINGS" ]; then
  echo "X release-artifact-audit [$TAG]: debug output banned from release artifacts" >&2
  printf '%s' "$FINDINGS" | sed 's/^/  /' >&2
  echo "  Rebuild in release configuration (BUILD_TYPE=release) and keep debug output out of $ARTIFACT_DIR." >&2
  exit 1
fi
echo "  · deterministic scan clean (no debug outputs, source maps, or debugger statements)"

# ---------------------------------------------------------------------------
# Layer 2 - claude inspection (semantic, additive)
# ---------------------------------------------------------------------------
if [ "${LIFECYCLE_TEST_MODE:-0}" = "1" ]; then
  outcome="${RELEASE_AUDIT_TEST_OUTCOME:-CLEAN}"
  if [ "$outcome" = "DEBUG" ]; then
    echo "X release-artifact-audit [DEBUG canned] $TAG" >&2
    echo "ARTIFACTS_DEBUG: canned test-mode outcome" >&2
    exit 1
  fi
  echo "  · [test-mode] claude artifact inspection outcome=CLEAN"
  echo "ARTIFACTS_CLEAN"
  exit 0
fi

ensure_claude_ready || true
if ! command -v claude >/dev/null 2>&1; then
  echo "  ! release-artifact-audit WARN: claude CLI unavailable; semantic inspection skipped (deterministic scan still applied)" >&2
  exit 0
fi
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "  ! release-artifact-audit WARN: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set; semantic inspection skipped (deterministic scan still applied)" >&2
  exit 0
fi

LISTING=$(cd "$SCAN_DIR" && find . -type f | sed 's|^\./||' | head -200)
# Debug-flavored sample lines from text payloads for claude to judge in
# context (verbose logging left on, dev endpoints, DEBUG toggles). The
# sample is judgment input, never a deterministic trigger.
SAMPLE=$(find "$SCAN_DIR" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.json' -o -name '*.txt' -o -name '*.html' \) \
  -exec grep -n -H -iE 'console\.(debug|trace)|qdebug|debug *= *(1|true)|localhost:[0-9]+|devtools' {} + 2>/dev/null \
  | sed "s|$SCAN_DIR/||" | head -80)

prompt_file=$(mktemp -t release-artifact-audit.XXXXXX)
{
  printf 'You are the release artifact auditor on a v* tag build. These artifacts ship publicly at main promotion WITHOUT a rebuild, so debug leftovers here ship to end users.\n\n'
  printf 'Tag: %s\n\nArtifact listing (payloads extracted from tarballs):\n%s\n\n' "$TAG" "$LISTING"
  if [ -n "$SAMPLE" ]; then
    printf 'Debug-flavored lines found in text payloads (file:line:content):\n%s\n\n' "$SAMPLE"
  else
    printf 'No debug-flavored lines were found in text payloads.\n\n'
  fi
  printf 'Judge whether REAL debug code or debug-build output ships in these artifacts: active debug logging left on, dev-only endpoints baked in, DEBUG toggles defaulted on, debug builds mislabeled as release. Legitimate uses (a configurable log level, the word debug in documentation, an error handler) are NOT findings.\n\n'
  printf 'Reply with exactly one of:\n'
  printf '  ARTIFACTS_CLEAN\n'
  printf '  ARTIFACTS_DEBUG: <named finding, one short sentence>\n'
} > "$prompt_file"

echo "  -> release-artifact-audit invoking claude inspection (this may take a few seconds)" >&2
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  output=$(unset ANTHROPIC_API_KEY; claude -p \
    --permission-mode acceptEdits \
    --allowedTools "Read,Glob,Grep,Bash(grep:*),Bash(find:*),Bash(file:*),Bash(tar -t:*)" \
    < "$prompt_file" 2>&1)
else
  output=$(claude -p \
    --permission-mode acceptEdits \
    --allowedTools "Read,Glob,Grep,Bash(grep:*),Bash(find:*),Bash(file:*),Bash(tar -t:*)" \
    < "$prompt_file" 2>&1)
fi
rc=$?
rm -f "$prompt_file"

if [ "$rc" -ne 0 ]; then
  echo "  ! release-artifact-audit WARN: claude exited rc=$rc; semantic inspection skipped (deterministic scan still applied)" >&2
  printf '%s\n' "$output" | head -5 >&2
  exit 0
fi
if printf '%s' "$output" | grep -qE '^[[:space:]]*ARTIFACTS_DEBUG\b'; then
  echo "X release-artifact-audit [FAIL] $TAG" >&2
  printf '%s' "$output" | grep -E '^[[:space:]]*ARTIFACTS_DEBUG' | head -1 >&2
  exit 1
fi
if printf '%s' "$output" | grep -qE '^[[:space:]]*ARTIFACTS_CLEAN\b'; then
  echo "  ✓ release-artifact-audit [CLEAN] $TAG"
  exit 0
fi
echo "  ! release-artifact-audit WARN: unparseable claude reply; semantic inspection skipped (deterministic scan still applied)" >&2
printf '%s\n' "$output" | head -5 >&2
exit 0
