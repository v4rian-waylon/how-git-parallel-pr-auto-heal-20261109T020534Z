#!/bin/bash
# how-git agent hook tool: git-preflight. Two independent working-tree backups BEFORE a destructive
# op, without touching the current branch or index. 1) preflight-bak-YYYY-MM-DD/NN ref built from a
# temp index of the full working tree (tracked + untracked, secrets/build/node_modules excluded),
# pushed to origin. 2) bak zip of the working tree into HOW_GIT_BAKS_DIR (+ optional mirror).
# Reuse: when a preflight younger than PREFLIGHT_MAX_AGE_H (12) exists for the same HEAD and the
# same working-tree snapshot (tree hash), with its zip still on disk (and its ref on origin when
# the repo has one), nothing new is written.
# Retention: only the newest PREFLIGHT_KEEP (5) <repo>-bak-*.zip per repo stay in the bak dir and
# the mirror; older ones are moved to the Trash (HOW_GIT_TRASH_DIR when set, else /usr/bin/trash,
# else $HOME/.Trash), never deleted.
# Identity: exported GIT_AUTHOR_* / GIT_COMMITTER_* are honoured; when only one side is exported
# the other follows it, so a preflight never mixes an exported author with the ambient committer.
# Config: HOW_GIT_BAKS_DIR (default $HOME/.how-git/baks; BAKS_DIR is a legacy alias),
# HOW_GIT_BAKS_MIRROR (copy of every zip, off by default; BAKS_MIRROR is a legacy alias).
# Usage: git-preflight.sh <repo-path> ["reason"]
set -eu
repo=$(cd "${1:?repo path}" && git rev-parse --show-toplevel)
reason="${2:-destructive op}"
BAKS="${HOW_GIT_BAKS_DIR:-${BAKS_DIR:-$HOME/.how-git/baks}}"
MIRROR="${HOW_GIT_BAKS_MIRROR:-${BAKS_MIRROR:-}}"
MAXH="${PREFLIGHT_MAX_AGE_H:-12}"
KEEP="${PREFLIGHT_KEEP:-5}"
name=$(basename "$repo"); day=$(date +%Y-%m-%d); TS=$(date -u +%Y%m%dT%H%M%SZ)
cd "$repo"

# identity: one exported side completes the other
if [ -n "${GIT_AUTHOR_NAME:-}" ] && [ -z "${GIT_COMMITTER_NAME:-}" ]; then export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"; fi
if [ -n "${GIT_AUTHOR_EMAIL:-}" ] && [ -z "${GIT_COMMITTER_EMAIL:-}" ]; then export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"; fi
if [ -n "${GIT_COMMITTER_NAME:-}" ] && [ -z "${GIT_AUTHOR_NAME:-}" ]; then export GIT_AUTHOR_NAME="$GIT_COMMITTER_NAME"; fi
if [ -n "${GIT_COMMITTER_EMAIL:-}" ] && [ -z "${GIT_AUTHOR_EMAIL:-}" ]; then export GIT_AUTHOR_EMAIL="$GIT_COMMITTER_EMAIL"; fi

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
# move a file to the Trash, never delete it
to_trash() {
  if [ -n "${HOW_GIT_TRASH_DIR:-}" ]; then mkdir -p "$HOW_GIT_TRASH_DIR" && mv "$1" "$HOW_GIT_TRASH_DIR/"
  elif [ -x /usr/bin/trash ]; then /usr/bin/trash "$1"
  else mkdir -p "$HOME/.Trash" && mv "$1" "$HOME/.Trash/"; fi
}
# keep the newest $KEEP zips of this repo in a directory, move the rest to the Trash
retain() {
  [ -n "$1" ] && [ -d "$1" ] || return 0
  ls -t "$1/$name"-bak-[0-9]*.zip 2>/dev/null | tail -n +$((KEEP + 1)) | while IFS= read -r old; do
    to_trash "$old" >/dev/null 2>&1 || echo "preflight: could not trash $old" >&2
  done
}

# snapshot the working tree through a temporary index (current branch and index untouched)
tmpidx=$(mktemp); trap 'rm -f "$tmpidx"' EXIT
# --git-path resolves the index in linked worktrees too (.git is a file there); an empty temp
# file is a corrupt index to git, so drop it when there is nothing to seed from.
cp "$(git rev-parse --git-path index)" "$tmpidx" 2>/dev/null || rm -f "$tmpidx"
# Stage by explicit path list, never `git add -A`: the exact set of tracked-modified/deleted plus
# untracked-not-ignored paths, minus the excludes below, fed to update-index. A path git cannot read
# fails the preflight instead of silently dropping out.
# Secrets match at ANY depth (the preflight ref is pushed to origin): .auth/ keys/ .frac/ dirs, .env,
# .env.*, *.env, *.p8 *.p12 *.pem *.cer *.provisionprofile *.mobileprovision, .DS_Store. They are also
# dropped from the snapshot when tracked. Non-secret zip excludes (node_modules at any depth, top-level
# build/ and build-*/) are kept out of untracked staging only. The zip below uses the same set.
SECRET_GLOBS=( '**/.auth' '**/.auth/**' '**/keys' '**/keys/**' '**/.frac' '**/.frac/**' '**/.env' '**/.env.*' '**/*.env'
  '**/*.p8' '**/*.p12' '**/*.pem' '**/*.cer' '**/*.provisionprofile' '**/*.mobileprovision' '**/.DS_Store' )
BULK_GLOBS=( '**/node_modules/**' 'build/**' 'build-*/**' )
SECRET_PS=(); EXCL_PS=()
for gl in "${SECRET_GLOBS[@]}"; do SECRET_PS+=( ":(glob)$gl" ); EXCL_PS+=( ":(exclude,glob)$gl" ); done
for gl in "${BULK_GLOBS[@]}"; do EXCL_PS+=( ":(exclude,glob)$gl" ); done
# untracked nested repos are listed as "dir/"; update-index wants the bare path (records a gitlink, as add did)
git ls-files -z --modified --others --exclude-standard -- . "${EXCL_PS[@]}" \
  | perl -0 -pe 's{/\0}{\0}g' \
  | GIT_INDEX_FILE="$tmpidx" git update-index -z --add --remove --stdin
# tracked secrets never ride along to origin either
GIT_INDEX_FILE="$tmpidx" git ls-files -z --cached -- "${SECRET_PS[@]}" \
  | GIT_INDEX_FILE="$tmpidx" git update-index -z --force-remove --stdin
tree=$(GIT_INDEX_FILE="$tmpidx" git write-tree)
parent=$(git rev-parse --verify -q HEAD || true)
has_origin=0; git remote get-url origin >/dev/null 2>&1 && has_origin=1

# ---- reuse a fresh preflight of the same HEAD + same working tree ----
now=$(date +%s); limit=$(( MAXH * 3600 ))
while read -r ts ref; do
  [ -n "$ts" ] || break
  [ $(( now - ts )) -le "$limit" ] || break             # sorted newest first: the rest are older
  [ "$(git rev-parse "$ref^{tree}")" = "$tree" ] || continue
  [ "$(git rev-parse -q --verify "$ref^1" 2>/dev/null || true)" = "$parent" ] || continue
  oldzip=$(git log -1 --format=%B "$ref" | sed -n 's/^Zip: //p' | head -1)
  [ -n "$oldzip" ] && [ -f "$oldzip" ] || continue
  [ $(( now - $(mtime "$oldzip") )) -le "$limit" ] || continue
  br=${ref#refs/heads/}
  if [ "$has_origin" = 1 ]; then
    [ "$(git rev-parse -q --verify "refs/remotes/origin/$br" 2>/dev/null || true)" = "$(git rev-parse "$ref")" ] || continue
  fi
  retain "$BAKS"; retain "$MIRROR"
  echo "preflight: reused $br ($(git rev-parse --short "$ref"), same HEAD and working tree, $(( (now - ts) / 60 )) min old); zip $oldzip"
  exit 0
done <<EOF
$(git for-each-ref --sort=-committerdate --format='%(committerdate:unix) %(refname)' 'refs/heads/preflight-bak-*' 'refs/heads/preflight-bak-*/*' 2>/dev/null)
EOF

# next free sequence number for today
n=1; while git show-ref --verify --quiet "refs/heads/preflight-bak-$day/$(printf %02d $n)" || git show-ref --verify --quiet "refs/remotes/origin/preflight-bak-$day/$(printf %02d $n)"; do n=$((n+1)); done
BR="preflight-bak-$day/$(printf %02d $n)"
mkdir -p "$BAKS"
zipf="$BAKS/$name-bak-$TS.zip"
commit=$(printf 'preflight backup before %s\n\nFull working tree (tracked + untracked, secrets and build outputs excluded) as of %s.\n\nZip: %s\n' "$reason" "$TS" "$zipf" | git commit-tree "$tree" ${parent:+-p "$parent"})
git update-ref "refs/heads/$BR" "$commit"
pushed="local-only (no origin)"
if [ "$has_origin" = 1 ]; then
  git push -q --no-verify origin "refs/heads/$BR:refs/heads/$BR" && pushed="pushed to origin" || pushed="PUSH FAILED (local-only, still at risk)"
fi
# content-level zip, independent of git (zip wildcards cross '/', so */x/* matches at any depth)
( cd "$repo/.." && zip -rq "$zipf" "$name" -x "$name/build/*" "$name/build-*/*" "$name/.git/*" "*/node_modules/*" "*/.auth" "*/.auth/*" "*/keys" "*/keys/*" "*/.frac/*" "*.env" "*/.env.*" "*.p8" "*.p12" "*.pem" "*.cer" "*.provisionprofile" "*.mobileprovision" "*/.DS_Store" )
[ -n "$MIRROR" ] && [ -d "$MIRROR" ] && cp -p "$zipf" "$MIRROR/" 2>/dev/null || true
retain "$BAKS"; retain "$MIRROR"
echo "preflight: $BR ($commit, $pushed); zip $zipf ($(du -h "$zipf" | cut -f1))"
