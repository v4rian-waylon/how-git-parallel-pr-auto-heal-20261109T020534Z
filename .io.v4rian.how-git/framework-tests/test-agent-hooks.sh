#!/usr/bin/env bash
# framework-tests/test-agent-hooks.sh - the agent-side how-git hooks in agent-hooks/shared
# (guard-destructive.sh, git-preflight.sh, guard-write.sh), proven on scratch repos under a
# mktemp root. GUARD_TMP_ROOTS narrows the guard's temp exemption to $W/throwaway so repos
# under $W/real stand in for real (non-temp) repos. HOW_GIT_BAKS_DIR / HOW_GIT_BAKS_MIRROR /
# HOW_GIT_TRASH_DIR keep zips and retired zips inside $W.
# Run directly: bash .io.v4rian.how-git/framework-tests/test-agent-hooks.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=./_hermetic_env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_hermetic_env.sh"
NS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$NS_ROOT/agent-hooks/shared"
GUARD="$H/guard-destructive.sh"; PF="$H/git-preflight.sh"; GW="$H/guard-write.sh"
W=$(mktemp -d -t agent-hooks-test.XXXXXX); W=$(cd "$W" && pwd -P)
export HOW_GIT_BAKS_DIR="$W/baks" HOW_GIT_BAKS_MIRROR="$W/mirror" HOW_GIT_TRASH_DIR="$W/trash" GUARD_TMP_ROOTS="$W/throwaway"
unset BAKS_DIR BAKS_MIRROR
BAKS_DIR="$HOW_GIT_BAKS_DIR"; BAKS_MIRROR="$HOW_GIT_BAKS_MIRROR"
mkdir -p "$BAKS_DIR" "$BAKS_MIRROR" "$W/throwaway" "$W/real"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1; git config --file "$GIT_CONFIG_GLOBAL" user.name ambient; git config --file "$GIT_CONFIG_GLOBAL" user.email ambient@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch dev
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1${2:+  ($2)}"; }
# guard <cwd> <command> -> prints allow|deny
guard() { local out; out=$(jq -nc --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}' | "$GUARD"); case "$out" in *'"deny"'*) echo deny ;; *) echo allow ;; esac; }
expect() { local got; got=$(guard "$2" "$3"); [ "$got" = "$1" ] && ok "$1: $4" || bad "$1: $4" "got $got"; }
mkrepo() { git init -q "$1" && git -C "$1" commit -q --allow-empty -m init && git -C "$1" branch foo; }

# ---------- guard: throwaway repos ----------
T="$W/throwaway/clone"; mkrepo "$T"
expect allow "$W" "cd $T && git branch -D foo"                       "branch -D in a throwaway repo (FP-02 repro 1)"
expect allow "$T" "git reset --hard HEAD"                              "reset --hard in a throwaway repo"
expect allow "$W" "git -C $T rebase dev"                               "rebase via -C in a throwaway repo"
git init -q --bare "$W/throwaway/origin.git"; git -C "$T" remote add origin "$W/throwaway/origin.git"
expect allow "$T" "git push --force-with-lease origin dev"             "force push from a throwaway repo to a temp remote"
expect deny  "$T" "git push --force-with-lease git@github.com:x/y.git dev" "force push from a throwaway repo to a URL"
R0="$W/real/upstream"; mkrepo "$R0"; git -C "$T" remote set-url origin "$R0"
expect deny  "$T" "git push --force-with-lease origin dev"             "force push from a throwaway repo to a non-temp remote"

# ---------- guard: real repo, chained preflight ----------
R="$W/real/repo"; mkrepo "$R"; echo a > "$R/f"; git -C "$R" add f; git -C "$R" commit -qm f
expect deny  "$W" "cd $R && git branch -D foo"                         "branch -D in a real repo without preflight"
expect allow "$W" "$PF $R r && git -C $R reset --hard HEAD"           "chained preflight && reset (FP-02 repro 2)"
expect allow "$W" "cd $R && ~/.claude/hooks/how-git/git-preflight.sh . r && git branch -D foo" "chained preflight with relative path after cd"
expect deny  "$W" "$PF $R r; git -C $R reset --hard HEAD"             "preflight chained with ; (runs even if preflight fails)"
expect deny  "$W" "$PF $R r || true && git -C $R reset --hard HEAD"   "preflight with || true"
expect deny  "$W" "$PF $R r | tail -1 && git -C $R reset --hard HEAD" "preflight piped (exit status masked)"
R2="$W/real/other"; mkrepo "$R2"
expect deny  "$W" "$PF $R r && git -C $R2 branch -D foo"              "chained preflight of a different repo"
"$PF" "$R" "test" >/dev/null 2>&1
expect allow "$W" "cd $R && git branch -D foo"                         "branch -D after a fresh preflight"
touch -t "$(python3 -c 'import time; print(time.strftime("%Y%m%d%H%M", time.localtime(time.time() - 13 * 3600)))')" "$BAKS_DIR"/repo-bak-*.zip
expect deny  "$W" "cd $R && git branch -D foo"                         "stale (13h) zip denies"
touch "$BAKS_DIR"/repo-bak-*.zip

# ---------- guard: linked worktrees ----------
git -C "$R" worktree add -q "$W/real/repo-wt" -b wtb
L="$W/real/repo-wt"
expect allow "$L" "git branch -D foo"                                  "branch -D in a linked worktree of a preflighted repo (FP-02 repro 3)"
expect allow "$L" "git reset --hard HEAD"                              "reset --hard in a clean linked worktree"
echo dirty >> "$L/f"
expect deny  "$L" "git reset --hard HEAD"                              "reset --hard in a dirty linked worktree (main preflight does not cover it)"
expect allow "$W" "$PF $L r && git -C $L reset --hard HEAD"           "dirty linked worktree with its own chained preflight"
expect deny  "$W" "$PF $R r && git -C $L reset --hard HEAD"           "dirty linked worktree with only the main repo chained"
git -C "$R" worktree add -q "$W/throwaway/tmpwt" -b tmpwtb
R3="$W/real/nopf"; mkrepo "$R3"; git -C "$R3" worktree add -q "$W/throwaway/wt-of-real" -b x
expect deny  "$W/throwaway/wt-of-real" "git branch -D foo"            "temp worktree of a non-preflighted real repo is not throwaway"
expect deny  "$W" "cd /nonexistent-dir && git reset --hard"            "unresolvable repo still denies"

# ---------- git-preflight: reuse, Z, identity, retention ----------
P="$W/real/pfrepo"; mkrepo "$P"; echo 1 > "$P/a"
out1=$("$PF" "$P" one 2>&1); n1=$(ls "$BAKS_DIR"/pfrepo-bak-*.zip | wc -l | tr -d ' ')
out2=$("$PF" "$P" two 2>&1); n2=$(ls "$BAKS_DIR"/pfrepo-bak-*.zip | wc -l | tr -d ' ')
out3=$("$PF" "$P" three 2>&1); n3=$(ls "$BAKS_DIR"/pfrepo-bak-*.zip | wc -l | tr -d ' ')
case "$out2$out3" in *reused*reused*) [ "$n1" = 1 ] && [ "$n3" = 1 ] && ok "3 preflights on an unchanged repo give 1 zip (FP-03 repro)" || bad "reuse" "zips $n1/$n2/$n3";; *) bad "reuse" "$out2 | $out3";; esac
[ "$(git -C "$P" for-each-ref 'refs/heads/preflight-bak-*/*' | wc -l | tr -d ' ')" = 1 ] && ok "reuse writes no extra preflight ref" || bad "reuse writes no extra preflight ref"
echo 2 >> "$P/a"; out4=$("$PF" "$P" four 2>&1)
case "$out4" in *reused*) bad "changed working tree gets a new preflight" "$out4";; *) ok "changed working tree gets a new preflight";; esac
git -C "$P" commit -q --allow-empty -m moved; out5=$("$PF" "$P" five 2>&1)
case "$out5" in *reused*) bad "moved HEAD gets a new preflight" "$out5";; *) ok "moved HEAD gets a new preflight";; esac
zips=$(ls "$BAKS_DIR"/pfrepo-bak-*.zip); grep -Eqv -- '-bak-[0-9]{8}T[0-9]{6}Z\.zip$' <<<"$zips" && bad "zip names end in UTC Z" || ok "zip names end in UTC Z ($(basename "$(ls -t "$BAKS_DIR"/pfrepo-bak-*.zip | head -1)"))"
# identity
echo 3 >> "$P/a"; GIT_AUTHOR_NAME="Agent (Model)" GIT_AUTHOR_EMAIL=agent@example.invalid "$PF" "$P" id1 >/dev/null 2>&1
id=$(git -C "$P" log -1 --format='%an <%ae> | %cn <%ce>' "$(git -C "$P" for-each-ref --sort=-refname --count=1 --format='%(refname)' 'refs/heads/preflight-bak-*/*')")
[ "$id" = "Agent (Model) <agent@example.invalid> | Agent (Model) <agent@example.invalid>" ] && ok "exported GIT_AUTHOR_* stamps author and committer" || bad "exported GIT_AUTHOR_* identity" "$id"
echo 4 >> "$P/a"; GIT_AUTHOR_NAME=au GIT_AUTHOR_EMAIL=au@x GIT_COMMITTER_NAME=co GIT_COMMITTER_EMAIL=co@x "$PF" "$P" id2 >/dev/null 2>&1
id=$(git -C "$P" log -1 --format='%an <%ae> | %cn <%ce>' "$(git -C "$P" for-each-ref --sort=-refname --count=1 --format='%(refname)' 'refs/heads/preflight-bak-*/*')")
[ "$id" = "au <au@x> | co <co@x>" ] && ok "explicit author and committer both honoured" || bad "explicit author/committer" "$id"
echo 5 >> "$P/a"; "$PF" "$P" id3 >/dev/null 2>&1
id=$(git -C "$P" log -1 --format='%an' "$(git -C "$P" for-each-ref --sort=-refname --count=1 --format='%(refname)' 'refs/heads/preflight-bak-*/*')")
[ "$id" = ambient ] && ok "no export falls back to the ambient identity" || bad "ambient identity" "$id"
# retention: 8 distinct preflights, keep newest 5, older ones land in the Trash
for i in 1 2 3 4 5 6 7 8; do echo "r$i" >> "$P/a"; "$PF" "$P" "ret$i" >/dev/null 2>&1; sleep 1; done
nb=$(ls "$BAKS_DIR"/pfrepo-bak-*.zip | wc -l | tr -d ' '); nm=$(ls "$BAKS_MIRROR"/pfrepo-bak-*.zip | wc -l | tr -d ' ')
[ "$nb" = 5 ] && [ "$nm" = 5 ] && ok "retention keeps newest 5 zips in baks and mirror" || bad "retention" "baks $nb mirror $nm"
trashed=$(ls "$HOW_GIT_TRASH_DIR" 2>/dev/null | grep -c '^pfrepo-bak-.*Z.*\.zip$')
[ "$trashed" -ge 1 ] && ok "older zips moved to the Trash ($trashed found there), not deleted" || bad "older zips in the Trash"
other="$BAKS_DIR/otherrepo-bak-20200101T000000Z.zip"; : > "$other"; echo r9 >> "$P/a"; "$PF" "$P" ret9 >/dev/null 2>&1
[ -f "$other" ] && ok "retention leaves other repos' zips alone" || bad "retention touched another repo's zip"
# origin: reuse requires the ref on origin
O="$W/real/o.git"; git init -q --bare "$O"; git -C "$P" remote add origin "$O"; echo o >> "$P/a"
"$PF" "$P" o1 >/dev/null 2>&1; o2=$("$PF" "$P" o2 2>&1)
case "$o2" in *reused*) ok "reuse with origin when the ref is on origin";; *) bad "reuse with origin" "$o2";; esac
expect allow "$W" "git -C $P branch -D foo"                            "branch -D after preflight pushed to origin"

# ---------- guard: read-only git add dry run ----------
expect allow "$W" "git add -A --dry-run ."                             "git add -A --dry-run . (FP-15 repro)"
expect allow "$W" "git add -n ."                                       "git add -n ."
expect allow "$W" "git add -An"                                        "git add -An (short-flag cluster)"
expect deny  "$W" "git add -A"                                         "git add -A still denied"
expect deny  "$W" "git add ."                                          "git add . still denied"
expect deny  "$W" "git add -A -- --dry-run"                            "--dry-run after -- is a path, not a flag"
expect deny  "$W" "git add -N ."                                       "-N (intent-to-add) is not a dry run"

# ---------- guard: neo-git bootstrap-offgrid ----------
expect allow "$R" ".io.v4rian.how-git/bin/bootstrap-offgrid"           "bootstrap-offgrid (relative)"
expect allow "$W" "cd $R && $R/.io.v4rian.how-git/bin/bootstrap-offgrid --remote origin --dry-run" "bootstrap-offgrid (absolute, own flags)"
expect deny  "$R" "git push --atomic origin main dev"                  "hand-rolled main+dev push still denied (FP-16)"
expect deny  "$R" ".io.v4rian.how-git/bin/bootstrap-offgrid && git push origin main" "push to main chained after bootstrap still denied"
expect deny  "$R" "git push --atomic --force-with-lease=refs/heads/main: origin refs/heads/main refs/heads/dev" "the tool's push typed by hand still denied"

# ---------- git-preflight: explicit-path staging, secrets excluded at any depth (commit tree and zip) ----------
F="$W/real/fixture"; mkrepo "$F"; mkdir -p "$F/sub/deep" "$F/keys" "$F/.auth" "$F/x/.frac" "$F/ign" "$F/a/b/.auth" "$F/lib/keys" "$F/c/.frac" "$F/sub/node_modules/m" "$F/t/.auth"
printf 'ign/\n*.log\n' > "$F/.gitignore"
echo t > "$F/tracked"; echo d > "$F/gone"; echo s > "$F/sub/env.txt"; echo e > "$F/sub/.env"; echo ts > "$F/t/.auth/tracked-secret.json"
git -C "$F" add .gitignore tracked gone sub/env.txt; git -C "$F" add -f sub/.env t/.auth/tracked-secret.json; git -C "$F" commit -qm fixture
echo mod >> "$F/tracked"; rm "$F/gone"; echo e2 >> "$F/sub/.env"
echo u > "$F/sub/deep/new file ü.txt"; echo l > "$F/a.log"; echo i > "$F/ign/x"; echo k > "$F/keys/k"
echo a > "$F/.auth/a.json"; echo p > "$F/sub/c.p8"; echo q > "$F/top.pem"; echo f > "$F/x/.frac/index.json"
echo ds > "$F/sub/.DS_Store"; echo v > "$F/.env.local"; ln -s tracked "$F/link"; echo st > "$F/staged"; git -C "$F" add staged
echo n1 > "$F/a/b/.auth/sa.json"; echo n2 > "$F/lib/keys/apns.p8"; echo n3 > "$F/lib/keys/plain"; echo n4 > "$F/c/.frac/i.json"
echo n5 > "$F/sub/deep/d.p12"; echo n6 > "$F/sub/deep/c.cer"; echo n7 > "$F/sub/deep/p.provisionprofile"; echo n8 > "$F/sub/deep/m.mobileprovision"
echo n9 > "$F/sub/deep/.env"; echo n10 > "$F/sub/deep/.env.prod"; echo n11 > "$F/sub/deep/x.env"; echo n12 > "$F/sub/deep/k.pem"; echo n13 > "$F/sub/node_modules/m/i.js"
git init -q "$F/nested"; git -C "$F/nested" commit -q --allow-empty -m n
SEC_RE='(^|/)(\.auth|keys|\.frac|node_modules)(/|$)|\.(p8|p12|pem|cer|provisionprofile|mobileprovision|env)$|(^|/)\.env(\..*)?$|(^|/)\.DS_Store$'
# reference: the former git add -A method, then secrets filtered out -> the non-secret part must be identical
oldidx=$(mktemp); cp "$(git -C "$F" rev-parse --path-format=absolute --git-path index)" "$oldidx"
( cd "$F" && GIT_INDEX_FILE="$oldidx" git add -A -- . ':(exclude,glob)**/.env' ':(exclude,glob)**/.env.*' ':(exclude).auth' ':(exclude)keys' ':(exclude,glob)**/*.p8' ':(exclude,glob)**/*.p12' ':(exclude,glob)**/*.pem' ':(exclude,glob)**/*.cer' ':(exclude,glob)**/*.provisionprofile' ':(exclude,glob)**/*.mobileprovision' ':(exclude,glob)**/.DS_Store' ':(exclude,glob)**/.frac' >/dev/null 2>&1 )
oldtree=$(cd "$F" && GIT_INDEX_FILE="$oldidx" git write-tree); rm -f "$oldidx"
"$PF" "$F" equiv >/dev/null 2>&1
newtree=$(git -C "$F" rev-parse "$(git -C "$F" for-each-ref --sort=-refname --count=1 --format='%(refname)' 'refs/heads/preflight-bak-*/*')^{tree}")
oldns=$(git -C "$F" -c core.quotePath=false ls-tree -r "$oldtree" | grep -Ev "	($SEC_RE)" | grep -Ev "	.*($SEC_RE)"); newall=$(git -C "$F" -c core.quotePath=false ls-tree -r "$newtree")
[ -n "$newtree" ] && [ "$oldns" = "$newall" ] && ok "snapshot == former git add -A snapshot minus secrets (same blobs, modes, paths)" || bad "snapshot vs former method" "$(diff <(echo "$oldns") <(echo "$newall") | head -8 | tr '\n' ' ')"
leak=$(git -C "$F" -c core.quotePath=false ls-tree -r --name-only "$newtree" | grep -E "$SEC_RE")
[ -z "$leak" ] && ok "commit tree holds no secret path at any depth (incl. tracked t/.auth/)" || bad "secret in commit tree" "$(echo $leak)"
listed=$(git -C "$F" -c core.quotePath=false ls-tree -r --name-only "$newtree" | tr '\n' ' ')
case "$listed" in *a.log*|*ign/x*|*" gone "*) bad "ignored/deleted paths absent" "$listed" ;; *) ok "ignored and deleted paths absent" ;; esac
case "$listed" in *"sub/deep/new file ü.txt"*) case "$listed" in *"lib/keys"*) bad "keys/ dir excluded" ;; *) ok "new untracked files kept" ;; esac ;; *) bad "new untracked files kept" "$listed" ;; esac
fz=$(ls -t "$BAKS_DIR"/fixture-bak-*.zip | head -1); zl=$(unzip -Z1 "$fz" | sed 's#^fixture/##')
zleak=$(printf '%s\n' "$zl" | grep -E "$SEC_RE")
[ -z "$zleak" ] && ok "zip holds no secret path at any depth" || bad "secret in zip" "$(echo $zleak)"
grep -qx 'sub/deep/new file ü.txt' <<<"$zl" && grep -qx 'sub/env.txt' <<<"$zl" && ok "zip keeps ordinary files" || bad "zip keeps ordinary files"
[ "$(git -C "$F" ls-files --stage | wc -l | tr -d ' ')" = 7 ] && ok "preflight leaves the real index untouched" || bad "real index changed" "$(git -C "$F" ls-files --stage)"
grep -Eq '(^|[^A-Za-z])git add -A' <<<"$(grep -v '^ *#' "$PF")" && bad "git-preflight.sh no longer runs git add -A" || ok "git-preflight.sh no longer runs git add -A"

# ---------- guard: protocol rules kept, personal rules dropped ----------
expect deny  "$W" "git commit -m x -m 'Co-Authored-By: Claude <noreply@anthropic.com>'" "Co-Authored-By: Claude trailer on a commit"
expect allow "$W" "git commit -m x -m 'Co-Authored-By: Ada <ada@example.invalid>'"     "a human Co-Authored-By trailer is the protocol's business, not the guard's"
expect deny  "$W" "cat keys/apns.p8"                                   "credential echo of a key file"
expect deny  "$W" "cat ~/.gcm/store/x"                                 "credential echo of the Git Credential Manager store"
expect deny  "$W" "rm -rf $HOME/project"                               "rm outside a temp root"
expect allow "$W" "rm -rf $W/throwaway/x"                              "rm under a temp root"
expect deny  "$W" "TMPDIR=/ rm -rf \$TMPDIR/x"                        "rm behind an env prefix"
expect deny  "$R" "git push origin main"                               "push to main"
expect deny  "$R" "git push --force origin dev"                        "bare --force push"
expect deny  "$W" "gh repo delete o/r --yes"                           "remote repo deletion"
expect deny  "$W" "git add build/out.o"                                "staging build output"
expect allow "$W" "sudo true"                                          "machine policy (sudo) is not a protocol rule"
expect allow "$W" "brew install jq"                                    "machine policy (brew install) is not a protocol rule"
expect allow "$W" "git add FEATURE_REQUESTS.md"                        "personal staging bans are not protocol rules"
grep -Eq '/Users/|waylon|Joel' "$GUARD" "$PF" "$GW" && bad "agent hooks carry no personal path or name" "$(grep -En '/Users/|waylon|Joel' "$GUARD" "$PF" "$GW" | head -3)" || ok "agent hooks carry no personal path or name"
# ---------- guard: no TMPDIR (GitHub's Linux runners leave it unset) ----------
guard_env() { local out; out=$(jq -nc --arg c "$3" --arg d "$2" '{tool_input:{command:$c},cwd:$d}' | env $1 "$GUARD"); case "$out" in *'"deny"'*) echo deny ;; *) echo allow ;; esac; }
expect_env() { local got; got=$(guard_env "$2" "$3" "$4"); [ "$got" = "$1" ] && ok "$1: $5" || bad "$1: $5" "got $got"; }
expect_env allow "-u TMPDIR" "$W" "git -C $T rebase dev"          "TMPDIR unset: git -C still resolves to the throwaway repo"
expect_env deny  "-u TMPDIR" "$W" "git -C $R2 branch -D foo"      "TMPDIR unset: git -C still resolves to the real repo"
expect_env deny  "-u TMPDIR" "$W" "rm -rf \$TMPDIR/x"             "TMPDIR unset: rm \$TMPDIR/x (it would expand to /x) is denied"
expect_env deny  "-u TMPDIR" "$W" "rm -rf $HOME/project"          "TMPDIR unset: rm outside a temp root is denied"
expect_env deny  "TMPDIR="   "$W" "rm -rf /etc/x"                 "TMPDIR empty: no path counts as a temp path"
# The command is only judged, never run; the path is split so the fixed-temp-path lint
# (test-lifecycle B10) does not read it as a shared temp file.
expect_env allow "-u TMPDIR" "$W" "rm -rf /tm""p/x"               "TMPDIR unset: rm under the system temp dir stays allowed"
deny_msg=$(jq -nc --arg c "git -C $R2 branch -D foo" --arg d "$W" '{tool_input:{command:$c},cwd:$d}' | "$GUARD")
grep -qF "$PF" <<<"$deny_msg" && ok "deny reason names the installed git-preflight.sh" || bad "deny reason names the installed git-preflight.sh" "$deny_msg"

# ---------- guard-write: vendored copies ----------
gw() { local out; out=$(jq -nc --arg f "$1" '{tool_input:{file_path:$f}}' | "$GW"); case "$out" in *'"deny"'*) echo deny ;; *) echo allow ;; esac; }
gexpect() { local got; got=$(gw "$2"); [ "$got" = "$1" ] && ok "write $1: $3" || bad "write $1: $3" "got $got"; }
C="$W/real/consumer"; mkdir -p "$C/.io.v4rian.how-git/bin"
FS="$W/real/fwsource"; mkdir -p "$FS/.io.v4rian.how-git"; : > "$FS/.io.v4rian.how-git/FRAMEWORK_REPO"
gexpect deny  "$C/.io.v4rian.how-git/bin/ship"                         "vendored framework copy in a consumer"
gexpect allow "$FS/.io.v4rian.how-git/bin/ship"                        "framework source (FRAMEWORK_REPO marker, any remote)"
gexpect allow "$C/src/main.c"                                          "ordinary project file"
gexpect allow "$HOME/.claude/.credentials.json"                        "agent credential custody is not a protocol rule"
out=$(jq -nc '{tool_input:{notebook_path:"'"$C"'/.io.v4rian.how-git/x.ipynb"}}' | "$GW")
case "$out" in *'"deny"'*) ok "write deny: notebook_path is checked too" ;; *) bad "write deny: notebook_path is checked too" "$out" ;; esac

# ---------- identity-env: org identity exported into git writes ----------
IE="$H/identity-env.sh"; ADP="$NS_ROOT/agent-hooks/codex/codex-adapter.sh"
unset HOW_GIT_MODEL ANTHROPIC_MODEL HOW_GIT_SNAPSHOT_REBUILD HOW_GIT_IDENTITY_MAP HOW_GIT_IDENTITY_DECISION GITHUB_ACTIONS GITHUB_RUN_ID
IDM="v4rian-waylon@users.noreply.github.com"
# ie <cwd> <command> [permission_mode] [model] -> hook output (empty = untouched)
ie() { jq -nc --arg c "$2" --arg d "$1" --arg p "${3:-default}" --arg m "${4:-claude-opus-5-5}" \
  '{tool_name:"Bash",tool_input:{command:$c,description:"d",timeout:5000},cwd:$d,permission_mode:$p,model:$m}' | "$IE"; }
newcmd() { jq -r '.hookSpecificOutput.updatedInput.command // empty' <<<"$1"; }
rewrites() { local o; o=$(ie "$2" "$3"); case "$(newcmd "$o")" in "export "*"GIT_AUTHOR_EMAIL='$IDM'"*"; $3") ok "identity rewrite: $1" ;; *) bad "identity rewrite: $1" "$o" ;; esac; }
untouched() { local o; o=$(ie "$2" "$3"); [ -z "$o" ] && ok "identity untouched: $1" || bad "identity untouched: $1" "$o"; }
M="$W/real/mapped"; mkrepo "$M"; git -C "$M" remote add origin git@github.com:v4rian-io/mapped.git
U="$W/real/unmapped"; mkrepo "$U"; git -C "$U" remote add origin https://github.com/someone-else/u.git
rewrites "plain git commit in a mapped repo (FP-05 repro)"  "$M" "git commit --allow-empty -m x"
rewrites "cd <repo> && git merge"                            "$W" "cd $M && git merge foo"
rewrites "git -C <repo> tag -a"                              "$W" "git -C $M tag -a v9 -m v9"
rewrites "cherry-pick"                                       "$M" "git cherry-pick foo"
rewrites "rebase"                                            "$M" "git rebase dev"
rewrites "commit-tree"                                       "$M" "git commit-tree HEAD^{tree} -m x"
rewrites "env-prefixed commit with a heredoc message"        "$M" "$(printf 'GIT_EDITOR=true git commit --allow-empty -F - <<EOF\n[NEW] x\nEOF')"
untouched "lightweight tag"                                  "$M" "git tag v9"
untouched "read-only git"                                    "$M" "git status && git log -1"
untouched "commit in an unmapped repo"                       "$U" "git commit -m x"
untouched "commit outside any repo"                          "$W" "git commit -m x"
untouched "mixed mapped and unmapped repos"                  "$W" "git -C $M commit -m x && git -C $U commit -m y"
untouched "the word commit in text"                          "$M" "echo git commit -m x"
untouched "explicit identity in the command"                 "$M" "GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@x GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@x git commit -m x"
untouched "eval of bin/identity --export"                    "$M" 'eval "$(.io.v4rian.how-git/bin/identity --export)" && git commit -m x'
untouched "snapshot-rebuild switch in the command"           "$M" "HOW_GIT_SNAPSHOT_REBUILD=1 git commit -m x"
git -C "$M" config how-git.snapshotRebuild true
untouched "snapshot-rebuild switch in repo config"           "$M" "git commit -m x"
git -C "$M" config --unset how-git.snapshotRebuild
o=$(ie "$M" 'git commit --author="A <a@x>" -m x'); c=$(newcmd "$o")
case "$c" in *GIT_COMMITTER_EMAIL=*) case "$c" in *GIT_AUTHOR_*) bad "--author keeps the author, committer exported" "$c" ;; *) ok "--author keeps the author, committer exported" ;; esac ;; *) bad "--author keeps the author, committer exported" "$o" ;; esac
o=$(GIT_AUTHOR_EMAIL=own@x ie "$M" "git commit -m x"); c=$(newcmd "$o")
case "$c" in *GIT_AUTHOR_EMAIL*) bad "identity already in the agent env is kept" "$c" ;; *GIT_COMMITTER_EMAIL=*) ok "identity already in the agent env is kept" ;; *) bad "identity already in the agent env is kept" "$o" ;; esac
o=$(ie "$M" "git commit --allow-empty -m x" default claude-opus-5-5)
jq -e '.hookSpecificOutput.permissionDecision == "ask" and .hookSpecificOutput.updatedInput.description == "d" and .hookSpecificOutput.updatedInput.timeout == 5000' <<<"$o" >/dev/null \
  && ok "default mode: ask with the full rewritten input (no permission widened)" || bad "default mode decision" "$o"
o=$(ie "$M" "git commit --allow-empty -m x" bypassPermissions)
jq -e '.hookSpecificOutput.permissionDecision == "allow"' <<<"$o" >/dev/null && ok "bypassPermissions mode: allow" || bad "bypass decision" "$o"
o=$(ie "$M" "git commit --allow-empty -m 'it'\''s'" bypassPermissions claude-opus-5-5); c=$(newcmd "$o")
(cd "$M" && bash -c "$c") >/dev/null 2>&1
[ "$(git -C "$M" log -1 --format='%an|%ae|%cn|%ce')" = "v4rian-waylon (Opus)|$IDM|v4rian-waylon (Opus)|$IDM" ] \
  && ok "the rewritten command commits as the mapped identity, model from the hook input" || bad "rewritten command identity" "$(git -C "$M" log -1 --format='%an|%ae|%cn|%ce')"
V="$W/real/vendored"; mkrepo "$V"; git -C "$V" remote add origin git@github.com:v4rian-io/v.git
mkdir -p "$V/.io.v4rian.how-git/scripts/lib"; cp "$NS_ROOT/scripts/lib/identity.sh" "$V/.io.v4rian.how-git/scripts/lib/"
printf 'v4rian-io  repo-own@example.invalid  repo-own\n' > "$V/.io.v4rian.how-git/identity-map"
case "$(newcmd "$(ie "$V" "git commit -m x")")" in *"repo-own@example.invalid"*) ok "a repo's own vendored identity map wins" ;; *) bad "vendored map wins" ;; esac
o=$(jq -nc --arg d "$M" '{tool_name:"Bash",tool_input:{command:["bash","-lc","git commit -m x"],workdir:"w"},cwd:$d,permission_mode:"default"}' | "$ADP" identity)
jq -e '.hookSpecificOutput.permissionDecision == "allow" and (.hookSpecificOutput.updatedInput.command | type == "string" and endswith("; git commit -m x")) and .hookSpecificOutput.updatedInput.workdir == "w"' <<<"$o" >/dev/null \
  && ok "codex: adapter identity rewrites an argv command via allow + updatedInput" || bad "codex identity" "$o"
grep -Eq '/Users/|waylon|Joel' "$IE" && bad "identity-env carries no personal path or name" || ok "identity-env carries no personal path or name"

# ---------- bin/install-agent-hooks against a fake HOME ----------
INST="$NS_ROOT/bin/install-agent-hooks"
FH="$W/fakehome"; mkdir -p "$FH/.claude" "$FH/.codex"
cat > "$FH/.claude/settings.json" <<'JSON'
{
  "model": "keep-me",
  "hooks": {
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$HOME/.claude/hooks/mine.sh" } ] } ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "echo stop" } ] } ]
  }
}
JSON
printf '# my codex notes\n' > "$FH/.codex/AGENTS.md"
cp "$FH/.claude/settings.json" "$W/claude-orig.json"; cp "$FH/.codex/AGENTS.md" "$W/agents-orig.md"
tree_sum() { (cd "$1" && find . -type f ! -name '*.how-git-bak-*' | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done; find . -type d | LC_ALL=C sort); }
s0=$(tree_sum "$FH")
dry=$("$INST" --prefix "$FH" --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(tree_sum "$FH")" = "$s0" ] && grep -q 'would add how-git hooks' <<<"$dry" && ok "installer --dry-run lists the plan and changes nothing" || bad "installer --dry-run" "rc=$rc $dry"
out=$("$INST" --prefix "$FH" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "installer runs for both agents by default" || bad "installer runs" "rc=$rc $out"
CS="$FH/.claude/settings.json"; XH="$FH/.codex/hooks.json"
jq -e --arg c "$FH/.claude/hooks/how-git/guard-destructive.sh" '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == $c and .timeout == 10)] | length == 1' "$CS" >/dev/null \
  && jq -e --arg c "$FH/.claude/hooks/how-git/guard-write.sh" '[.hooks.PreToolUse[] | select(.matcher == "Write|Edit|NotebookEdit") | .hooks[] | select(.command == $c)] | length == 1' "$CS" >/dev/null \
  && jq -e --arg c "$FH/.claude/hooks/how-git/identity-env.sh" '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == $c and .timeout == 10)] | length == 1' "$CS" >/dev/null \
  && ok "claude: settings.json gets the Bash (guard + identity) and Write|Edit|NotebookEdit PreToolUse entries" || bad "claude settings entries" "$(cat "$CS")"
jq -e '.model == "keep-me" and ([.hooks.PreToolUse[].hooks[] | select(.command == "$HOME/.claude/hooks/mine.sh")] | length == 1) and (.hooks.Stop[0].hooks[0].command == "echo stop")' "$CS" >/dev/null \
  && ok "claude: the user's own settings and hooks are kept" || bad "claude user hooks kept" "$(cat "$CS")"
ls "$CS".how-git-bak-* >/dev/null 2>&1 && cmp -s "$(ls "$CS".how-git-bak-* | head -1)" "$W/claude-orig.json" && ok "claude: settings.json backed up before the first write" || bad "claude backup"
[ -x "$FH/.claude/hooks/how-git/guard-destructive.sh" ] && [ -x "$FH/.claude/hooks/how-git/git-preflight.sh" ] && [ -x "$FH/.claude/hooks/how-git/guard-write.sh" ] && ok "claude: guards installed executable in hooks/how-git" || bad "claude guard files"
jq -e --arg c "$FH/.codex/hooks/how-git/codex-adapter.sh bash" --arg p "$FH/.codex/hooks/how-git/codex-adapter.sh patch" \
  '([.hooks.PreToolUse[] | select(.matcher == "^Bash$") | .hooks[] | select(.command == $c)] | length == 1) and ([.hooks.PreToolUse[] | select(.matcher == "^(apply_patch|Edit|Write)$") | .hooks[] | select(.command == $p)] | length == 1)' "$XH" >/dev/null \
  && jq -e --arg c "$FH/.codex/hooks/how-git/codex-adapter.sh identity" '[.hooks.PreToolUse[] | select(.matcher == "^Bash$") | .hooks[] | select(.command == $c)] | length == 1' "$XH" >/dev/null \
  && ok "codex: hooks.json gets the Bash (guard + identity) and apply_patch PreToolUse entries" || bad "codex hooks.json" "$(cat "$XH" 2>&1)"
[ -x "$FH/.claude/hooks/how-git/identity-env.sh" ] && [ -f "$FH/.claude/hooks/how-git/identity.sh" ] && [ -f "$FH/.claude/hooks/how-git/identity-map" ] && [ -x "$FH/.codex/hooks/how-git/identity-env.sh" ] \
  && ok "identity-env.sh installed with its identity.sh and identity-map fallback" || bad "identity files installed" "$(ls "$FH/.claude/hooks/how-git")"
[ -f "$FH/.codex/rules/how-git.rules" ] && grep -q 'decision = "forbidden"' "$FH/.codex/rules/how-git.rules" && ok "codex: execpolicy rules installed" || bad "codex rules"
head -1 "$FH/.codex/AGENTS.md" | grep -q '^# my codex notes$' && grep -q 'how-git:agent-hooks:begin' "$FH/.codex/AGENTS.md" && grep -qF "$FH/.codex/hooks/how-git/git-preflight.sh" "$FH/.codex/AGENTS.md" \
  && ok "codex: AGENTS.md keeps the user's text and gains the marked block" || bad "codex AGENTS.md" "$(cat "$FH/.codex/AGENTS.md")"
# the installed hooks work end to end through the command lines written into the settings
cmdc=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | test("guard-destructive")) | .command' "$CS")
r=$(jq -nc --arg d "$R" '{tool_input:{command:"git push origin main"},cwd:$d}' | sh -c "$cmdc")
grep -q '"deny"' <<<"$r" && ok "claude: the installed command denies a push to main" || bad "claude installed command" "$r"
cmdx=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "^Bash$") | .hooks[] | select(.command | endswith(" bash")) | .command' "$XH")
r=$(jq -nc --arg d "$R" '{tool_name:"Bash",tool_input:{command:["bash","-lc","git push origin main"]},cwd:$d}' | sh -c "$cmdx")
grep -q '"deny"' <<<"$r" && ok "codex: the installed adapter denies a push to main sent as an argv array" || bad "codex installed adapter (bash)" "$r"
cmdi=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | test("identity-env")) | .command' "$CS")
r=$(jq -nc --arg d "$M" '{tool_input:{command:"git commit -m x"},cwd:$d,permission_mode:"bypassPermissions"}' | sh -c "$cmdi")
jq -e --arg e "$IDM" '.hookSpecificOutput.updatedInput.command | contains($e)' <<<"$r" >/dev/null && ok "claude: the installed identity hook rewrites a commit in a mapped repo" || bad "claude installed identity hook" "$r"
r=$(jq -nc --arg d "$U" '{tool_input:{command:"git commit -m x"},cwd:$d}' | sh -c "$cmdi")
[ -z "$r" ] && ok "claude: the installed identity hook leaves an unmapped repo alone" || bad "installed identity hook unmapped" "$r"
cmdxi=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "^Bash$") | .hooks[] | select(.command | endswith(" identity")) | .command' "$XH")
r=$(jq -nc --arg d "$M" '{tool_input:{command:["bash","-lc","git commit -m x"]},cwd:$d}' | sh -c "$cmdxi")
jq -e '.hookSpecificOutput.permissionDecision == "allow"' <<<"$r" >/dev/null && ok "codex: the installed adapter rewrites a commit in a mapped repo" || bad "codex installed identity" "$r"
cmdp=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "^(apply_patch|Edit|Write)$") | .hooks[0].command' "$XH")
r=$(jq -nc --arg d "$C" '{tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Update File: src/a.c\n@@\n-a\n+b\n*** Update File: .io.v4rian.how-git/bin/ship\n@@\n-a\n+b\n*** End Patch\n"},cwd:$d}' | sh -c "$cmdp")
grep -q '"deny"' <<<"$r" && ok "codex: the installed adapter denies an apply_patch into a vendored copy" || bad "codex installed adapter (patch)" "$r"
r=$(jq -nc --arg d "$C" '{tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: src/new.c\n+x\n*** End Patch\n"},cwd:$d}' | sh -c "$cmdp")
[ -z "$r" ] && ok "codex: the installed adapter allows an ordinary patch" || bad "codex adapter allows ordinary patch" "$r"
# idempotency
s1=$(tree_sum "$FH"); nb=$(ls "$CS".how-git-bak-* | wc -l | tr -d ' ')
out=$("$INST" --prefix "$FH" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ "$(tree_sum "$FH")" = "$s1" ] && [ "$(ls "$CS".how-git-bak-* | wc -l | tr -d ' ')" = "$nb" ] \
  && ok "re-run changes nothing, prints nothing and takes no new backup" || bad "idempotent re-run" "rc=$rc out=$out"
# upgrade: a stale handler from an older install is replaced, the user's hooks stay
jq --arg c "$FH/.claude/hooks/how-git/old-guard.sh" '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$c}]}]' "$CS" > "$W/cs.tmp" && mv "$W/cs.tmp" "$CS"
"$INST" --prefix "$FH" --claude >/dev/null 2>&1
jq -e '([.hooks.PreToolUse[].hooks[] | select(.command | test("old-guard"))] | length == 0) and ([.hooks.PreToolUse[].hooks[] | select(.command == "$HOME/.claude/hooks/mine.sh")] | length == 1)' "$CS" >/dev/null \
  && ok "re-install drops a stale how-git handler and keeps the user's" || bad "stale handler upgrade" "$(cat "$CS")"
# uninstall
out=$("$INST" --prefix "$FH" --uninstall 2>&1); rc=$?
[ "$rc" = 0 ] && cmp -s "$CS" "$W/claude-orig.json" && ok "uninstall restores claude settings.json byte for byte" || bad "claude uninstall" "rc=$rc $(diff "$W/claude-orig.json" "$CS" | head -5)"
[ ! -e "$XH" ] && [ ! -e "$FH/.codex/rules" ] && cmp -s "$FH/.codex/AGENTS.md" "$W/agents-orig.md" && ok "uninstall removes codex hooks.json and rules it created and restores AGENTS.md" || bad "codex uninstall" "$(ls -R "$FH/.codex")"
[ ! -e "$FH/.claude/hooks" ] && [ ! -e "$FH/.codex/hooks" ] && ok "uninstall removes the hook dirs it created" || bad "hook dirs left" "$(find "$FH" -type d)"
out=$("$INST" --prefix "$FH" --uninstall 2>&1); [ -z "$out" ] && ok "uninstall twice is a silent no-op" || bad "second uninstall" "$out"
# a user edit made after the install survives the uninstall
FH2="$W/fakehome2"; "$INST" --prefix "$FH2" --claude >/dev/null 2>&1
jq '.theme = "dark"' "$FH2/.claude/settings.json" > "$W/s2.tmp" && mv "$W/s2.tmp" "$FH2/.claude/settings.json"
"$INST" --prefix "$FH2" --claude --uninstall >/dev/null 2>&1
jq -e '. == {theme: "dark"}' "$FH2/.claude/settings.json" >/dev/null && ok "uninstall keeps a setting added after the install, drops only how-git" || bad "uninstall after user edit" "$(cat "$FH2/.claude/settings.json")"
mkdir -p "$W/fh3/.claude"; echo '{ broken' > "$W/fh3/.claude/settings.json"
out=$("$INST" --prefix "$W/fh3" --claude 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'not valid JSON' <<<"$out" && grep -q '{ broken' "$W/fh3/.claude/settings.json" && ok "invalid settings.json is refused and left untouched" || bad "invalid JSON refused" "rc=$rc $out"
"$INST" --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "unknown flag exits 2" || bad "unknown flag exit"

echo "---- $pass passed, $fail failed  (scratch: $W)"
[ "$fail" = 0 ] && rm -rf "$W"
exit $(( fail > 0 ))
