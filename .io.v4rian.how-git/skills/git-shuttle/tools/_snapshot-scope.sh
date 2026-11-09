# _snapshot-scope.sh - shared in-scope rules for the git-shuttle tools.
#
# Sourced (never executed) by content-match.sh and integration-check.sh so
# both tools judge the snapshot AND the repo trees with one rule set: the
# Step B coverage list of the git-shuttle skill plus the caller's
# --extra-exclude patterns.
#
# Built-in exclusions:
#   directories (any depth): .git node_modules dist build build-*
#   file names:              .git (a worktree gitfile) .DS_Store .session
#                            package-lock.json yarn.lock pnpm-lock.yaml
#                            *.log *.bak *_old.qml
# --extra-exclude PATTERN (repeatable), glob with * and ? (never **):
#   NAME/          a directory of that name at any depth (.auth/, keys/)
#   a/b/  or a/b   that path relative to the snapshot root and everything
#                  under it (app/sub/keys/); a leading / is the root too
#   NAME           a file name at any depth (.env, *.p8)
# The honoured rules are printed once on stderr ("# excludes: ...");
# an unsupported pattern (** or a bracket expression) is refused.
#
# Functions:
#   scope_setup [pattern...]     compile the rules; returns 2 on an
#                                unsupported pattern
#   scope_filter                 stdin lines (path or path<TAB>...) -> in-scope lines
#   snapshot_scope_hashes <dir> <out-file>
#       Writes "<path>TAB<key>" lines, byte sorted by path, for every
#       in-scope regular file and symlink under <dir>. A regular file's
#       key is `git hash-object --no-filters` of its bytes; a symlink's
#       key is "L:" plus the hash of its target string, so a link only
#       ever equals a 120000 entry and a file only a regular-file entry
#       (tree_keys gives repo entries the same shape; gitlinks are
#       "G:<sha>"). A symlinked directory is kept as a link and reported
#       on stderr (git stores the link, not the contents behind it); a
#       nested repository (a subdirectory holding .git) is reported and
#       walked as plain files. Paths containing a newline or a TAB cannot
#       travel in the TSV: they are reported on stderr and skipped.
#       Returns 3 after listing every unreadable regular file: hashing
#       around them would silently drop user work.

scope_glob_re() {
  printf '%s' "$1" | sed -e 's/[].[^$(){}|+\\]/\\&/g' -e 's/\*/[^\/]*/g' -e 's/?/[^\/]/g'
}

scope_setup() {
  local dir_re='\.git|node_modules|dist|build|build-[^/]*'
  local name_re='\.git|\.DS_Store|\.session|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|[^/]*\.log|[^/]*\.bak|[^/]*_old\.qml'
  local path_re='' pat re dirs='' names='' paths=''
  for pat in "$@"; do
    [ -n "$pat" ] || continue
    case "$pat" in
      *'**'*|*'['*|*']'*)
        echo "X exclude '$pat' is unsupported (no ** or bracket expressions; use NAME/, a/b/ or NAME)" >&2
        return 2 ;;
    esac
    # A leading / or ./ anchors at the snapshot root, which every path
    # form already is.
    while :; do
      case "$pat" in /*) pat="${pat#/}" ;; ./*) pat="${pat#./}" ;; *) break ;; esac
    done
    case "$pat" in
      */*/|*/*[!/]*)
        # Path form: that path and everything under it.
        re=$(scope_glob_re "${pat%/}")
        path_re="${path_re:+$path_re|}$re(/.*)?"; paths="$paths ${pat%/}/" ;;
      */)
        re=$(scope_glob_re "${pat%/}"); dir_re="$dir_re|$re"; dirs="$dirs $pat" ;;
      *)
        re=$(scope_glob_re "$pat"); name_re="$name_re|$re"; names="$names $pat" ;;
    esac
  done
  SCOPE_DIR_RE="^($dir_re)\$"
  SCOPE_NAME_RE="^($name_re)\$"
  SCOPE_PATH_RE="${path_re:+^($path_re)\$}"
  export SCOPE_DIR_RE SCOPE_NAME_RE SCOPE_PATH_RE
  echo "# excludes: dirs=[built-in${dirs}] names=[built-in${names}] paths=[${paths# }]" >&2
}

# Lines may be bare paths or "<path>TAB<more>"; only the path is judged.
scope_filter() {
  awk -F'\t' '
    BEGIN { d = ENVIRON["SCOPE_DIR_RE"]; n = ENVIRON["SCOPE_NAME_RE"]; p = ENVIRON["SCOPE_PATH_RE"] }
    {
      if (p != "" && $1 ~ p) next
      k = split($1, part, "/")
      if (part[k] ~ n) next
      for (i = 1; i < k; i++) if (part[i] ~ d) next
      print
    }'
}

snapshot_scope_hashes() {
  local dir="$1" out="$2"
  local abs work p target bad=0
  abs=$(cd "$dir" && pwd)
  work=$(mktemp -d -t snapshot-scope.XXXXXX)
  : > "$work/entries"
  while IFS= read -r -d '' p; do
    p="${p#./}"
    case "$p" in
      *"
"*|*"	"*) printf '  ! skipped (newline or TAB in path): %q\n' "$p" >&2; continue ;;
    esac
    printf '%s\n' "$p" >> "$work/entries"
  done < <(cd "$abs" && find . \( -name .git -o -name node_modules \) -prune -o \( -type f -o -type l \) -print0)
  ( cd "$abs" && find . -mindepth 2 -name .git -print ) | while IFS= read -r p; do
    p="${p#./}"
    echo "  ! nested repository ${p%/.git}: walked as plain files (a gitlink in the target reads as DELETED_IN_SNAPSHOT)" >&2
  done
  : > "$out"
  scope_filter < "$work/entries" | LC_ALL=C sort > "$work/all"
  : > "$work/files"; : > "$work/links"
  while IFS= read -r p; do
    if [ -L "$abs/$p" ]; then
      printf '%s\n' "$p" >> "$work/links"
      [ -d "$abs/$p" ] && echo "  ! symlinked directory $p: git stores the link ($(readlink "$abs/$p")), the contents behind it are not walked" >&2
    elif [ ! -r "$abs/$p" ]; then
      echo "  ! unreadable: $p" >&2
      bad=$((bad + 1))
    else
      printf '%s\n' "$p" >> "$work/files"
    fi
  done < "$work/all"
  if [ "$bad" -gt 0 ]; then
    echo "X $bad unreadable snapshot file(s); fix their permissions and rerun" >&2
    rm -rf "$work"
    return 3
  fi
  if [ -s "$work/files" ]; then
    SCOPE_ABS="$abs" awk '{ print ENVIRON["SCOPE_ABS"] "/" $0 }' "$work/files" \
      | ( cd / && git hash-object --no-filters --stdin-paths ) > "$work/oids" || { rm -rf "$work"; return 1; }
    paste "$work/files" "$work/oids" >> "$out"
  fi
  while IFS= read -r p; do
    target=$(readlink "$abs/$p")
    printf '%s\tL:%s\n' "$p" "$(printf '%s' "$target" | ( cd / && git hash-object --stdin ))" >> "$out"
  done < "$work/links"
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -o "$out" "$out"
  rm -rf "$work"
}

# tree_keys: ls-tree -r lines on stdin -> "<path>TAB<key>" with the same
# key shape as snapshot_scope_hashes (regular file: oid, 120000: L:oid,
# gitlink: G:sha). Paths keep the repo's spelling.
tree_keys() {
  awk -F'\t' '{ split($1, m, " ")
    if (m[2] == "blob") key = (m[1] == "120000") ? "L:" m[3] : m[3]
    else if (m[2] == "commit") key = "G:" m[3]
    else next
    print $2 "\t" key }'
}
