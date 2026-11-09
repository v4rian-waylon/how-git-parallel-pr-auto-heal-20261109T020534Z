#!/usr/bin/env bash
# content-match.sh - rank the commits of a target repo by how closely their
# tree equals a working-tree snapshot, both ways.
#
# git-shuttle Step C. Deterministic: no AI, no network, no writes to the
# target repo. The caller applies the skill's decision rules to the ranking.
#
# Usage:
#   content-match.sh <snapshot-dir> <target-repo> [options]
#
# Options:
#   --since DATE            only scan commits since DATE (git log --since)
#   --until DATE            only scan commits up to DATE (git log --until)
#   --branches a,b,c        comma separated revs to scan (default: --all);
#                           each must resolve to a commit
#   --top N                 rows to print (default 10; 0 prints every commit)
#   --path-prefix DIR       the snapshot root maps to DIR inside the target
#                           (relative; ./DIR and DIR/ accepted); only tree
#                           files under DIR take part
#   --extra-exclude PATTERN extra exclusion, repeatable: NAME/ is a
#                           directory at any depth (.auth/, keys/), a/b/
#                           (or a/b) that path and everything under it,
#                           NAME a file name (.env, *.p8)
#   --verbose               after the ranking, list per-file differences
#                           against the top commit (NEW_IN_SNAPSHOT,
#                           MODIFIED, DELETED_IN_SNAPSHOT)
#   -h, --help              print this help
#
# Both sides use the same scope rules (_snapshot-scope.sh): build output,
# lockfiles, logs and the extra excludes count on neither side. Symlinks
# compare by target string against 120000 entries only (a regular file
# with the same bytes is MODIFIED); a nested repository in the snapshot is
# reported and walked as files. Blobs are compared as
# raw bytes (--no-filters): with text=auto or eol attributes a CRLF copy of
# an LF blob reads as MODIFIED.
#
# Output (stdout): one '#'-prefixed header line, then TSV rows
#   <sha> <matched>/<total> <extra_in_commit> <pct>% <author-date> <subject>
# matched = snapshot files equal at the same path; total = in-scope snapshot
# files; extra_in_commit = in-scope commit files the snapshot lacks (what
# the snapshot deleted); pct = matched / (total + extra_in_commit), so
# 100.0% means the commit tree IS the snapshot. Sorted by pct, then
# matched, descending, ties broken by the EARLIEST author date (the skill's
# tie rule), then by sha. Progress and warnings go to stderr.
#
# Decision rules (git-shuttle Step C, applied by the caller):
#   100% (extra 0)     snapshot already represented at that commit
#   >=90% unambiguous  parent C*, small diff to atomize (deletions included)
#   <90% unambiguous   parent C*, larger diff to atomize
#   ties at the top    earliest by author date (first row already is)
#   <30%               run integration-check.sh before halting
#
# Exit codes: 0 ranking printed; 1 snapshot has no in-scope file;
#             2 usage error (bad flag, missing dir, not a git repo,
#             unknown rev, absolute or escaping prefix, unsupported
#             exclude); 3 unreadable snapshot file(s), each named on stderr.

set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=_snapshot-scope.sh
. "$TOOLS_DIR/_snapshot-scope.sh"

POSITIONAL=()
SINCE=""
UNTIL=""
BRANCHES=""
TOP_N=10
PATH_PREFIX=""
VERBOSE=0
EXTRA_EXCLUDES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --since)         SINCE="$2"; shift 2 ;;
    --until)         UNTIL="$2"; shift 2 ;;
    --branches)      BRANCHES="$2"; shift 2 ;;
    --top)           TOP_N="$2"; shift 2 ;;
    --path-prefix)   PATH_PREFIX="$2"; shift 2 ;;
    --extra-exclude) EXTRA_EXCLUDES+=("$2"); shift 2 ;;
    --verbose)       VERBOSE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*)              echo "X content-match: unknown flag $1" >&2; exit 2 ;;
    *)               POSITIONAL+=("$1"); shift ;;
  esac
done

if [ "${#POSITIONAL[@]}" -ne 2 ]; then
  echo "X content-match: want <snapshot-dir> <target-repo> (see --help)" >&2
  exit 2
fi
case "$TOP_N" in ''|*[!0-9]*) echo "X content-match: --top wants a number (got '$TOP_N')" >&2; exit 2 ;; esac

SNAPSHOT_DIR="${POSITIONAL[0]}"
TARGET_REPO="${POSITIONAL[1]}"
if [ ! -d "$SNAPSHOT_DIR" ]; then
  echo "X content-match: snapshot dir not found: $SNAPSHOT_DIR" >&2
  exit 2
fi
if ! git -C "$TARGET_REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "X content-match: not a git repo: $TARGET_REPO" >&2
  exit 2
fi

# Normalise the prefix to "dir/sub" (no ./, no trailing slash); refuse
# absolute or escaping prefixes, which can never match a tree path.
PREFIX="$PATH_PREFIX"
while :; do
  case "$PREFIX" in
    ./*) PREFIX="${PREFIX#./}" ;;
    */)  PREFIX="${PREFIX%/}" ;;
    *)   break ;;
  esac
done
[ "$PREFIX" = "." ] && PREFIX=""
case "/$PREFIX/" in
  //?*|*/../*) echo "X content-match: --path-prefix must be relative inside the repo (got '$PATH_PREFIX')" >&2; exit 2 ;;
esac

REVS=()
if [ -n "$BRANCHES" ]; then
  IFS=',' read -r -a raw_revs <<<"$BRANCHES"
  for r in "${raw_revs[@]}"; do
    r=$(printf '%s' "$r" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$r" ] || continue
    if ! git -C "$TARGET_REPO" rev-parse --verify --quiet "$r^{commit}" >/dev/null; then
      echo "X content-match: unknown rev '$r' in $TARGET_REPO" >&2
      exit 2
    fi
    REVS+=("$r")
  done
  if [ "${#REVS[@]}" -eq 0 ]; then
    echo "X content-match: --branches names no rev" >&2
    exit 2
  fi
else
  REVS=(--all)
fi
LOG_ARGS=()
[ -n "$SINCE" ] && LOG_ARGS+=("--since=$SINCE")
[ -n "$UNTIL" ] && LOG_ARGS+=("--until=$UNTIL")

if [ "$(git -C "$TARGET_REPO" rev-parse --is-shallow-repository)" = "true" ]; then
  echo "# WARN: shallow repository $TARGET_REPO: commits beyond the graft are not scanned" >&2
fi

TAB=$(printf '\t')
WORK=$(mktemp -d -t content-match.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

scope_setup ${EXTRA_EXCLUDES[@]+"${EXTRA_EXCLUDES[@]}"} || exit 2
rc=0; snapshot_scope_hashes "$SNAPSHOT_DIR" "$WORK/snap.tsv" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
TOTAL=$(wc -l < "$WORK/snap.tsv" | tr -d ' ')
if [ "$TOTAL" -eq 0 ]; then
  echo "X content-match: no in-scope file under $SNAPSHOT_DIR" >&2
  exit 1
fi

git -C "$TARGET_REPO" log ${LOG_ARGS[@]+"${LOG_ARGS[@]}"} --format='%H' "${REVS[@]}" -- > "$WORK/commits"
COMMIT_COUNT=$(wc -l < "$WORK/commits" | tr -d ' ')
{
  echo "# snapshot=$SNAPSHOT_DIR"
  echo "# target=$TARGET_REPO"
  echo "# in_scope_files=$TOTAL path_prefix='$PREFIX'"
  echo "# candidate_commits=$COMMIT_COUNT"
} >&2

# A commit tree in snapshot coordinates: "<path>TAB<key>" (tree_keys:
# regular file oid, L:oid for a 120000 link, G:sha for a gitlink) under
# the prefix, prefix stripped, run through the same scope rules, byte
# sorted by path. A gitlink never equals a snapshot entry, so a submodule
# shows as extra_in_commit / DELETED_IN_SNAPSHOT instead of vanishing.
tree_tsv() {
  git -C "$TARGET_REPO" -c core.quotePath=false ls-tree -r "$1" | tree_keys \
    | SCOPE_PRE="${PREFIX:+$PREFIX/}" awk -F'\t' '
        BEGIN { pre = ENVIRON["SCOPE_PRE"] }
        { path = $1
          if (pre != "") { if (index(path, pre) != 1) next; path = substr(path, length(pre) + 1) }
          print path "\t" $2 }' \
    | scope_filter | LC_ALL=C sort -t "$TAB" -k1,1
}

: > "$WORK/results"
i=0
while IFS= read -r sha; do
  i=$((i + 1))
  [ $((i % 100)) -eq 0 ] && echo "# scanned $i / $COMMIT_COUNT" >&2
  tree_tsv "$sha" > "$WORK/tree"
  match=$(LC_ALL=C join -t "$TAB" -1 1 -2 1 "$WORK/snap.tsv" "$WORK/tree" \
    | awk -F'\t' '$2 == $3 { n++ } END { print n + 0 }')
  extra=$(LC_ALL=C join -t "$TAB" -1 1 -2 1 -v 2 "$WORK/snap.tsv" "$WORK/tree" | wc -l | tr -d ' ')
  git -C "$TARGET_REPO" log -1 --format="%at${TAB}%aI${TAB}%s" "$sha" > "$WORK/meta"
  IFS="$TAB" read -r at adate subj < "$WORK/meta" || true
  read -r score pct <<EOF2
$(awk -v m="$match" -v t="$TOTAL" -v x="$extra" 'BEGIN { u = t + x; printf "%d %.1f\n", int(m * 1000000 / u), (m / u) * 100 }')
EOF2
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$score" "$match" "$at" "$sha" "$TOTAL" "$extra" "$pct" "$adate" "${subj:0:80}" >> "$WORK/results"
done < "$WORK/commits"

LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2nr -k3,3n -k4,4 "$WORK/results" > "$WORK/ranked"
echo "# sha${TAB}matched/total${TAB}extra_in_commit${TAB}pct${TAB}author_date${TAB}subject"
if [ "$TOP_N" -eq 0 ]; then cat "$WORK/ranked"; else head -n "$TOP_N" "$WORK/ranked"; fi \
  | awk -F'\t' 'BEGIN { OFS = "\t" } { print $4, $2 "/" $5, $6, $7 "%", $8, $9 }'

if [ "$VERBOSE" = "1" ] && [ -s "$WORK/ranked" ]; then
  top=$(head -1 "$WORK/ranked" | cut -f4)
  echo
  echo "# per-file differences against $top (paths relative to the snapshot root)"
  tree_tsv "$top" > "$WORK/tree"
  LC_ALL=C join -t "$TAB" -1 1 -2 1 -a 1 -e MISSING -o '0,1.2,2.2' "$WORK/snap.tsv" "$WORK/tree" \
    | awk -F'\t' '$2 != $3 { print (($3 == "MISSING") ? "NEW_IN_SNAPSHOT" : "MODIFIED") "\t" $1 }'
  LC_ALL=C join -t "$TAB" -1 1 -2 1 -v 2 "$WORK/snap.tsv" "$WORK/tree" \
    | awk -F'\t' '{ print "DELETED_IN_SNAPSHOT\t" $1 }'
fi
exit 0
