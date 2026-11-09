#!/usr/bin/env bash
# integration-check.sh - classify every in-scope file of a snapshot as
# INTEGRATED (its exact bytes already lived at this very path in one of
# the related repos), INTEGRATED_ELSEWHERE (the bytes are stored, but only
# at other paths) or NEW (no related repo has ever stored that blob).
#
# git-shuttle Step C.5. Deterministic: no AI, no network, no writes to any
# repo. Settles "abandoned" versus "extracted into a sibling repo", which
# a single-target content-match cannot see.
#
# Usage:
#   integration-check.sh <snapshot-dir> <repo[,repo...]> [options]
#
# Options:
#   --extra-exclude PATTERN  extra exclusion, repeatable: NAME/ is a
#                            directory at any depth (.auth/, keys/), a/b/
#                            (or a/b) that path and everything under it,
#                            NAME a file name (.env, *.p8)
#   -h, --help            print this help
#
# A blob counts as stored when it is reachable from any ref of the repo
# (git rev-list --objects --all: branches, remote-tracking refs, tags,
# stash). Reflog-only and unreachable objects do not count: a later gc
# can drop them, so relying on them would lose work.
#
# Scope rules, symlink and newline handling are shared with
# content-match.sh (_snapshot-scope.sh). A shallow repo is flagged on
# stderr: its first-commit answers stop at the graft.
#
# Output (stdout): one '#'-prefixed header line, then TSV rows sorted by
# path:
#   <status> <path> <blob-oid> <repos|-> <first-commit|-> <known-paths|->
# <repos> lists every related repo (as given on the command line) that
# stores the blob; <first-commit> is "<repo>@<sha>", the oldest commit of
# the first listed repo that introduces the blob; <known-paths> lists
# "<repo>:<path>" for every path the blob ever lived at (at most 5; a
# link carries " (link)"). INTEGRATED needs the same path AND the same
# kind: a regular file equal to a stored link's target is not the link.
# Step D: INTEGRATED is skipped; INTEGRATED_ELSEWHERE in the target (the
# first repo) is a move or copy still to commit; INTEGRATED_ELSEWHERE only
# in a sibling repo is extracted work (recorded, not recommitted). The
# stderr summary line is "# integrated=I elsewhere=E new=N total=T".
#
# Exit codes: 0 classification printed; 1 snapshot has no in-scope file;
#             2 usage error (bad flag, missing dir, a repo is not a git
#             repo, unsupported exclude; a mistyped repo would silently
#             turn every file NEW); 3 unreadable snapshot file(s), each
#             named on stderr.

set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_snapshot-scope.sh
. "$TOOLS_DIR/_snapshot-scope.sh"

POSITIONAL=()
EXTRA_EXCLUDES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --extra-exclude) EXTRA_EXCLUDES+=("$2"); shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    -*)              echo "X integration-check: unknown flag $1" >&2; exit 2 ;;
    *)               POSITIONAL+=("$1"); shift ;;
  esac
done

if [ "${#POSITIONAL[@]}" -ne 2 ]; then
  echo "X integration-check: want <snapshot-dir> <repo[,repo...]> (see --help)" >&2
  exit 2
fi
SNAPSHOT_DIR="${POSITIONAL[0]}"
if [ ! -d "$SNAPSHOT_DIR" ]; then
  echo "X integration-check: snapshot dir not found: $SNAPSHOT_DIR" >&2
  exit 2
fi
REPOS=()
IFS=',' read -r -a REPOS <<<"${POSITIONAL[1]}"
if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "X integration-check: no related repo given" >&2
  exit 2
fi
for r in "${REPOS[@]}"; do
  if ! git -C "$r" rev-parse --git-dir >/dev/null 2>&1; then
    echo "X integration-check: not a git repo: $r" >&2
    exit 2
  fi
done

TAB=$(printf '\t')
WORK=$(mktemp -d -t integration-check.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

for r in "${REPOS[@]}"; do
  if [ "$(git -C "$r" rev-parse --is-shallow-repository)" = "true" ]; then
    echo "# WARN: shallow repository $r: blobs and first commits beyond the graft are not seen" >&2
  fi
done

scope_setup ${EXTRA_EXCLUDES[@]+"${EXTRA_EXCLUDES[@]}"} || exit 2
rc=0; snapshot_scope_hashes "$SNAPSHOT_DIR" "$WORK/snap.tsv" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
TOTAL=$(wc -l < "$WORK/snap.tsv" | tr -d ' ')
if [ "$TOTAL" -eq 0 ]; then
  echo "X integration-check: no in-scope file under $SNAPSHOT_DIR" >&2
  exit 1
fi
echo "# snapshot=$SNAPSHOT_DIR in_scope_files=$TOTAL" >&2

# Snapshot rows keyed by raw oid for the set joins, with the entry kind
# (F regular file, L symlink; the key shape of _snapshot-scope.sh).
awk -F'\t' 'BEGIN { OFS = "\t" } { k = "F"; o = $2; if (o ~ /^L:/) { k = "L"; o = substr(o, 3) }; print o, k, $1 }' "$WORK/snap.tsv" \
  | LC_ALL=C sort -t "$TAB" -k1,1 > "$WORK/by-oid"
cut -f1 "$WORK/by-oid" | LC_ALL=C sort -u > "$WORK/snap-oids"

# Per repo: the subset of snapshot oids the repo stores (sorted, unique).
idx=0
for r in "${REPOS[@]}"; do
  idx=$((idx + 1))
  git -C "$r" rev-list --objects --all | cut -d' ' -f1 | LC_ALL=C sort -u > "$WORK/objs"
  LC_ALL=C comm -12 "$WORK/snap-oids" "$WORK/objs" > "$WORK/hit.$idx"
  echo "# $r: $(wc -l < "$WORK/objs" | tr -d ' ') reachable objects, $(wc -l < "$WORK/hit.$idx" | tr -d ' ') snapshot blobs stored" >&2
done

# First introducing commit, resolved once per oid (several snapshot paths
# can share one blob).
first_commit() {
  local oid="$1" i=0 r sha
  for r in "${REPOS[@]}"; do
    i=$((i + 1))
    if LC_ALL=C grep -qxF "$oid" "$WORK/hit.$i"; then
      sha=$(git -C "$r" log --all --reverse --format=%H --find-object="$oid" | head -1)
      printf '%s@%s' "$r" "${sha:--}"
      return 0
    fi
  done
  printf -- '-'
}

# Every place the blob ever lived, as "<repo>TAB<kind>TAB<path>" (kind L
# for a 120000 link, F otherwise), read from the raw diffs that add or
# remove it, so a link and a file with equal bytes stay apart.
known_paths() {
  local oid="$1" i=0 r
  for r in "${REPOS[@]}"; do
    i=$((i + 1))
    LC_ALL=C grep -qxF "$oid" "$WORK/hit.$i" || continue
    git -C "$r" -c core.quotePath=false log --all -m --format= --raw --no-abbrev --no-renames --find-object="$oid" \
      | REPO="$r" OID="$oid" awk -F'\t' '
          BEGIN { r = ENVIRON["REPO"]; o = ENVIRON["OID"] }
          /^:/ { split($1, m, " "); sub(/^:/, "", m[1])
                 if (m[4] == o) mode = m[2]; else if (m[3] == o) mode = m[1]; else next
                 print r "\t" ((mode == "120000") ? "L" : "F") "\t" $2 }' \
      | LC_ALL=C sort -u
  done
}

integrated=0
elsewhere=0
new=0
: > "$WORK/rows"
prev_oid=""
prev_repos=""
prev_first=""
while IFS="$TAB" read -r oid kind path; do
  if [ "$oid" != "$prev_oid" ]; then
    repos=""
    i=0
    for r in "${REPOS[@]}"; do
      i=$((i + 1))
      if LC_ALL=C grep -qxF "$oid" "$WORK/hit.$i"; then
        repos="${repos:+$repos,}$r"
      fi
    done
    if [ -n "$repos" ]; then
      first=$(first_commit "$oid")
      known_paths "$oid" > "$WORK/paths"
    else
      first="-"; : > "$WORK/paths"
    fi
    prev_oid="$oid"; prev_repos="$repos"; prev_first="$first"
  fi
  if [ -z "$prev_repos" ]; then
    printf 'NEW\t%s\t%s\t-\t-\t-\n' "$path" "$oid" >> "$WORK/rows"
    new=$((new + 1))
  elif P="$path" K="$kind" awk -F'\t' '$2 == ENVIRON["K"] && $3 == ENVIRON["P"] { f = 1 } END { exit !f }' "$WORK/paths"; then
    printf 'INTEGRATED\t%s\t%s\t%s\t%s\t%s\n' "$path" "$oid" "$prev_repos" "$prev_first" "$path" >> "$WORK/rows"
    integrated=$((integrated + 1))
  else
    printf 'INTEGRATED_ELSEWHERE\t%s\t%s\t%s\t%s\t%s\n' "$path" "$oid" "$prev_repos" "$prev_first" \
      "$(awk -F'\t' '{ print $1 ":" $3 (($2 == "L") ? " (link)" : "") }' "$WORK/paths" | head -5 | paste -s -d, -)" >> "$WORK/rows"
    elsewhere=$((elsewhere + 1))
  fi
done < "$WORK/by-oid"

echo "# status${TAB}path${TAB}blob${TAB}repos${TAB}first_commit${TAB}known_paths"
LC_ALL=C sort -t "$TAB" -k2,2 "$WORK/rows"
echo "# integrated=$integrated elsewhere=$elsewhere new=$new total=$TOTAL" >&2
exit 0
