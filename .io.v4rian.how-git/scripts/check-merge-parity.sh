#!/usr/bin/env bash
# check-merge-parity.sh - PR body / merge commit body parity (ledger R23).
#
# In connected mode the claim writes the merge body as one "PR #N <url>"
# reference paragraph (bare "PR #N" when the repo slug does not resolve),
# a blank line, then the PR body as stored on GitHub. The merge body minus
# that paragraph must therefore equal the PR body character for character
# (git-merge-audit, PR body parity). CR characters and trailing blank
# lines are normalised on both sides; nothing else is.
#
# Usage:
#   check-merge-parity.sh <merge-rev> --pr-body-file <file>
#   check-merge-parity.sh <merge-rev> --pr <N> [--repo owner/name]
#   ... [--strip-topic "<Topic>."]  also drop a claim-added list topic and
#                                   its leaves (the release roster) from the
#                                   merge body before comparing
#
# The second form reads the PR body with `gh pr view`. Exit 0 on parity,
# 1 with a unified diff on stderr when the bodies differ, 2 on usage or
# lookup errors. Used by claim-dev-merge.sh / claim-main-release.sh after
# the amend and by CI (ci-dispatch pr-merge claim). bash 3.2 and 5.

set -uo pipefail

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

REV="${1:-}"
[ -n "$REV" ] || usage
shift
PR_FILE=""; PR_NUM=""; REPO=""; STRIP_TOPIC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr-body-file) [ $# -ge 2 ] || usage; PR_FILE="$2"; shift 2 ;;
    --pr) [ $# -ge 2 ] || usage; PR_NUM="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --strip-topic) [ $# -ge 2 ] || usage; STRIP_TOPIC="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$PR_FILE" ] || [ -n "$PR_NUM" ] || usage

WORK=$(mktemp -d "${TMPDIR:-/tmp}/merge-parity.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

normalise() { tr -d '\r' | awk '{ l[++n] = $0 } END { while (n > 0 && l[n] ~ /^[ \t]*$/) n--; for (i = 1; i <= n; i++) print l[i] }'; }

if ! git log -1 --format=%b "$REV" > "$WORK/merge.raw" 2>/dev/null; then
  echo "X check-merge-parity: unknown revision: $REV" >&2; exit 2
fi
# Drop the leading "PR #N[ url]" paragraph and the blank line after it.
normalise < "$WORK/merge.raw" | awk '
  NR == 1 && /^PR #[0-9]+( https?:\/\/[^ ]+)?$/ { skip = 1; next }
  skip && /^[ \t]*$/ { next }
  { skip = 0; print }' | awk -v t="- $STRIP_TOPIC" '
  t != "- " && $0 == t { drop = 1; next }
  drop && /^    - / { next }
  { drop = 0; print }' > "$WORK/merge.body"

if [ -n "$PR_FILE" ]; then
  [ -f "$PR_FILE" ] || { echo "X check-merge-parity: no such file: $PR_FILE" >&2; exit 2; }
  normalise < "$PR_FILE" > "$WORK/pr.body"
else
  if [ -z "$REPO" ]; then
    REPO=$(git config --get remote.origin.url 2>/dev/null | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
  fi
  if ! gh pr view "$PR_NUM" ${REPO:+--repo "$REPO"} --json body --jq '.body' > "$WORK/pr.gh" 2>/dev/null; then
    echo "X check-merge-parity: could not read PR #$PR_NUM body via gh" >&2; exit 2
  fi
  normalise < "$WORK/pr.gh" > "$WORK/pr.body"
fi

if diff -u "$WORK/pr.body" "$WORK/merge.body" > "$WORK/diff" 2>&1; then
  echo "OK merge body of $(git rev-parse --short "$REV") equals the PR body"
  exit 0
fi
echo "X check-merge-parity: merge body of $(git rev-parse --short "$REV") differs from the PR body (--- PR, +++ merge):" >&2
sed '1,2d' "$WORK/diff" >&2
exit 1
