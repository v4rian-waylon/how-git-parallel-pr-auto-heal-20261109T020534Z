#!/bin/bash
# how-git agent hook: PreToolUse(Bash) commit identity for Claude Code and Codex. Deterministic, no model call.
# A plain `git commit` records the machine's global identity; the repo rule forbids writing identity into
# repo git config, and git hooks can refuse a commit but cannot set its author. This hook rewrites the
# Bash command through the documented PreToolUse `updatedInput` so it starts with
#   export GIT_AUTHOR_NAME=.. GIT_AUTHOR_EMAIL=.. GIT_COMMITTER_NAME=.. GIT_COMMITTER_EMAIL=..;
# whenever a segment runs git commit | merge | tag -a/-s/-m/-F/-u | cherry-pick | rebase | commit-tree |
# revert | am | pull inside a repo whose origin org is in the identity map.
# Identity comes from scripts/lib/identity.sh (bin/identity): the repo's own vendored copy when it has
# one, else the copy installed next to this hook with the installed identity-map as HOW_GIT_IDENTITY_MAP.
# The <Model> slot is filled from HOW_GIT_MODEL, ANTHROPIC_MODEL, or the hook input's `model`.
# Left untouched:
#   - commands with no such git segment, or any such segment in a repo that is not mapped (mixed
#     commands are not rewritten: the identity would leak into the unmapped repo), or two segments
#     whose repos map to different identities;
#   - every identity field the command or the hook environment already sets (GIT_AUTHOR_*/GIT_COMMITTER_*,
#     --author, -c user.name / -c user.email, eval of `identity --export`), so explicit identity wins;
#   - the snapshot-rebuild switch (HOW_GIT_SNAPSHOT_REBUILD=1 in the command or environment, or
#     git config how-git.snapshotRebuild true): the rebuild authors as the owner, the gate already allows it;
#   - a real CI run (identity_real_ci): the workflow's bot identity authors there.
# Decision: Claude Code allows the rewrite without a prompt only in bypassPermissions mode (where nothing
# prompts anyway); in every other mode it returns "ask" so the user sees the rewritten command and no
# permission is widened. Deny and ask rules still apply, and a guard deny outranks both. Codex supports
# only "allow" with updatedInput. Override: HOW_GIT_IDENTITY_DECISION=allow|ask.
# Usage: identity-env.sh [--agent claude|codex]   < hook JSON on stdin; prints nothing when it passes.
set -u
agent=claude
[ "${1:-}" = "--agent" ] && agent="${2:-claude}"
here="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$here/identity.sh" ]; then lib="$here/identity.sh"; map="$here/identity-map"
else lib="$here/../../scripts/lib/identity.sh"; map="$here/../../identity-map"; fi
input=$(cat)
[ -n "$input" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
printf '%s' "$input" | python3 -c '
import json, os, re, shlex, subprocess, sys
agent, lib, mapfile = sys.argv[1:4]
try: data = json.loads(sys.stdin.read())
except ValueError: sys.exit(0)
ti = data.get("tool_input") or {}
cmd = ti.get("command")
if not isinstance(cmd, str) or not cmd.strip(): sys.exit(0)
cwd = data.get("cwd") or os.getcwd()
FIELDS = ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"]
WRITERS = {"commit", "merge", "cherry-pick", "rebase", "commit-tree", "revert", "am", "pull"}
TAG_ANNOTATED = {"-a", "-s", "-m", "-F", "-u", "--annotate", "--sign", "--message", "--file", "--local-user"}

# segments: heredoc bodies dropped, separators inside quotes neutralised (same split as guard-destructive.sh)
lines = cmd.split("\n"); kept = []; i = 0
while i < len(lines):
    l = lines[i]; m = re.search(r"<<-?\s*[\x27\"]?([A-Za-z_][A-Za-z0-9_]*)[\x27\"]?", l)
    kept.append(l); i += 1
    if m:
        while i < len(lines) and lines[i].strip() != m.group(1): i += 1
        i += 1
flat = "\n".join(kept)
masked = re.sub(r"\x27[^\x27]*\x27|\"[^\"]*\"", lambda m: re.sub(r"[|&;\n()]", " ", m.group(0)), flat)
segs = [p.strip() for p in re.split(r"&&|\|\||;|\||\n|\(|\)", masked) if p.strip()]

def expand(p):
    p = p.replace("${HOME}", os.environ.get("HOME", "")).replace("$HOME", os.environ.get("HOME", ""))
    return os.path.expanduser(p)

def toks(s):
    try: return shlex.split(s, comments=True)
    except ValueError: return s.split()

d = cwd; targets = []
for s in segs:
    t = toks(s)
    while t and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t[0]) or t[0] in ("command", "env", "nohup", "time", "exec", "builtin")):
        t = t[1:]
    if not t: continue
    if t[0] in ("cd", "pushd"):
        if len(t) > 1 and t[1] != "-":
            nd = expand(t[1]); d = nd if os.path.isabs(nd) else os.path.join(d, nd)
        elif len(t) == 1: d = os.environ.get("HOME", d)
        continue
    if os.path.basename(t[0]) != "git": continue
    k = 1; repo = d
    while k < len(t) and t[k].startswith("-"):
        o = t[k]
        if o == "-C" and k + 1 < len(t):
            nd = expand(t[k + 1]); repo = nd if os.path.isabs(nd) else os.path.join(repo, nd); k += 2
        elif o in ("-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env") and k + 1 < len(t): k += 2
        else: k += 1
    if k >= len(t): continue
    sub, rest = t[k], t[k + 1:]
    if sub in WRITERS or (sub == "tag" and any(a in TAG_ANNOTATED or re.match(r"^(-[asmFu].*|--(annotate|sign|message|file|local-user)=.*)$", a) for a in rest)):
        targets.append(repo)
if not targets: sys.exit(0)

# identity fields the command already sets explicitly
explicit = set(f for f in FIELDS if re.search(r"(^|[^A-Za-z0-9_])" + f + r"=", flat) or os.environ.get(f))
if re.search(r"(^|\s)--author(=|\s)", flat): explicit |= {"GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL"}
if re.search(r"-c\s+[\x27\"]?user\.name=", flat): explicit |= {"GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"}
if re.search(r"-c\s+[\x27\"]?user\.email=", flat): explicit |= {"GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"}
if re.search(r"identity\s+--export", flat): explicit |= set(FIELDS)
if re.search(r"(^|[^A-Za-z0-9_])HOW_GIT_SNAPSHOT_REBUILD=[\x27\"]?1", flat): sys.exit(0)
missing = [f for f in FIELDS if f not in explicit]
if not missing: sys.exit(0)

env = dict(os.environ)
model = data.get("model")
if not env.get("HOW_GIT_MODEL") and not env.get("ANTHROPIC_MODEL") and isinstance(model, str): env["ANTHROPIC_MODEL"] = model
probe = r"""
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 3
cd "$top" || exit 3
if [ -f "$top/.io.v4rian.how-git/scripts/lib/identity.sh" ]; then . "$top/.io.v4rian.how-git/scripts/lib/identity.sh"
else [ -f "$1" ] || exit 3; . "$1"; [ -n "${HOW_GIT_IDENTITY_MAP:-}" ] || HOW_GIT_IDENTITY_MAP="$2"; fi
identity_real_ci && exit 4
identity_snapshot_rebuild_on && exit 4
identity_lookup
"""
hits = set()
for r in targets:
    if not os.path.isdir(r): sys.exit(0)
    p = subprocess.run(["bash", "-c", probe, "identity-env", lib, mapfile], cwd=r, env=env, capture_output=True, text=True)
    if p.returncode != 0 or "\t" not in p.stdout: sys.exit(0)
    hits.add(p.stdout.strip("\n"))
if len(hits) != 1: sys.exit(0)
email, name = hits.pop().split("\t", 1)
val = {"GIT_AUTHOR_NAME": name, "GIT_COMMITTER_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_EMAIL": email}
q = lambda v: "\x27" + v.replace("\x27", "\x27\\\x27\x27") + "\x27"
prefix = "export " + " ".join("%s=%s" % (f, q(val[f])) for f in missing) + "; "
new = dict(ti); new["command"] = prefix + cmd
decision = os.environ.get("HOW_GIT_IDENTITY_DECISION", "")
if decision not in ("allow", "ask"):
    decision = "allow" if agent == "codex" or data.get("permission_mode") == "bypassPermissions" else "ask"
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": decision,
    "permissionDecisionReason": "how-git: commit identity %s <%s> exported for this git write (identity map)" % (name, email),
    "updatedInput": new}}, separators=(",", ":")))
' "$agent" "$lib" "$map"
exit 0
