#!/bin/bash
# git-preflight: two independent working-tree backups BEFORE a destructive op, without touching
# the current branch or index. 1) preflight-bak-YYYY-MM-DD/NN ref built from a temp index of the
# full working tree (tracked + untracked, secrets/build/node_modules excluded), pushed to origin.
# 2) bak zip of the working tree into local_stage/baks/ (+ shuttle.o/baks/ mirror).
# Usage: git-preflight.sh <repo-path> ["reason"]
set -eu
repo=$(cd "${1:?repo path}" && git rev-parse --show-toplevel)
reason="${2:-destructive op}"
BAKS="${BAKS_DIR:-/Users/waylon/local_stage/baks}"
MIRROR="${BAKS_MIRROR:-/Users/waylon/local_stage/shuttle.o/baks}"
name=$(basename "$repo"); day=$(date +%Y-%m-%d); TS=$(date -u +%Y%m%dT%H%M%S)
cd "$repo"
# next free sequence number for today
n=1; while git show-ref --verify --quiet "refs/heads/preflight-bak-$day/$(printf %02d $n)" || git show-ref --verify --quiet "refs/remotes/origin/preflight-bak-$day/$(printf %02d $n)"; do n=$((n+1)); done
BR="preflight-bak-$day/$(printf %02d $n)"
# snapshot the working tree through a temporary index (current branch and index untouched)
tmpidx=$(mktemp); trap 'rm -f "$tmpidx"' EXIT
# --git-path resolves the index in linked worktrees too (.git is a file there); an empty temp
# file is a corrupt index to git, so drop it when there is nothing to seed from.
cp "$(git rev-parse --git-path index)" "$tmpidx" 2>/dev/null || rm -f "$tmpidx"
# .gitignore already keeps build outputs and node_modules out of `add -A`; only secrets need explicit excludes.
GIT_INDEX_FILE="$tmpidx" git add -A -- . ':(exclude,glob)**/.env' ':(exclude,glob)**/.env.*' ':(exclude).auth' ':(exclude)keys' ':(exclude,glob)**/*.p8' ':(exclude,glob)**/*.p12' ':(exclude,glob)**/*.pem' ':(exclude,glob)**/*.cer' ':(exclude,glob)**/*.provisionprofile' ':(exclude,glob)**/*.mobileprovision' ':(exclude,glob)**/.DS_Store' ':(exclude,glob)**/.frac' 2>&1 | grep -v '^hint:' || true
tree=$(GIT_INDEX_FILE="$tmpidx" git write-tree)
parent=$(git rev-parse --verify -q HEAD || true)
commit=$(printf 'preflight backup before %s\n\nFull working tree (tracked + untracked, secrets and build outputs excluded) as of %s.\n' "$reason" "$TS" | git commit-tree "$tree" ${parent:+-p "$parent"})
git update-ref "refs/heads/$BR" "$commit"
pushed="local-only (no origin)"
if git remote get-url origin >/dev/null 2>&1; then
  git push -q --no-verify origin "refs/heads/$BR:refs/heads/$BR" && pushed="pushed to origin" || pushed="PUSH FAILED (local-only, still at risk)"
fi
# content-level zip, independent of git
mkdir -p "$BAKS"
zipf="$BAKS/$name-bak-$TS.zip"
( cd "$repo/.." && zip -rq "$zipf" "$name" -x "$name/build/*" "$name/build-*/*" "$name/.git/*" "*/node_modules/*" "*.env" "*/.auth/*" "*/keys/*" "*.p8" "*.p12" "*.pem" "*/.DS_Store" )
[ -d "$MIRROR" ] && cp -p "$zipf" "$MIRROR/" 2>/dev/null || true
echo "preflight: $BR ($commit, $pushed); zip $zipf ($(du -h "$zipf" | cut -f1))"
