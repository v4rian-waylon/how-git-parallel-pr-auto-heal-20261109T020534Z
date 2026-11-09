#!/usr/bin/env bash
# claim-tag-drift-sanity.sh — self-correct duplicate v* tags on HEAD
# before the claim script runs.
#
# Two actors racing to claim the dev tip can both land a v* tag on the
# same commit. The normal case is zero or one tag on HEAD; this script
# is a no-op in that case. When two or more tags exist, keep the lowest
# (by version sort) and drop the rest on both local and origin so the
# claim's idempotent re-derive lands cleanly on the chosen tag.

set -uo pipefail

DUPS=$(git tag --points-at HEAD --list 'v*' | sort -V)
COUNT=0
[ -n "$DUPS" ] && COUNT=$(printf '%s\n' "$DUPS" | wc -l | tr -d ' ')

if [ "$COUNT" -gt 1 ]; then
  KEEP=$(printf '%s\n' "$DUPS" | head -1)
  echo "→ HEAD has $COUNT v* tags: $DUPS"
  echo "→ keeping $KEEP, deleting the rest"
  printf '%s\n' "$DUPS" | tail -n +2 | while read -r t; do
    [ -z "$t" ] && continue
    git tag -d "$t"
    git push origin ":refs/tags/$t" 2>&1 || true
  done
else
  echo "→ HEAD has $COUNT v* tag(s); nothing to self-correct"
fi
