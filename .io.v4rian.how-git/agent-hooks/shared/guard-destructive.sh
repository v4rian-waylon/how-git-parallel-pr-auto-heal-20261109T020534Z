#!/bin/bash
# how-git agent hook: PreToolUse(Bash) guard for Claude Code and Codex. Deterministic, no model call.
# Reads the agent's hook JSON on stdin ({tool_input:{command}, cwd}); a deny is printed as
# {hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason}} with the fix in the reason.
#   1. No rm / find -delete / unlink / shred / xargs rm outside temp roots: deletions go to the Trash.
#   2. No destructive git (reset --hard, checkout -f, clean -f, push --force*, branch -D, rebase,
#      filter-branch, stash drop/clear, reflog expire, gc --prune, update-ref -d) without a fresh
#      preflight backup (preflight-bak-* ref, on origin when the repo has one, plus bak zip, both < PREFLIGHT_MAX_AGE_H old).
#      Exempt: throwaway repos whose worktree AND git common dir live under a temp root ($TMPDIR, /private/tmp,
#      /private/var/folders); a force push from one is exempt only when every remote is itself under a temp root.
#      Linked worktrees accept a fresh preflight of their main repo; a reset --hard / checkout -f / clean -f
#      then still needs the worktree's own preflight when the worktree has changes that op would destroy.
#      `git-preflight.sh <repo> ... && <destructive git on that repo>` in one command counts as preflighted
#      (only through an unbroken && chain, since the hook runs before the command).
#   3. No push to main, no remote repo deletion, no bare --force on a push, no `filter-branch -- --all`.
#   4. No printing of credential files into the transcript (Git Credential Manager store, .credentials.json,
#      .auth/, keys/, .env, *.p8 *.p12 *.pem).
#   5. Protocol staging and trailer rules: git add -A|., staging secrets or build output, a
#      Co-Authored-By: Claude trailer on a commit.
# `cd <dir>` segments are tracked so `cd repo && git reset --hard` resolves the right repo.
# Config: HOW_GIT_BAKS_DIR (bak zips, default $HOME/.how-git/baks; BAKS_DIR is a legacy alias),
# PREFLIGHT_MAX_AGE_H (12), GUARD_TMP_ROOTS (colon list that can only narrow the temp exemption).
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0
MAXH="${PREFLIGHT_MAX_AGE_H:-12}"
BAKS="${HOW_GIT_BAKS_DIR:-${BAKS_DIR:-$HOME/.how-git/baks}}"
PF="$(cd "$(dirname "$0")" && pwd)/git-preflight.sh"
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
deny() { jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }

# Split into simple commands. Heredoc bodies are dropped and separators inside quotes are
# neutralised, so text, patterns and fixtures are never mistaken for commands.
seglist=$(python3 - "$cmd" <<'PY'
import sys, re
c = sys.argv[1]
lines = c.split("\n"); out = []; i = 0
while i < len(lines):
    l = lines[i]; m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", l)
    out.append(l); i += 1
    if m:
        tag = m.group(1)
        while i < len(lines) and lines[i].strip() != tag: i += 1
        i += 1
c = "\n".join(out)
c = re.sub(r"'[^']*'|\"[^\"]*\"", lambda m: re.sub(r"[|&;\n]", " ", m.group(0)), c)
# each line: <separator before the segment>TAB<segment>; the separator decides whether a chained preflight still holds
sep = "^"
for part in re.split(r"(&&|\|\||;|\||\n)", c):
    if part in ("&&", "||", ";", "|", "\n"):
        sep = ";" if part == "\n" else part
        continue
    part = part.strip()
    if part: print(sep + "\t" + part)
PY
)
segments=$(printf '%s\n' "$seglist" | cut -f2-)
# Trailer check on the raw command (heredoc bodies hold commit messages), only when a segment really is a git commit.
if printf '%s\n' "$segments" | grep -Eq '^git +(-C +[^ ]+ +)?commit( |$)' && printf '%s' "$cmd" | grep -Eiq 'Co-Authored-By: *Claude'; then
  deny "Co-Authored-By: Claude trailer blocked (how-git protocol, githooks/commit-msg): commit without the trailer."
fi
SECRET_RE='(\.gcm/store|\.credentials\.json|(^|[ /])\.auth(/| |$)|(^|[ /])keys/|\.p8( |$)|\.p12( |$)|\.pem( |$)|(^|[ /])\.env( |$))'
BANNED_STAGE_RE='(\.DS_Store|(^|[ /])\.auth(/| |$)|(^|[ /])keys/|\.p8( |$)|\.p12( |$)|\.cer( |$)|\.pem( |$)|\.provisionprofile( |$)|\.mobileprovision( |$)|(^|[ /])build(-[^ /]+)?/|node_modules/|(^|[ /])\.env( |$)|\.zip( |$)|\.bak( |$))'
# The caller's TMPDIR without its trailing slash; empty when unset (Linux runners).
TMPD=${TMPDIR:-}; TMPD=${TMPD%/}
# temp roots, resolved (macOS: /tmp -> /private/tmp, /var/folders -> /private/var/folders)
TMP_REAL=$( (cd "${TMPDIR:-/private/tmp}" 2>/dev/null && pwd -P) || echo /private/tmp)
is_tmp_default() { case "$1/" in /private/tmp/?*|/tmp/?*|/private/var/folders/?*|/var/folders/?*|"$TMP_REAL"/?*) return 0 ;; esac; return 1; }
real() { [ -n "$1" ] && (cd "$1" 2>/dev/null && pwd -P); }
# GUARD_TMP_ROOTS (colon list, for the hook's own tests) can only NARROW the exemption: each entry must sit under a default temp root
TMP_NARROW=""
if [ -n "${GUARD_TMP_ROOTS:-}" ]; then
  TMP_NARROW="|"; IFS=: read -r -a _roots <<< "$GUARD_TMP_ROOTS"
  for _r in "${_roots[@]}"; do _rr=$(real "$_r") && is_tmp_default "$_rr" && TMP_NARROW="$TMP_NARROW$_rr|"; done
fi
is_tmp() {
  is_tmp_default "$1" || return 1
  [ -z "$TMP_NARROW" ] && return 0
  local IFS='|' r; for r in $TMP_NARROW; do [ -n "$r" ] && case "$1/" in "$r"/?*) return 0 ;; esac; done; return 1
}
# expand the variables an agent typically uses in a path; anything still holding a $ is unresolvable
xpath() {
  local t; t=$(printf '%s' "$1" | tr -d '"'"'")
  t=${t//\$\{HOME\}/$HOME}; t=${t//\$HOME/$HOME}
  # Linux runners leave TMPDIR unset: under set -u a bare ${TMPDIR%/} aborted this
  # function and every -C path resolved to the cwd. Without a TMPDIR the variable
  # stays unexpanded, so the caller treats the path as unresolvable.
  if [ -n "$TMPD" ]; then t=${t//\$\{TMPDIR\}/$TMPD}; t=${t//\$TMPDIR/$TMPD}; fi
  case "$t" in '~'*) t="$HOME${t#\~}" ;; esac
  printf '%s' "$t"
}
dir="$cwd"
pf_roots=""   # repo roots preflighted earlier in this command through an unbroken && chain
printf '%s\n' "$seglist" | while IFS= read -r line; do
  sep=${line%%$'\t'*}; seg=${line#*$'\t'}
  [ -z "$seg" ] && continue
  [ "$sep" = "&&" ] || pf_roots=""
  raw="$seg"
  # leading env assignments are a bypass vector for rule 1 (TMPDIR=/ rm $TMPDIR/x): remember them
  envprefix=0; printf '%s' "$seg" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=' && envprefix=1
  # strip leading env assignments / sudo / command / nohup / time / exec
  seg=$(printf '%s' "$seg" | sed -E 's/^(([A-Za-z_][A-Za-z0-9_]*=[^ ]* +)|(command|nohup|time|exec) +)*//')
  first=$(printf '%s' "$seg" | awk '{print $1}')

  # ---- neo-git new-repo bootstrap: the one sanctioned main seeding (atomic main+dev push, lease that
  # both are absent, refuses a seeded origin). Exactly the tool with its own flags; any other push to main
  # still meets rule 3.
  if printf '%s' "$first" | grep -Eq '(^|/)\.io\.v4rian\.how-git/bin/bootstrap-offgrid$' \
     && printf '%s' "${seg#"$first"}" | grep -Eq '^( +(--dry-run|-h|--help|--remote +[A-Za-z0-9._-]+))* *$'; then
    continue
  fi

  # ---- cd tracking ----
  if [ "$first" = cd ]; then
    t=$(xpath "$(printf '%s' "$seg" | awk '{print $2}')")
    case "$t" in ""|-) ;; /*) dir="$t" ;; *) dir="$dir/$t" ;; esac
    continue
  fi

  # ---- chained preflight: remember the repo it covers ----
  pfarg=$(printf '%s' "$seg" | awk '{for(i=1;i<NF;i++) if ($i ~ /git-preflight\.sh["'"'"']?$/) {print $(i+1); exit}}')
  if [ -n "$pfarg" ]; then
    p=$(xpath "$pfarg"); case "$p" in /*) ;; *) p="$dir/$p" ;; esac
    case "$p" in *'$'*) ;; *) r=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) && pf_roots="$pf_roots|$(real "$r")|" ;; esac
    continue
  fi

  # ---- rule 4: credential echo ----
  if printf '%s' "$seg" | grep -Eq "$SECRET_RE"; then
    case "$first" in
      cat|less|more|head|tail|bat|strings|base64|xxd|od|hexdump|grep|rg|awk|sed|cut|jq|python|python3|node|ruby|perl|open|pbcopy|curl)
        printf '%s' "$seg" | grep -Eq '>' || deny "Credential echo blocked: '$first' on a secret path would print the secret into the transcript. Read it into a shell variable or let the consuming tool read the file itself. Offending: $seg" ;;
    esac
  fi

  # ---- rule 1: deletions ----
  if printf '%s' "$seg" | grep -Eq '^(rm|unlink|shred)( |$)|^find .* -delete( |$)|^find .* -exec +(rm|unlink|shred)( |$)|^xargs( .*)? (rm|unlink|shred)( |$)'; then
    tmp_ok=1
    [ "$envprefix" = 1 ] && tmp_ok=0
    printf '%s' "$seg" | grep -Eq '^xargs|-exec' && tmp_ok=0
    if [ "$tmp_ok" = 1 ]; then
      for tok in $(printf '%s' "$seg" | tr -d '"'"'" | awk '{for(i=2;i<=NF;i++) if ($i !~ /^-/) print $i}'); do
        case "$tok" in
          /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) ;;
          # $TMPDIR counts only when it is set: unset or empty, "$TMPDIR"* matched
          # every path, and a literal $TMPDIR/x expands to /x in the agent's shell.
          *) if [ -n "$TMPD" ]; then
               case "$tok" in "$TMPD"/*|\$TMPDIR/*|\${TMPDIR}/*) ;; *) tmp_ok=0 ;; esac
             else tmp_ok=0; fi ;;
        esac
      done
    fi
    [ "$tmp_ok" = 1 ] && continue
    deny "Deletion blocked (how-git data-loss prevention): move it to the Trash (macOS: '/usr/bin/trash <path>', Linux: 'gio trash <path>') so it stays recoverable. Only absolute paths under /tmp, /private/tmp or \$TMPDIR may be rm'd, never through xargs, -exec or an env prefix. Offending: $raw"
  fi

  # ---- rule 3: remote repo deletion ----
  if printf '%s' "$seg" | grep -Eq '^gh +repo +delete|^gh +api +.*(-X|--method) *DELETE .*repos/|^gh +api +.*repos/[^ ]+ .*(-X|--method) *DELETE'; then
    deny "Remote repo deletion blocked (how-git data-loss prevention): only the repo owner deletes a repo, by name, by hand. Offending: $seg"
  fi

  # ---- rules 2, 3, 5: git ----
  [ "$first" = git ] || continue
  g=$(printf '%s' "$seg" | sed -E 's/^git +//')
  gdir="$dir"
  if printf '%s' "$g" | grep -Eq '^-C +[^ ]+'; then gdir=$(xpath "$(printf '%s' "$g" | sed -E 's/^-C +([^ ]+).*/\1/')"); g=$(printf '%s' "$g" | sed -E 's/^-C +[^ ]+ +//'); fi
  case "$gdir" in /*) ;; *) gdir="$cwd/$gdir" ;; esac
  # staging
  if printf '%s' "$g" | grep -Eq '^add( |$)'; then
    # read-only dry run (-n / --dry-run, alone or in a short-flag cluster, before any `--`) stages nothing
    addopts=$(printf '%s' "$g" | sed -E 's/ -- .*$//; s/ --$//')
    printf '%s' "$addopts" | grep -Eq '(^| )(--dry-run|-[A-Za-z]*n[A-Za-z]*)( |$)' && addro=1 || addro=0
    [ "$addro" = 0 ] && printf '%s' "$g" | grep -Eq '^add( .*)? (-A|--all|\.)( |$)' && deny "git add -A / git add . blocked (how-git protocol): stage files by name. Offending: $seg"
    printf '%s' "$g" | grep -Eq "$BANNED_STAGE_RE" && deny "Staging a banned file blocked (how-git protocol: .DS_Store, .auth/, keys/, certificates, build/, node_modules/, .env, *.zip, *.bak). Offending: $seg"
  fi
  printf '%s' "$g" | grep -Eq '^filter-branch( .*)? -- +--all' && deny "git filter-branch -- --all blocked (how-git protocol). Offending: $seg"
  # push to main: explicit refspec, or bare `git push` while main is checked out; bare --force
  if printf '%s' "$g" | grep -Eq '^push( |$)'; then
    if printf '%s' "$g" | grep -Eq '(^| )(refs/heads/)?main( |$)|:(refs/heads/)?main( |$)|( |^)[A-Za-z0-9_./-]+:main( |$)'; then
      deny "Push to main blocked: main advances only through the release close-up (dev to main via the repo's own ship/claim tooling), never by a direct push. Offending: $seg"
    fi
    if printf '%s' "$g" | grep -Eq '(^| )(--force|-f)( |$)' && ! printf '%s' "$g" | grep -Eq -- '--force-with-lease'; then
      deny "Bare --force blocked (how-git protocol): use --force-with-lease after a preflight. Offending: $seg"
    fi
    args=$(printf '%s' "$g" | sed -E 's/^push//; s/ --?[A-Za-z][A-Za-z-]*(=[^ ]*)?//g; s/^ +//')
    if [ -z "$args" ]; then
      cur=$(git -C "$gdir" symbolic-ref --short HEAD 2>/dev/null || true)
      [ "$cur" = main ] && deny "Push to main blocked: main is checked out in $gdir and a bare 'git push' would advance it. Switch to a pool branch or use the release close-up tooling."
    fi
  fi
  destructive=""
  printf '%s' "$g" | grep -Eq '^reset( .*)? --hard'                          && destructive="git reset --hard"
  printf '%s' "$g" | grep -Eq '^checkout( .*)? (-f|--force)( |$)'            && destructive="git checkout --force"
  printf '%s' "$g" | grep -Eq '^clean( .*)? -[a-zA-Z]*f'                     && destructive="git clean -f"
  printf '%s' "$g" | grep -Eq '^push( .*)? --force-with-lease'               && destructive="force push"
  printf '%s' "$g" | grep -Eq '^branch( .*)? (-D|--delete +--force|-d +--force)' && destructive="git branch -D"
  printf '%s' "$g" | grep -Eq '^(rebase|filter-branch|filter-repo)( |$)'     && destructive="history rewrite ($(printf '%s' "$g" | awk '{print $1}'))"
  printf '%s' "$g" | grep -Eq '^stash +(drop|clear)'                         && destructive="git stash drop/clear"
  printf '%s' "$g" | grep -Eq '^reflog +expire|^gc( .*)? --prune|^update-ref +-d|^prune( |$)' && destructive="ref/reflog pruning"
  [ -z "$destructive" ] && continue
  root=$(git -C "$gdir" rev-parse --show-toplevel 2>/dev/null) || deny "Destructive git blocked (how-git preflight): $destructive but $gdir is not inside a git repo, so the preflight cannot be checked. Run it from inside the repo (cd <repo> && ...) or with git -C <repo>. Offending: $seg"
  root_p=$(real "$root")
  common_p=$(real "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")
  gitdir_p=$(real "$(git -C "$root" rev-parse --path-format=absolute --git-dir 2>/dev/null)")
  linked=0; [ -n "$common_p" ] && [ "$common_p" != "$gitdir_p" ] && linked=1
  case "$common_p" in */.git) mainroot=${common_p%/.git} ;; *) mainroot="$common_p" ;; esac

  # throwaway repo: worktree and shared git dir both under a temp root (a temp worktree of a real repo is not throwaway)
  if [ -n "$root_p" ] && [ -n "$common_p" ] && is_tmp "$root_p" && is_tmp "$common_p"; then
    [ "$destructive" != "force push" ] && continue
    # a force push leaves the temp root: exempt only when it cannot reach a non-temp remote
    remote_ok=1
    printf '%s' "$g" | grep -Eq '://|(^| )[^ /]+@[^ ]+:' && remote_ok=0
    while IFS= read -r url; do
      [ -z "$url" ] && continue
      u=${url#file://}; case "$u" in /*) ;; *) u="$root_p/$u" ;; esac
      ur=$(real "$u"); [ -n "$ur" ] && is_tmp "$ur" || remote_ok=0
    done <<EOF
$(git -C "$root" config --get-regexp '^remote\..*\.(url|pushurl)$' 2>/dev/null | awk '{print $2}')
EOF
    [ "$remote_ok" = 1 ] && continue
  fi

  # what a worktree-local op would destroy in this worktree (empty = nothing)
  wt_dirty() {
    case "$destructive" in
      "git reset --hard"|"git checkout --force") git -C "$root" status --porcelain --untracked-files=no 2>/dev/null ;;
      "git clean -f") if printf '%s' "$g" | grep -Eq '^clean( .*)? -[a-zA-Z]*[xX]'; then git -C "$root" status --porcelain --untracked-files=all --ignored 2>/dev/null | grep -E '^(\?\?|!!)'; else git -C "$root" status --porcelain --untracked-files=all 2>/dev/null | grep '^??'; fi ;;
    esac
  }
  WT_DENY="Destructive git blocked (how-git preflight): $destructive in linked worktree $root, whose uncommitted changes the main repo's preflight does not cover. Run first: \"$PF\" \"$root\" \"before $destructive\"  then retry the exact command."

  # chained in this command: `git-preflight.sh <repo> ... && <this>`
  case "$pf_roots" in *"|$root_p|"*) continue ;; esac
  if [ "$linked" = 1 ]; then case "$pf_roots" in *"|$mainroot|"*) [ -z "$(wt_dirty)" ] && continue; deny "$WT_DENY" ;; esac; fi

  name=$(basename "$root"); now=$(date +%s); limit=$(( MAXH * 3600 ))
  if git -C "$root" remote get-url origin >/dev/null 2>&1; then
    newest=$(git -C "$root" for-each-ref --sort=-committerdate --format='%(committerdate:unix) %(refname)' 'refs/remotes/' 2>/dev/null | grep '/preflight-bak-' | head -1 | cut -d' ' -f1); where="on origin"
  else
    newest=$(git -C "$root" for-each-ref --sort=-committerdate --format='%(committerdate:unix) %(refname)' 'refs/heads/' 2>/dev/null | grep '/preflight-bak-' | head -1 | cut -d' ' -f1); where="locally (repo has no origin)"
  fi
  ref_ok=0; [ -n "$newest" ] && [ $(( now - newest )) -le "$limit" ] && ref_ok=1
  fresh_zip() { local z; z=$(ls -t "$BAKS"/"$1"-bak-*.zip 2>/dev/null | head -1); [ -n "$z" ] && [ $(( now - $(mtime "$z") )) -le "$limit" ]; }
  zip_ok=0; fresh_zip "$name" && zip_ok=1
  [ "$ref_ok" = 1 ] && [ "$zip_ok" = 1 ] && continue
  # linked worktree: refs are shared, so a fresh preflight of the main repo covers it unless this op destroys worktree changes
  if [ "$linked" = 1 ] && [ "$ref_ok" = 1 ] && fresh_zip "$(basename "$mainroot")"; then
    [ -z "$(wt_dirty)" ] && continue
    deny "$WT_DENY"
  fi
  missing=""; [ "$ref_ok" = 0 ] && missing="no preflight-bak-* ref $where"; [ "$zip_ok" = 0 ] && missing="${missing:+$missing; }no $name-bak-*.zip in $BAKS"
  deny "Destructive git blocked (how-git preflight): $destructive on $root with ${missing} within ${MAXH}h. Run first: \"$PF\" \"$root\" \"before $destructive\"  then retry the exact command, or chain both in one command (\"$PF\" \"$root\" \"...\" && <command>)."
done
exit 0
