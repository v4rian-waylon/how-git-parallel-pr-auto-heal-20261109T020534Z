#!/usr/bin/env bash
# seed-release-body.sh - print a dev into main merge body in the ruled
# merge shape (git-merge-audit rule 5) from the first-parent pool merges
# in <base>..HEAD (default base origin/main, else main): a one-sentence
# macro paragraph, a blank line, one topic per pool kind holding one leaf
# per pool, "<short name>: <first sentence of that merge's paragraph>.".
# The claim's "PR #N" reference paragraph is skipped. Prints nothing when
# no pool merge is in range. Used by bin/init-release and bin/ship.
#
# Usage: seed-release-body.sh [<base>]

set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
BASE_ARG="${1:-}"

seed_release_body() {
  local base="${BASE_ARG:-origin/main}"
  git -C "$REPO_ROOT" rev-parse --verify --quiet "$base" >/dev/null || base="main"
  local shas count=0
  shas=$(git -C "$REPO_ROOT" rev-list --first-parent --merges --reverse "$base..HEAD" 2>/dev/null || true)
  local entries="" sha subj ref kind short sentence
  for sha in $shas; do
    subj=$(git -C "$REPO_ROOT" log -1 --format=%s "$sha")
    ref=$(printf '%s' "$subj" | sed -nE 's|^\[MERGE\] (pool/[^ ]+) into dev.*|\1|p')
    [ -n "$ref" ] || continue
    kind=$(printf '%s' "$ref" | sed -nE 's|^pool/([^/]+/)?n[0-9]+\.([a-z&]+)\..*|\2|p')
    short=$(printf '%s' "$ref" | sed -nE 's|^pool/([^/]+/)?n[0-9]+\.[a-z&]+\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?(.*)$|\4|p')
    sentence=$(git -C "$REPO_ROOT" log -1 --format=%b "$sha" | awk '
      /^PR #[0-9]+/ && !seen { next }
      /^[ \t]*$/ { if (para != "") exit; next }
      { seen = 1; para = para (para == "" ? "" : " ") $0 }
      END { print para }' | sed -E 's/([.!?])( .*)?$/\1/')
    [ -n "$sentence" ] || sentence="Lands ${short}."
    case "$sentence" in *[.!?]) ;; *) sentence="${sentence}." ;; esac
    entries="${entries}${kind}|${short}|${sentence}
"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || return 0
  if [ "$count" -eq 1 ]; then
    printf 'Releases the one pool merged into dev since the last release.\n'
  else
    printf 'Releases the %s pools merged into dev since the last release.\n' "$count"
  fi
  local k topic
  for k in feature fix refactor doc reconcile 'r&d'; do
    printf '%s' "$entries" | grep -q "^${k}|" || continue
    case "$k" in
      feature) topic="Features." ;; fix) topic="Fixes." ;; refactor) topic="Refactors." ;;
      doc) topic="Documentation." ;; reconcile) topic="Reconciles." ;; *) topic="Research." ;;
    esac
    printf -- '- %s\n' "$topic"
    printf '%s' "$entries" | awk -F'|' -v k="$k" '$1 == k { print "    - " $2 ": " $3 }'
  done
}

seed_release_body > "${TMPDIR:-/tmp}/.seed-$$" || true
if [ -s "${TMPDIR:-/tmp}/.seed-$$" ]; then
  head -n1 "${TMPDIR:-/tmp}/.seed-$$"; printf '\n'; sed '1d' "${TMPDIR:-/tmp}/.seed-$$"
fi
rm -f "${TMPDIR:-/tmp}/.seed-$$"
