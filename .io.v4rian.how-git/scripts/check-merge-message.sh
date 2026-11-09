#!/usr/bin/env bash
# check-merge-message.sh - deterministic gate for the merge message shape.
#
# One rule for every merge commit (pool into dev, dev into main) and for
# the PR body that becomes it (git-merge-audit rules 1 to 6):
#
#   [MERGE] <source> into <target>: <version>
#
#   <1-3 sentence macro paragraph, ending with a period>
#
#   - <Topic>.
#       - <label>: <one-line summary>.
#
# The list is nested: every topic line is "- " at column 0 and holds at
# least one leaf "    - label: summary." indented four spaces; every list
# line ends with a period; no "Changes:" header; nothing follows the list.
# In connected mode the claim prepends one "PR #N <url>" reference
# paragraph to the merge body; --pr-ref lets that paragraph through.
#
# Used by githooks/commit-msg (merges into dev or main and every [MERGE]
# subject), githooks/pre-push (merge commits in the pushed range),
# claim-dev-merge.sh / claim-main-release.sh (before the amend) and
# validate-pr-open.sh (the PR body).
#
# Usage:
#   check-merge-message.sh --file <msg-file> [--pr-ref]   title + body
#   check-merge-message.sh --commit <rev> [--pr-ref]      a commit's message
#   check-merge-message.sh --body-file <file>             body only (PR body)
#   check-merge-message.sh --title "<subject>"            title only
#
# Exit 0 when the message passes, 1 with one "X ..." line per violation
# on stderr, 2 on usage errors. bash 3.2 and bash 5 compatible.

set -uo pipefail

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

MODE=""
ARG=""
PR_REF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file|--commit|--body-file|--title)
      [ $# -ge 2 ] || usage
      MODE="$1"; ARG="$2"; shift 2 ;;
    --pr-ref) PR_REF=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$MODE" ] || usage

ERRORS=0
fail() { echo "X merge message: $*" >&2; ERRORS=$((ERRORS + 1)); }

check_title() {
  local t="$1"
  local re='^\[MERGE\] ([^ ]+) into ([^ ]+): (v[0-9]+\.[0-9]+\.[0-9]+)$'
  if [[ ! "$t" =~ $re ]]; then
    fail "title must read '[MERGE] <source> into <target>: <version>' (got: $t)"
    return
  fi
  case "${BASH_REMATCH[1]}" in
    Merge|merge) fail "title repeats the word Merge after the [MERGE] tag" ;;
  esac
}

# check_body <file>: the body as written (no title line). Comment lines
# (git's "#" template) are ignored.
check_body() {
  local f="$1" out
  out=$(grep -v '^#' "$f" | awk -v prref="$PR_REF" '
    function err(m) { print m; bad = 1 }
    { sub(/\r$/, ""); lines[++n] = $0 }
    END {
      i = 1
      while (i <= n && lines[i] ~ /^[ \t]*$/) i++
      if (prref == 1 && i <= n && lines[i] ~ /^PR #[0-9]+( https?:\/\/[^ ]+)?$/) {
        i++
        if (i <= n && lines[i] !~ /^[ \t]*$/) err("the PR reference paragraph must be followed by a blank line")
        while (i <= n && lines[i] ~ /^[ \t]*$/) i++
      }
      if (i > n) { err("body is empty; it needs a macro paragraph and a nested list"); exit }
      para = ""
      while (i <= n && lines[i] !~ /^[ \t]*$/) {
        if (lines[i] ~ /^[ \t]*[-*] /) { err("body must open with a macro paragraph before the list (line: " lines[i] ")"); break }
        para = para (para == "" ? "" : " ") lines[i]; i++
      }
      if (para != "") {
        s = para; cnt = gsub(/[.!?]( +|$)/, "&", s)
        if (para !~ /\.$/) err("macro paragraph must end with a period")
        else if (cnt > 3) err("macro paragraph must be 1-3 sentences (found " cnt ")")
        if (para ~ /^Changes:/) err("no Changes: header")
        if (para ~ /^\[[A-Z]+\]/) err("macro paragraph must not open with a [TAG]; the tag belongs to the title")
      }
      blanks = 0
      while (i <= n && lines[i] ~ /^[ \t]*$/) { i++; blanks++ }
      if (i > n) { if (!bad) err("body needs a nested list after the macro paragraph"); exit }
      if (blanks != 1) err("exactly one blank line separates the macro paragraph from the list")
      topics = 0; leaves = 0
      for (; i <= n; i++) {
        l = lines[i]
        if (l ~ /^[ \t]*$/) {
          rest = 0
          for (j = i + 1; j <= n; j++) if (lines[j] !~ /^[ \t]*$/) rest = 1
          if (rest) err("the list must be one block with no blank lines inside or after it")
          break
        }
        if (l ~ /^Changes:/) { err("no Changes: header"); continue }
        if (l ~ /^- [^ ]/) {
          if (topics > 0 && leaves == 0) err("topic without a nested leaf: " prev)
          topics++; leaves = 0; prev = l
          if (l !~ /\.$/) err("list line must end with a period: " l)
          continue
        }
        if (l ~ /^    - [^ ]/) {
          if (topics == 0) err("leaf before any topic: " l)
          leaves++
          if (l !~ /^    - [^:]+: [^ ].*\.$/) err("leaf must read \"    - <label>: <summary>.\": " l)
          continue
        }
        err("not a list line (topics \"- \" at column 0, leaves \"    - \" indented four spaces): " l)
      }
      if (topics == 0) err("body needs a nested list of topics")
      else if (leaves == 0) err("topic without a nested leaf: " prev)
    }')
  if [ -n "$out" ]; then
    while IFS= read -r line; do fail "$line"; done <<EOF
$out
EOF
  fi
}

TMP_BODY=""
cleanup() { [ -n "$TMP_BODY" ] && rm -f "$TMP_BODY"; return 0; }
trap cleanup EXIT

check_message_file() {
  local f="$1" title
  title=$(grep -v '^#' "$f" | head -n1 | tr -d '\r')
  check_title "$title"
  TMP_BODY=$(mktemp "${TMPDIR:-/tmp}/merge-body.XXXXXX")
  grep -v '^#' "$f" | sed '1d' > "$TMP_BODY"
  check_body "$TMP_BODY"
}

case "$MODE" in
  --title) check_title "$ARG" ;;
  --body-file)
    [ -f "$ARG" ] || { echo "X check-merge-message: no such file: $ARG" >&2; exit 2; }
    check_body "$ARG" ;;
  --file)
    [ -f "$ARG" ] || { echo "X check-merge-message: no such file: $ARG" >&2; exit 2; }
    check_message_file "$ARG" ;;
  --commit)
    MSG=$(mktemp "${TMPDIR:-/tmp}/merge-msg.XXXXXX")
    if ! git log -1 --format=%B "$ARG" > "$MSG" 2>/dev/null; then
      rm -f "$MSG"; echo "X check-merge-message: unknown revision: $ARG" >&2; exit 2
    fi
    check_message_file "$MSG"; rm -f "$MSG" ;;
esac

if [ "$ERRORS" -gt 0 ]; then
  echo "  The ruled shape (git-merge-audit rule 5):" >&2
  echo "    [MERGE] <source> into <target>: <version>" >&2
  echo "    <blank>" >&2
  echo "    <1-3 sentence macro paragraph.>" >&2
  echo "    <blank>" >&2
  echo "    - <Topic>." >&2
  echo "        - <label>: <one-line summary>." >&2
  exit 1
fi
exit 0
