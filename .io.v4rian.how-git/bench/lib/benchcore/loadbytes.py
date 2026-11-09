"""bench loadbytes: bytes an agent is instructed to read per decision-tree task, per arm.

Zero model, deterministic. Old arm: the global how-git loader plus everything its
"On invoke" steps mandate (the git memories it names, every in-repo git-* skill and
docs/Git_Strategy.md + docs/RUNBOOK.md at the old ref) plus what the task's row adds
(how-* skills and memories it names). New arm: the in-repo lean loader at the new ref
plus the skills its row names and the --help output of the tools its row names.
"""
import os
import re
import subprocess
import sys
import tempfile

NS = ".io.v4rian.how-git"
HOME = os.path.expanduser("~")
# The old arm is the frozen 2026-10-29 snapshot the bench ships (arms/how-git/bundle),
# not the live ~/.claude: a runner has no ~/.claude, and the live skills keep changing,
# so reading them made the count machine- and day-dependent. Memories stay outside the
# repo (they are private); --memory-dir names where to read them, a missing one is 0 B.
BUNDLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "arms", "how-git", "bundle", "dot-claude")
OLD_LOADER = os.path.normpath(os.path.join(BUNDLE, "skills", "how-git", "SKILL.md"))
MEMORY = os.path.join(HOME, ".claude", "projects", "-Users-waylon-local-stage", "memory")
USER_SKILLS = os.path.normpath(os.path.join(BUNDLE, "skills"))
LIVE_SKILLS = os.path.join(HOME, ".claude", "skills")

# New loader row (matched by its first words) -> old loader row label, or None when
# the old loader has no row (the all-skills read still applies). A row whose skill
# column says "the matching git-*-audit" is measured with git-compile-audit.
TASKS = [
    ("Compose a commit", "Compose a commit"),
    ("Create a working branch", "Create a working branch"),
    ("Merge a pool into dev", "Merge working branch to dev"),
    ("Release dev to main", "Merge dev to main"),
    ("Rewrite my own history", "Rewrite history"),
    ("Rebuild from bak zips", "Rebuild history from zips"),
    ("Rebuild from working-tree folders", "Rebuild history from working-tree folders"),
    ("Replay or rebase across diverged history", None),
    ("Verify compile, coverage or runtime", None),
    ("After a push", None),
    ("GitHub API call needing credentials", "GitHub API operation"),
    ("Bootstrap a new repo", "Bootstrap a new repo"),
    ("Adopt or migrate the framework", None),
]


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True)
    if r.returncode != 0:
        sys.exit("bench loadbytes: git %s failed: %s" % (" ".join(args), r.stderr.decode(errors="replace").strip()))
    return r.stdout


def blob(repo, ref, path):
    r = subprocess.run(["git", "-C", repo, "show", "%s:%s" % (ref, path)], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def table_rows(text, header_word):
    """Rows of the markdown table whose header starts with | Task |."""
    rows, on = [], False
    for line in text.splitlines():
        if line.startswith("| Task |"):
            on = True
            continue
        if on:
            if not line.startswith("|"):
                if rows:
                    break
                continue
            if set(line.replace("|", "").strip()) <= set("-: "):
                continue
            rows.append([c.strip() for c in line.strip().strip("|").split("|")])
    return rows


def ticks(cell):
    return re.findall(r"`([^`]+)`", cell)


def file_bytes(path):
    return os.path.getsize(path) if os.path.isfile(path) else None


def old_arm(repo, ref, loader_path):
    if not os.path.isfile(loader_path):
        sys.exit("bench loadbytes: old loader %s does not exist" % loader_path)
    text = open(loader_path, encoding="utf-8").read()
    base = [("loader " + loader_path, len(text.encode()))]
    notes = []
    invoke = text.split("## On invoke", 1)[1].split("\n## ", 1)[0]
    step1 = [l for l in invoke.splitlines() if l.startswith("1.")][0]
    for m in sorted(set(re.findall(r"`((?:feedback|reference|project)_[a-z0-9_]+)`", step1))):
        b = file_bytes(os.path.join(MEMORY, m + ".md"))
        if b is None:
            notes.append("old: memory %s is mandated but absent (0 B)" % m)
        base.append(("memory " + m, b or 0))
    names = sorted({p.split("/")[2] for p in git(repo, "ls-tree", "-r", "--name-only", ref, NS + "/skills").decode().split()
                    if re.match(re.escape(NS) + r"/skills/git-[^/]+/SKILL\.md$", p)})
    for n in names:
        base.append(("skill " + n, len(blob(repo, ref, "%s/skills/%s/SKILL.md" % (NS, n)))))
    for d in ("docs/Git_Strategy.md", "docs/RUNBOOK.md"):
        b = blob(repo, ref, "%s/%s" % (NS, d))
        base.append((d, len(b) if b is not None else 0))
    rows = {r[0]: r for r in table_rows(text, "Task")}
    return base, rows, set(names), notes


def old_row_extra(row, git_names):
    extra = []
    for t in ticks(row[1]) + ticks(row[2] if len(row) > 2 else ""):
        if t in git_names or t.startswith("git-"):
            continue
        if re.match(r"(feedback|reference|project)_[a-z0-9_]+$", t):
            extra.append(("memory " + t, file_bytes(os.path.join(MEMORY, t + ".md")) or 0))
        elif re.match(r"how-[a-z-]+$", t):
            b = file_bytes(os.path.join(USER_SKILLS, t, "SKILL.md"))
            if b is None:
                b = file_bytes(os.path.join(LIVE_SKILLS, t, "SKILL.md"))
            extra.append(("user skill " + t, b or 0))
    return extra


def help_bytes(tree, tool, args):
    """Bytes of `tool args` (the row's own arguments, --help appended when absent), run in a checkout of the ref."""
    path = os.path.join(tree, NS, tool)
    if not os.path.isfile(path):
        return 0
    if "--help" not in args:
        args = args + ["--help"]
    r = subprocess.run(["bash", path] + args, cwd=tree, capture_output=True, timeout=60,
                       env=dict(os.environ, NO_COLOR="1", GIT_TERMINAL_PROMPT="0"))
    return len(r.stdout) + len(r.stderr)


def new_arm(repo, ref):
    text = blob(repo, ref, NS + "/skills/how-git/SKILL.md")
    if text is None:
        sys.exit("bench loadbytes: new loader %s/skills/how-git/SKILL.md does not exist at %s" % (NS, ref))
    rows = table_rows(text.decode(), "Task")
    tree = os.path.join(tempfile.mkdtemp(prefix="neo-loadbytes-"), "wt")
    # A real checkout: several tools resolve the repo root before printing help.
    git(repo, "-c", "core.hooksPath=/dev/null", "worktree", "add", "-q", "--detach", tree, ref)
    try:
        out = {}
        for r in rows:
            skills = [t for t in ticks(r[1]) if re.match(r"(git-[a-z-]+|how-dev)$", t)]
            if "matching `git-*-audit`" in r[1] or "matching git-*-audit" in r[1]:
                skills = ["git-compile-audit"]
            files = []
            for s in skills:
                b = blob(repo, ref, "%s/skills/%s/SKILL.md" % (NS, s))
                files.append(("skill " + s, len(b) if b is not None else 0))
            tools = []
            for cell in ticks(r[2]) if len(r) > 2 else []:
                parts = cell.split()
                t = parts[0]
                if t.startswith("bin/"):
                    tools.append((cell, help_bytes(tree, t, parts[1:])))
                elif t.startswith("skills/") and t.endswith("*.sh"):
                    d = os.path.join(tree, NS, os.path.dirname(t))
                    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
                        if f.endswith(".sh") and not f.startswith("_"):
                            tools.append((t.replace("*.sh", f) + " --help",
                                          help_bytes(tree, os.path.join(os.path.dirname(t), f), [])))
            out[r[0]] = (files, tools)
        return len(text), out
    finally:
        subprocess.run(["git", "-C", repo, "worktree", "remove", "--force", tree], capture_output=True)
        os.rmdir(os.path.dirname(tree)) if os.path.isdir(os.path.dirname(tree)) and not os.listdir(os.path.dirname(tree)) else None


def run(opts):
    global MEMORY
    if getattr(opts, "memory_dir", None):
        MEMORY = opts.memory_dir
    repo = opts.repo
    old_ref = git(repo, "rev-parse", "--short=7", opts.old_ref + "^{commit}").decode().strip()
    new_ref = git(repo, "rev-parse", "--short=7", opts.new_ref + "^{commit}").decode().strip()
    base, old_rows, git_names, notes = old_arm(repo, old_ref, opts.old_loader)
    base_total = sum(b for _, b in base)
    loader_new, new_rows = new_arm(repo, new_ref)
    lines = []
    lines.append("# bench loadbytes: bytes an agent is told to read, per task")
    lines.append("")
    lines.append("Old arm: `%s` + everything its On invoke mandates at `%s` (%d B: loader, %d memories, %d git-* skills, "
                 "Git_Strategy.md, RUNBOOK.md) + the row's how-* skills and memories. New arm: in-repo lean loader at `%s` "
                 "(%d B) + the row's skills + `--help` of the row's tools. Zero model; rerun gives the same table."
                 % (opts.old_loader, old_ref, base_total, sum(1 for n, _ in base if n.startswith("memory")),
                    len(git_names), new_ref, loader_new))
    lines.append("")
    lines.append("| Task | Old B | New loader+skills B | New tool help B | New total B | Saved |")
    lines.append("|---|---:|---:|---:|---:|---:|")
    tot_old = tot_new = 0
    for new_label, old_label in TASKS:
        key = next((k for k in new_rows if k.startswith(new_label)), None)
        if key is None:
            sys.exit("bench loadbytes: new loader has no row starting %r" % new_label)
        files, tools = new_rows[key]
        nb = loader_new + sum(b for _, b in files)
        hb = sum(b for _, b in tools)
        extra = []
        if old_label:
            okey = next((k for k in old_rows if k.startswith(old_label)), None)
            if okey is None:
                sys.exit("bench loadbytes: old loader has no row starting %r" % old_label)
            extra = old_row_extra(old_rows[okey], git_names)
        ob = base_total + sum(b for _, b in extra)
        tot_old += ob
        tot_new += nb + hb
        lines.append("| %s | %d | %d | %d | %d | %.0f%% |" % (new_label, ob, nb, hb, nb + hb, 100.0 * (ob - nb - hb) / ob))
    lines.append("| **All 13 tasks** | %d | | | %d | %.0f%% |" % (tot_old, tot_new, 100.0 * (tot_old - tot_new) / tot_old))
    if notes:
        lines.append("")
        lines.extend("- " + n + "." for n in notes)
    text = "\n".join(lines) + "\n"
    if opts.out:
        with open(opts.out, "w") as f:
            f.write(text)
    sys.stdout.write(text)
    return 0
