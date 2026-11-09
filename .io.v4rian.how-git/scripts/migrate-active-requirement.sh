#!/usr/bin/env bash
# migrate-active-requirement.sh - move legacy lanes onto per-lane
# requirement files.
#
# Lanes allocated before the per-lane layout carry the single shared
# .io.v4rian.how-git/active-requirement, so two of them merged into dev
# collide on it (add/add or modify/modify). This tool gives each such lane
# one commit that moves its text, byte for byte, to its own
# .io.v4rian.how-git/requirements/<pool ref with / as __>
# (hg_requirement_path), after which every lane merges cleanly on any host.
#
# A lane qualifies when its tip tracks the shared file, it changed that file
# since it forked from dev (so the text is its own, not one inherited from
# dev), and it has no per-lane file yet.
#
# Lanes that share one legacy blob (a lane cut from another lane) must not
# all move it: two lanes renaming one file to two paths conflict
# rename/rename on dev. Per blob exactly one lane moves the text (the first
# by name in this run, unless another lane already moved that blob in an
# earlier run); every other lane only adds its lane file and leaves the
# shared file unchanged, which merges cleanly in any order. The shared file
# that remains on dev afterwards is dropped by the next allocated lane.
#
# The commit is made with plumbing,
# so no branch is checked out; a lane checked out in a worktree is updated
# there too (two-way read-tree), and is skipped when that worktree has
# uncommitted changes. Nothing is pushed.
#
# Usage:
#   migrate-active-requirement.sh               migrate every qualifying local lane
#   migrate-active-requirement.sh <branch>...   migrate the named lanes
#   migrate-active-requirement.sh --dry-run     list what would move
#   migrate-active-requirement.sh -h | --help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

DRY_RUN=false
BRANCHES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "X unknown flag: $1" >&2; exit 2 ;;
    *) BRANCHES="$BRANCHES ${1#refs/heads/}"; shift ;;
  esac
done
[ -n "$BRANCHES" ] || BRANCHES=$(hg_legacy_requirement_lanes)
if [ -z "$(printf '%s' "$BRANCHES" | tr -d ' \n')" ]; then
  echo "ok: no lane carries the legacy shared active-requirement"
  exit 0
fi

# Lanes that already moved a blob (the lane file holds it and the shared
# file is gone): their blob ids, one per line.
MOVED_BLOBS=$(git for-each-ref --format='%(refname:short)' refs/heads/pool/ | while read -r lb; do
  git cat-file -e "refs/heads/$lb:$HG_LEGACY_REQUIREMENT" 2>/dev/null && continue
  git rev-parse -q --verify "refs/heads/$lb:$(hg_requirement_path "$lb")" 2>/dev/null || true
done)

moved=0 skipped=0
for b in $BRANCHES; do
  tip=$(git rev-parse -q --verify "refs/heads/$b^{commit}" 2>/dev/null || true)
  if [ -z "$tip" ]; then echo "  skip $b: no such local branch"; skipped=$((skipped + 1)); continue; fi
  blob=$(git rev-parse -q --verify "$tip:$HG_LEGACY_REQUIREMENT" 2>/dev/null || true)
  if [ -z "$blob" ]; then echo "  skip $b: carries no shared active-requirement"; skipped=$((skipped + 1)); continue; fi
  newpath=$(hg_requirement_path "$b")
  if git cat-file -e "$tip:$newpath" 2>/dev/null; then echo "  skip $b: already has $newpath"; skipped=$((skipped + 1)); continue; fi
  wt=$(git worktree list --porcelain | awk -v r="branch refs/heads/$b" '/^worktree /{w=substr($0, 10)} $0 == r {print w}')
  if [ -n "$wt" ] && [ -n "$(git -C "$wt" status --porcelain --untracked-files=no)" ]; then
    echo "  skip $b: checked out in $wt with uncommitted changes (commit or stash, then re-run)"
    skipped=$((skipped + 1)); continue
  fi
  # One mover per shared blob (see the header): keep the shared file when
  # another lane already moved this blob or moves it earlier in this run.
  keep=false
  if printf '%s\n' "$MOVED_BLOBS" | grep -qx "$blob"; then keep=true; fi
  if $DRY_RUN; then
    if $keep; then echo "  would add $newpath to $b (shared $HG_LEGACY_REQUIREMENT kept: another lane moves this text)"
    else echo "  would move $b: $HG_LEGACY_REQUIREMENT -> $newpath"; fi
    MOVED_BLOBS="$MOVED_BLOBS
$blob"
    continue
  fi
  idx=$(mktemp -t migrate-req-idx.XXXXXX)
  GIT_INDEX_FILE="$idx" git read-tree "$tip"
  $keep || GIT_INDEX_FILE="$idx" git update-index --force-remove "$HG_LEGACY_REQUIREMENT"
  GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo 100644 "$blob" "$newpath"
  tree=$(GIT_INDEX_FILE="$idx" git write-tree)
  rm -f "$idx"
  if $keep; then
    new=$(printf '%s\n\n%s\n' "[REFACTOR] Add the lane requirement file beside the shared one" \
      "Adds $newpath with the text of $HG_LEGACY_REQUIREMENT, which stays unchanged because another lane carrying the same text moves it; only one lane may move a shared file, or the two merges conflict on dev." \
      | git commit-tree "$tree" -p "$tip")
  else
    new=$(printf '%s\n\n%s\n' "[REFACTOR] Move the lane requirement to its per-lane file" \
      "Moves $HG_LEGACY_REQUIREMENT to $newpath with the text unchanged, so this lane no longer collides with other lanes on the shared file when it merges into dev." \
      | git commit-tree "$tree" -p "$tip")
    MOVED_BLOBS="$MOVED_BLOBS
$blob"
  fi
  git update-ref "refs/heads/$b" "$new" "$tip"
  if [ -n "$wt" ]; then
    git -C "$wt" read-tree -m -u "$tip" "$new"
  fi
  if $keep; then
    echo "  added $newpath to $b, shared file kept for the lane that moves it ($(git rev-parse --short "$new"))"
  else
    echo "  moved $b: $HG_LEGACY_REQUIREMENT -> $newpath ($(git rev-parse --short "$new"))"
  fi
  moved=$((moved + 1))
done
$DRY_RUN && exit 0
echo "ok: $moved lane(s) migrated, $skipped skipped"
