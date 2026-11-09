#!/usr/bin/env bash
# lint-protocol.sh - deterministic consistency lint for the how-git protocol
# text (skills, loader, docs) and the allocator. No AI, no network.
#
# Usage:
#   lint-protocol.sh [--root <repo>] [--copy <path>]... [--staged | <file>...]
#
#   no <file>       lint every protocol file in the namespace (CI mode) and
#                   run the allocator kind check.
#   <file>...       lint only these repo-relative or absolute files;
#                   non-protocol files are ignored, and the allocator
#                   kind check runs when the allocator or _lib.sh is listed.
#   --staged        pre-commit mode on the staged protocol files, failing only
#                   on findings in lines the commit adds (or on findings
#                   with no line), so a commit never inherits older debt.
#   --copy <path>   also compare the canonical namespace with a copy (a repo
#                   root holding .io.v4rian.how-git/, or the namespace dir
#                   itself, e.g. the fractaris copy) and report the drift.
#   --root <repo>   repo to lint (default: the repo holding this script).
#
# Rules (each finding prints "RULE<TAB>file:line<TAB>detail"):
#   MEMORY-LINK   a [[name]] link in a skill that is not an in-tree skill
#                 (memory notes resolve on one machine only), or a
#                 memory/<x>.md path or `feedback_*`-style note name.
#   DEAD-REF      bin/<tool>, scripts/<path>, skills/*/tools/<tool>,
#                 <workflow>.yml or `git-*` skill named but absent. A line
#                 recording the removal (removed, folded into, earlier,
#                 formerly) passes.
#   RETIRED       cat VERSION, [CLEANUP], a Changes: header, "straight to
#                 dev", or feature/ outside a legacy section. A line that
#                 negates the phrase (no, never, not, retired) passes.
#   FIXED-TMP     a fixed /tmp path in a skill (use mktemp under TMPDIR); a
#                 line that forbids it (not, never, don't) passes.
#   KIND-DRIFT    a kind list in the allocator differing from HG_BRANCH_KINDS
#                 in _lib.sh, or _lib.sh without HG_BRANCH_KINDS.
#   COPY-DRIFT    the --copy tree differs from the canonical namespace.
#   PERSONAL-PATH a home or session path (/Users/<name>/, /home/<name>/,
#                 -Users-<name>-, a claude session temp dir) in any namespace
#                 Markdown file, history included; write <workspace>,
#                 <scratchpad> or <tmp>. The frozen benchmark baseline under
#                 bench/arms/ is a verbatim copy and is skipped.
#
# Exit: 0 clean, 1 findings, 2 usage error. Bash 3.2 and 5 compatible.

set -uo pipefail

usage() { sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
FILES=()
COPIES=()
STAGED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { usage >&2; exit 2; }; ROOT=$(cd "$2" && pwd) || exit 2; shift 2 ;;
    --copy) [ $# -ge 2 ] || { usage >&2; exit 2; }; COPIES+=("$2"); shift 2 ;;
    --staged) STAGED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*) echo "lint-protocol: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

NSNAME=.io.v4rian.how-git
NS="$ROOT/$NSNAME"
[ -d "$NS" ] || { echo "lint-protocol: no $NSNAME under $ROOT" >&2; exit 2; }
ALLOC="$NSNAME/scripts/allocate-pool-branch.sh"
LIB="$NSNAME/scripts/_lib.sh"

FINDINGS=$(mktemp "${TMPDIR:-/tmp}/lint-protocol.XXXXXX") || exit 2
trap 'rm -f "$FINDINGS"' EXIT

report() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FINDINGS"; }

# Protocol files: the text an agent or a human reads as the rules. History
# (CHANGELOG.md) and the original build spec (IMPLEMENTATION_HANDOFF.md) are
# records, not rules, and stay out.
is_protocol_file() {
  case "$1" in
    $NSNAME/skills/*.md|$NSNAME/README.md|$NSNAME/githooks/README.md) return 0 ;;
    $NSNAME/docs/Git_Strategy.md|$NSNAME/docs/CONTRIBUTING.md) return 0 ;;
    $NSNAME/docs/RUNBOOK.md|$NSNAME/docs/repo-config.md) return 0 ;;
    .github/PULL_REQUEST_TEMPLATE.md) return 0 ;;
  esac
  return 1
}
is_skill_file() { case "$1" in $NSNAME/skills/*) return 0 ;; esac; return 1; }

# Lines that state a rule against the phrase rather than use it.
NEGATION='(^|[^A-Za-z])([Nn]o|[Nn]ever|[Nn]ot|[Rr]etired|[Dd]on.t|[Ii]nstead)([^A-Za-z]|$)'
# Lines that record a removal rather than point at a live file.
HISTORY='(^|[^A-Za-z])([Rr]emoved|[Ff]olded into|[Ee]arlier|[Ff]ormerly)([^A-Za-z]|$)'

lint_file() {
  local rel="$1" abs="$ROOT/$1" hits ln text ref name skill=0
  [ -f "$abs" ] || return 0
  is_skill_file "$rel" && skill=1

  # Backtick spans are code (`[[bin]]` is a Cargo.toml table), so links are
  # read from the line with the spans removed.
  if [ "$skill" = 1 ]; then
    hits=$(sed 's/`[^`]*`//g' "$abs" | grep -noE '\[\[[^]]+\]\]' || true)
    while IFS=: read -r ln ref; do
      [ -n "$ln" ] || continue
      name=$(printf '%s' "$ref" | tr -d '[]' | sed 's#.*/##; s/\.md$//')
      [ -f "$NS/skills/$name/SKILL.md" ] && continue
      report MEMORY-LINK "$rel:$ln" "$ref is not an in-tree skill"
    done <<EOF
$hits
EOF
    hits=$(grep -noE 'memory/[A-Za-z0-9_.-]+\.md|`(feedback|reference|project|user|workflow)_[a-z0-9_]+`' "$abs" || true)
    while IFS=: read -r ln ref; do
      [ -n "$ln" ] || continue
      report MEMORY-LINK "$rel:$ln" "$ref names a memory note"
    done <<EOF
$hits
EOF
    hits=$(grep -nE '(^|[^A-Za-z0-9_.])/tm[p]/' "$abs" | grep -vE "$NEGATION" || true)
    while IFS=: read -r ln text; do
      [ -n "$ln" ] || continue
      ref=$(printf '%s' "$text" | grep -oE '/tm[p]/[^ `"'"'"')]*' | head -1)
      report FIXED-TMP "$rel:$ln" "$ref (use mktemp -d under \${TMPDIR:-/tmp})"
    done <<EOF
$hits
EOF
  fi

  # References to tools, scripts, workflows and skills (removal records skip).
  local live
  live=$(mktemp "${TMPDIR:-/tmp}/lint-protocol-live.XXXXXX") || return 1
  awk -v h="$HISTORY" '{ if ($0 ~ h) print ""; else print }' "$abs" > "$live"
  hits=$(grep -noE '(^|[^/A-Za-z0-9_.-])bin/[a-z][a-z0-9-]*[a-z0-9]' "$live" || true)
  while IFS=: read -r ln ref; do
    [ -n "$ln" ] || continue
    name=${ref#*bin/}
    [ -e "$NS/bin/$name" ] || report DEAD-REF "$rel:$ln" "bin/$name does not exist"
  done <<EOF
$hits
EOF
  hits=$(grep -noE '(^|[^/A-Za-z0-9_.-])scripts/[A-Za-z0-9_./-]+\.(sh|py)' "$live" || true)
  while IFS=: read -r ln ref; do
    [ -n "$ln" ] || continue
    name=scripts/${ref#*scripts/}
    [ -e "$NS/$name" ] || [ -e "$ROOT/$name" ] || report DEAD-REF "$rel:$ln" "$name does not exist"
  done <<EOF
$hits
EOF
  hits=$(grep -noE 'tools/[A-Za-z0-9_.-]+\.sh' "$live" || true)
  while IFS=: read -r ln ref; do
    [ -n "$ln" ] || continue
    name=${ref#tools/}
    ls "$NS"/skills/*/tools/"$name" >/dev/null 2>&1 || [ -e "$NS/tools/$name" ] \
      || report DEAD-REF "$rel:$ln" "tools/$name does not exist"
  done <<EOF
$hits
EOF
  hits=$(grep -noE '[A-Za-z0-9_-]+\.yml' "$live" || true)
  while IFS=: read -r ln ref; do
    [ -n "$ln" ] || continue
    [ -e "$ROOT/.github/workflows/$ref" ] || report DEAD-REF "$rel:$ln" "workflow $ref does not exist"
  done <<EOF
$hits
EOF
  hits=$(grep -noE '`git-[a-z]+(-[a-z]+)*`' "$live" || true)
  while IFS=: read -r ln ref; do
    [ -n "$ln" ] || continue
    name=$(printf '%s' "$ref" | tr -d '`')
    [ -d "$NS/skills/$name" ] || report DEAD-REF "$rel:$ln" "skill $name does not exist"
  done <<EOF
$hits
EOF
  rm -f "$live"

  # Retired phrases. feature/ is legal only inside a section whose heading
  # names the legacy model, or on a line that names it.
  hits=$(awk -v neg="$NEGATION" '
    /^#+ / { legacy = (tolower($0) ~ /legacy/) }
    {
      line = $0; low = tolower(line)
      if (line ~ /cat VERSION/ && line !~ neg) print NR "\tcat VERSION"
      if (line ~ /\[CLEANUP\]/ && line !~ neg) print NR "\t[CLEANUP]"
      if (line ~ /Changes:/ && line !~ neg) print NR "\tChanges: header"
      if (low ~ /straight to dev/ && line !~ neg) print NR "\tstraight to dev"
      if (line ~ /(^|[^A-Za-z0-9_\/-])feature\// && !legacy && low !~ /legacy/) print NR "\tfeature/ outside the legacy section"
    }' "$abs")
  while IFS="$(printf '\t')" read -r ln text; do
    [ -n "$ln" ] || continue
    report RETIRED "$rel:$ln" "$text"
  done <<EOF
$hits
EOF
}

# The allocator must use the shared kind list; any literal list it still
# carries must equal it.
norm_kinds() { tr -d '\\ ' | tr '|,' '\n\n' | grep -v '^$' | sort -u | tr '\n' ' '; }
lint_kinds() {
  local shared lists ln list
  if ! grep -qE "^HG_BRANCH_KINDS=" "$ROOT/$LIB" 2>/dev/null; then
    report KIND-DRIFT "$LIB" "HG_BRANCH_KINDS is not defined"
    return 0
  fi
  shared=$(grep -E "^HG_BRANCH_KINDS=" "$ROOT/$LIB" | head -1 | sed "s/^HG_BRANCH_KINDS=//; s/^['\"]//; s/['\"]\$//" | norm_kinds)
  [ -f "$ROOT/$ALLOC" ] || return 0
  lists=$(grep -noE '[a-z&\\]+(\|[a-z&\\]+)+|one of: [a-z&, ]+' "$ROOT/$ALLOC" | grep -E 'feature|fix' || true)
  while IFS=: read -r ln list; do
    [ -n "$ln" ] || continue
    list=$(printf '%s' "${list#one of: }" | norm_kinds)
    [ "$list" = "$shared" ] || report KIND-DRIFT "$ALLOC:$ln" "kinds [$list] differ from HG_BRANCH_KINDS [$shared]"
  done <<EOF
$lists
EOF
}

# Home and session paths name one person's machine; history records them
# as placeholders.
PERSONAL_RE='/Users/[A-Za-z][A-Za-z0-9._-]*/|/home/[a-z][a-z0-9._-]*/|-Users-[A-Za-z][A-Za-z0-9._-]*-|/private/t[m]p/claude-'
lint_personal() {
  local rel="$1" abs="$ROOT/$1" hits ln text ref
  [ -f "$abs" ] || return 0
  case "$rel" in */bench/arms/*) return 0 ;; esac
  hits=$(grep -nE "$PERSONAL_RE" "$abs" || true)
  while IFS=: read -r ln text; do
    [ -n "$ln" ] || continue
    ref=$(printf '%s' "$text" | grep -oE "$PERSONAL_RE" | head -1)
    report PERSONAL-PATH "$rel:$ln" "$ref (write <workspace>, <scratchpad> or <tmp>)"
  done <<EOF
$hits
EOF
}

# Drift between the canonical namespace and a copy, as a diff summary. The
# per-repo files (MODE, SPEC, REQUIREMENTS.md, the FRAMEWORK_REPO marker)
# belong to each repo and are not compared.
COPY_EXCLUDES="-x .DS_Store -x MODE -x SPEC -x REQUIREMENTS.md -x FRAMEWORK_REPO"
lint_copy() {
  local copy="$1" files only_canon only_copy changed lines
  [ -d "$copy/$NSNAME" ] && copy="$copy/$NSNAME"
  if [ ! -d "$copy" ]; then report COPY-DRIFT "$copy" "copy not found"; return 0; fi
  files=$(diff -rq $COPY_EXCLUDES "$NS" "$copy" 2>/dev/null || true)
  [ -n "$files" ] || return 0
  # Match the roots with their trailing / or : so a copy path that extends
  # the canonical path (ns vs ns-copy) is never counted as canonical.
  only_canon=$(printf '%s\n' "$files" | grep -cF -e "Only in $NS/" -e "Only in $NS:" || true)
  only_copy=$(printf '%s\n' "$files" | grep -cF -e "Only in $copy/" -e "Only in $copy:" || true)
  changed=$(printf '%s\n' "$files" | grep -c '^Files .* differ$' || true)
  lines=$(diff -r $COPY_EXCLUDES "$NS" "$copy" 2>/dev/null | grep -c '^[<>]' || true)
  report COPY-DRIFT "$copy" "$changed changed, $only_canon only in canonical, $only_copy only in copy, $lines differing lines"
  printf '%s\n' "$files" | awk -v a="$NS" -v b="$copy" '
    function swap(s, root, label,   out, i, c) {
      out = ""
      while ((i = index(s, root)) > 0) {
        c = substr(s, i + length(root), 1)
        if (c == "/" || c == ":") { out = out substr(s, 1, i - 1) label; s = substr(s, i + length(root) + 1) }
        else { out = out substr(s, 1, i + length(root) - 1); s = substr(s, i + length(root)) }
      }
      return out s
    }
    { print swap(swap($0, b, "copy:"), a, "canonical:") }' | head -40 \
    | while IFS= read -r l; do report COPY-DRIFT "$copy" "$l"; done
}

if [ "$STAGED" = 1 ]; then
  staged=$(git -C "$ROOT" diff --cached --name-only --diff-filter=ACMRT 2>/dev/null || true)
  [ -n "$staged" ] || { echo "lint-protocol: nothing staged" >&2; exit 0; }
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done <<EOF
$staged
EOF
fi

run_kinds=0
if [ ${#FILES[@]} -eq 0 ]; then
  run_kinds=1
  for abs in "$ROOT/.github/PULL_REQUEST_TEMPLATE.md" "$NS"/*.md "$NS"/githooks/*.md "$NS"/docs/*.md \
             $(find "$NS/skills" -name '*.md' 2>/dev/null | sort); do
    rel=${abs#"$ROOT"/}
    is_protocol_file "$rel" && lint_file "$rel"
  done
  while IFS= read -r abs; do
    [ -n "$abs" ] && lint_personal "${abs#"$ROOT"/}"
  done <<EOF
$(find "$NS" -name '*.md' 2>/dev/null | sort)
EOF
else
  for f in ${FILES[@]+"${FILES[@]}"}; do
    case "$f" in /*) rel=${f#"$ROOT"/} ;; *) rel=$f ;; esac
    case "$rel" in "$ALLOC"|"$LIB") run_kinds=1 ;; esac
    is_protocol_file "$rel" && lint_file "$rel"
    case "$rel" in "$NSNAME"/*.md) lint_personal "$rel" ;; esac
  done
fi
[ "$run_kinds" = 1 ] && lint_kinds
for c in ${COPIES[@]+"${COPIES[@]}"}; do lint_copy "$c"; done

# --staged: keep findings on added lines ("file:N" with N added) and
# findings without a line number; drop the ones the commit only carries.
if [ "$STAGED" = 1 ] && [ -s "$FINDINGS" ]; then
  added=$(git -C "$ROOT" diff --cached -U0 --diff-filter=ACMRT 2>/dev/null | awk '
    /^\+\+\+ b\// { f = substr($0, 7); next }
    /^@@/ {
      split($3, a, ","); start = substr(a[1], 2); n = (a[2] == "" ? 1 : a[2])
      for (i = 0; i < n; i++) print f ":" start + i
    }')
  kept=$(mktemp "${TMPDIR:-/tmp}/lint-protocol-kept.XXXXXX") || exit 2
  while IFS="$(printf '\t')" read -r rule loc detail; do
    case "$rule:$loc" in
      KIND-DRIFT:*|COPY-DRIFT:*) ;;
      *:[0-9]*) printf '%s\n' "$added" | grep -qxF -- "$loc" || continue ;;
    esac
    printf '%s\t%s\t%s\n' "$rule" "$loc" "$detail" >> "$kept"
  done < "$FINDINGS"
  mv "$kept" "$FINDINGS"
fi

if [ -s "$FINDINGS" ]; then
  cat "$FINDINGS"
  echo "lint-protocol: $(wc -l < "$FINDINGS" | tr -d ' ') finding(s)" >&2
  exit 1
fi
echo "lint-protocol: clean" >&2
exit 0
