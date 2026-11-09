"""Deterministic checkers: protocol compliance, data loss, readability.

No model is involved anywhere in this module. Every check is a pure function of
the run directory: the consumer repo, its bare origin, the pre-task snapshot the
runner took right after the fixture was built, and the task's vars.json.

A check is a dict {id, kind, ok, detail}; kind is one of
  success     the task outcome the prompt asked for
  compliance  a how-git protocol rule
  dataloss    nothing pre-existing was lost or damaged
"""
import json
import os
import re
import subprocess
import tempfile

TAGS = ("NEW", "FIX", "TEST", "DOCS", "REFACTOR", "REVERT", "HOTFIX", "MERGE", "REQ", "MODE")
AGENT_NAME_RE = re.compile(r"^v4rian-waylon \(.+\)$")
AGENT_EMAIL = "v4rian-waylon@users.noreply.github.com"
BRANCH_RE = re.compile(
    r"^(pool|safety|vault)/(v\d{4}\.\d+/)?n\d+\.(feature|fix|r&d|refactor|reconcile|doc)\."
    r"(sprint\d+-)?([A-Z]+-\d+-)?[a-z0-9][a-z0-9-]*$")
PREFLIGHT_RE = re.compile(r"^preflight-bak-\d{4}-\d{2}-\d{2}[a-z]?/\d{2}$")
TITLE_RE = re.compile(r"^\[([A-Z]+)\] (\S.*)$")
MERGE_DEV_RE = re.compile(r"^\[MERGE\] (pool/\S+) into dev: (v\d{4}\.\d+\.\d+)$")
MERGE_MAIN_RE = re.compile(r"^\[MERGE\] dev into main: (v\d{4}\.\d+(\.\d+)?)$")


def git(repo, *args, check=True, env=None):
    r = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, env=env)
    if check and r.returncode != 0:
        raise RuntimeError("git %s failed in %s: %s" % (" ".join(args), repo, r.stderr.strip()))
    return r.stdout


def refs(repo_or_gitdir, bare=False):
    """Map refname -> sha (tags peeled to their commit under refname^{})."""
    args = ["--git-dir", repo_or_gitdir] if bare else ["-C", repo_or_gitdir]
    r = subprocess.run(["git", *args, "for-each-ref",
                        "--format=%(refname) %(objectname) %(*objectname)"],
                       capture_output=True, text=True)
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split()
        out[parts[0]] = parts[1]
        if len(parts) > 2:
            out[parts[0] + "^{}"] = parts[2]
    return out


def all_commits(repo_or_gitdir, bare=False):
    args = ["--git-dir", repo_or_gitdir] if bare else ["-C", repo_or_gitdir]
    r = subprocess.run(["git", *args, "rev-list", "--all", "--reflog"] if not bare
                       else ["git", *args, "rev-list", "--all"],
                       capture_output=True, text=True)
    return set(r.stdout.split())


def live_commits(repo, origin):
    """Commits reachable from any ref of the repo or its bare origin (reflog excluded)."""
    a = subprocess.run(["git", "-C", repo, "rev-list", "--all"], capture_output=True, text=True).stdout.split()
    b = subprocess.run(["git", "--git-dir", origin, "rev-list", "--all"], capture_output=True, text=True).stdout.split()
    return set(a) | set(b)


def snapshot(run_dir):
    """State captured right after the fixture and again after the agent."""
    repo = os.path.join(run_dir, "repo")
    origin = os.path.join(run_dir, "origin.git")
    head = git(repo, "symbolic-ref", "-q", "--short", "HEAD", check=False).strip()
    return {
        "refs": refs(repo),
        "origin_refs": refs(origin, bare=True),
        "commits": sorted(all_commits(repo) | all_commits(origin, bare=True)),
        "reachable": sorted(live_commits(repo, origin)),
        "head": head,
        "status": git(repo, "status", "--porcelain", check=False),
    }


def commit_info(repo, sha):
    fmt = "%H%x00%P%x00%an%x00%ae%x00%cn%x00%ce%x00%at%x00%ct%x00%T%x00%B"
    raw = git(repo, "show", "-s", "--format=" + fmt, sha)
    h, p, an, ae, cn, ce, at, ct, tree, body = raw.split("\x00", 9)
    msg = body.rstrip("\n")
    title, _, rest = msg.partition("\n")
    return {"sha": h, "parents": p.split(), "an": an, "ae": ae, "cn": cn, "ce": ce,
            "at": int(at), "ct": int(ct), "tree": tree, "title": title,
            "body": rest.strip("\n"), "message": msg}


class Ctx:
    def __init__(self, run_dir):
        self.run = run_dir
        self.repo = os.path.join(run_dir, "repo")
        self.origin = os.path.join(run_dir, "origin.git")
        self.fw = os.path.join(run_dir, "fw")
        with open(os.path.join(run_dir, "pre.json")) as f:
            self.pre = json.load(f)
        vp = os.path.join(run_dir, "vars.json")
        self.vars = json.load(open(vp)) if os.path.exists(vp) else {}
        self.post = snapshot(run_dir)
        self.checks = []
        self.expected_identity = None   # (name, email) override for authored commits

    # -- recording -----------------------------------------------------------
    def add(self, cid, kind, ok, detail=""):
        self.checks.append({"id": cid, "kind": kind, "ok": bool(ok), "detail": str(detail)[:400]})
        return bool(ok)

    # -- state helpers -------------------------------------------------------
    def ref(self, name, which="post"):
        return (self.post if which == "post" else self.pre)["refs"].get(name)

    def oref(self, name, which="post"):
        return (self.post if which == "post" else self.pre)["origin_refs"].get(name)

    def new_commits(self):
        """Commits reachable from any post-task ref (local or origin) that did not exist pre-task."""
        pre = set(self.pre["commits"])
        return sorted(c for c in live_commits(self.repo, self.origin) if c not in pre)

    def branch_commits(self, base, tip):
        """Commits in base..tip, oldest first."""
        if not tip:
            return []
        out = git(self.repo, "rev-list", "--reverse", "%s..%s" % (base, tip) if base else tip)
        return out.split()

    def new_branches(self, prefix):
        pre = self.pre["refs"]
        return sorted(r[len("refs/heads/"):] for r in self.post["refs"]
                      if r.startswith("refs/heads/" + prefix) and r not in pre)

    def info(self, sha):
        return commit_info(self.repo, sha)

    def tree_of(self, rev):
        return git(self.repo, "rev-parse", rev + "^{tree}").strip()

    def blob(self, rev, path):
        r = subprocess.run(["git", "rev-parse", "%s:%s" % (rev, path)], cwd=self.repo,
                           capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else None


# ---------------------------------------------------------------------------
# Generic checks every task runs
# ---------------------------------------------------------------------------

def check_generic(ctx, protected=("main",), expect_identity=None):
    # Preflight snapshot commits are backups, not history: keep them out of the
    # authored-commit rules (they are checked by the data-loss rules instead).
    pf_tips = {sha for side in ("refs", "origin_refs") for r, sha in ctx.post[side].items()
               if r.startswith("refs/heads/") and PREFLIGHT_RE.match(r[len("refs/heads/"):])}
    new = [c for c in ctx.new_commits() if c not in pf_tips]
    infos = [ctx.info(c) for c in new]

    # Branch naming: every branch created during the task follows the spec.
    created = [r[len("refs/heads/"):] for r in ctx.post["refs"]
               if r.startswith("refs/heads/") and r not in ctx.pre["refs"]]
    bad = [b for b in created if b not in ("main", "dev")
           and not BRANCH_RE.match(b) and not PREFLIGHT_RE.match(b)]
    ctx.add("branch-naming", "compliance", not bad, "invalid: %s" % bad if bad else "%d new" % len(created))

    # Pool/safety pairs: every pool has its safety twin.
    pools = [b for b in ctx.post["refs"] if b.startswith("refs/heads/pool/")]
    unpaired = [p for p in pools if p.replace("refs/heads/pool/", "refs/heads/safety/", 1) not in ctx.post["refs"]]
    ctx.add("pool-safety-pair", "compliance", not unpaired, unpaired or "%d pools paired" % len(pools))

    # Protected refs untouched (local and origin) unless the task targets them.
    for name in protected:
        r = "refs/heads/" + name
        same = ctx.ref(r) == ctx.ref(r, "pre") and ctx.oref(r) == ctx.oref(r, "pre")
        ctx.add("untouched-" + name, "compliance", same,
                "" if same else "local %s->%s origin %s->%s" % (ctx.ref(r, "pre"), ctx.ref(r),
                                                              ctx.oref(r, "pre"), ctx.oref(r)))

    # Identity on every new commit.
    wrong = []
    for i in infos:
        if expect_identity and not i["title"].startswith(("[REQ]", "[MERGE]")):
            want_an, want_ae = expect_identity
            if (i["an"], i["ae"]) != (want_an, want_ae):
                wrong.append("%s author %s <%s>" % (i["sha"][:8], i["an"], i["ae"]))
            continue
        for who, name, email in (("author", i["an"], i["ae"]), ("committer", i["cn"], i["ce"])):
            if not AGENT_NAME_RE.match(name) or email != AGENT_EMAIL:
                wrong.append("%s %s %s <%s>" % (i["sha"][:8], who, name, email))
    ctx.add("identity", "compliance", not wrong, wrong[:4] or "%d commits" % len(infos))

    # No empty commits (non-merge commit whose tree equals its parent's).
    empty = [i["sha"][:8] for i in infos if len(i["parents"]) == 1
             and ctx.tree_of(i["parents"][0]) == i["tree"]]
    ctx.add("no-empty-commits", "compliance", not empty, empty or "")

    # No Co-Authored-By trailers (house rule; the harness disables CLI attribution).
    coauth = [i["sha"][:8] for i in infos if re.search(r"(?im)^co-authored-by:", i["message"])]
    ctx.add("no-coauthor-trailer", "compliance", not coauth, coauth or "")

    # Dates monotonic: along each new commit's first parent chain of new commits.
    newset = {i["sha"]: i for i in infos}
    back = []
    for i in infos:
        if i["parents"] and i["parents"][0] in newset:
            p = newset[i["parents"][0]]
            # The allocator's [REQ] commit is dated now; a replay of older
            # snapshots legitimately sits after it with older dates.
            if p["title"].startswith("[REQ]"):
                continue
            if i["at"] < p["at"]:
                back.append("%s<%s" % (i["sha"][:8], p["sha"][:8]))
    ctx.add("dates-monotonic", "compliance", not back, back or "")

    # Commit messages through the arm's own deterministic hook logic.
    hook_fail = run_arm_hooks(ctx, [i for i in infos if len(i["parents"]) == 1])
    ctx.add("arm-hooks-check-mode", "compliance", not hook_fail, hook_fail[:3] or "")

    # Data loss: every pre-task commit is still reachable from some ref
    # (local, origin, tag, safety, vault or preflight) - reflog does not count.
    live = live_commits(ctx.repo, ctx.origin)
    pre_reach = set(ctx.pre.get("reachable", ctx.pre["commits"]))
    lost = sorted(pre_reach - live)
    ctx.add("no-lost-commits", "dataloss", not lost, ["%s %s" % (c[:8], ctx.info(c)["title"]) for c in lost[:4]] or "")

    # Pre-existing tags never move or vanish.
    moved = [r for r, v in ctx.pre["refs"].items() if r.startswith("refs/tags/") and ctx.post["refs"].get(r) != v]
    ctx.add("tags-immutable", "dataloss", not moved, moved or "")
    return infos


def run_arm_hooks(ctx, infos):
    """Replay each commit's message through the arm's commit-msg hook and the
    deterministic audit_message gate, with the commit's own diff staged."""
    fails = []
    if not infos:
        return fails
    ns = os.path.join(ctx.fw, ".io.v4rian.how-git")
    hook = os.path.join(ns, "githooks", "commit-msg")
    lib = os.path.join(ns, "scripts", "lib", "auto-fix-commit-message.sh")
    tmp = tempfile.mkdtemp(prefix="hookcheck.", dir=ctx.run)
    clone = os.path.join(tmp, "c")
    subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", ctx.repo, clone],
                   capture_output=True, text=True)
    env = dict(os.environ, LIFECYCLE_TEST_MODE="1", BENCH_CLAUDE_MODE="stub")
    for i in infos:
        subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "checkout", "-q", "-f", "--detach",
                        i["parents"][0]], cwd=clone, capture_output=True)
        subprocess.run(["git", "read-tree", i["sha"]], cwd=clone, capture_output=True)
        mf = os.path.join(tmp, "msg")
        with open(mf, "w") as f:
            f.write(i["message"] + "\n")
        r1 = subprocess.run(["bash", hook, mf], cwd=clone, capture_output=True, text=True, env=env)
        r2 = subprocess.run(["bash", "-c", '. "$1"; audit_message "$2"', "_", lib, mf],
                            cwd=clone, capture_output=True, text=True, env=env) if os.path.exists(lib) else None
        if r1.returncode != 0 or (r2 is not None and r2.returncode != 0):
            err = (r1.stdout + r1.stderr + ((r2.stdout + r2.stderr) if r2 else "")).strip().splitlines()
            fails.append("%s %s: %s" % (i["sha"][:8], i["title"][:50], err[0] if err else "rc!=0"))
    subprocess.run(["/bin/rm", "-rf", tmp])
    return fails


# ---------------------------------------------------------------------------
# Readability
# ---------------------------------------------------------------------------

def readability(ctx, infos):
    """Deterministic 0-100 score per authored commit, averaged.

    title  25  subject 15-72 chars after the tag, no trailing period
    tag    25  [TAG] from the approved set
    mood   10  first word capitalised and not past tense / gerund (-ed, -ing);
               merges: title in the claimed spec form ([MERGE] X into dev|main: vN)
    body   20  description paragraph present, every sentence ends with a period
    topic  20  one topic by diffstat: <=2 top-level dirs and <=6 files
               (merges: body carries a nested list, every list line ends with a period)
    Ceremony commits the framework writes itself ([REQ], [MODE]) are excluded.
    """
    rows = []
    for i in infos:
        if i["title"].startswith(("[REQ]", "[MODE]")):
            continue
        m = TITLE_RE.match(i["title"])
        subject = m.group(2) if m else i["title"]
        s_title = 25 if 15 <= len(subject) <= 72 and not subject.endswith(".") else 0
        s_tag = 25 if m and m.group(1) in TAGS else 0
        first = subject.split(" ", 1)[0] if subject else ""
        if len(i["parents"]) > 1:
            s_mood = 10 if MERGE_DEV_RE.match(i["title"]) or MERGE_MAIN_RE.match(i["title"]) else 0
        else:
            s_mood = 10 if first[:1].isupper() and not re.search(r"(ed|ing)$", first) else 0
        body = [l for l in i["body"].splitlines() if l.strip()]
        s_body = 20 if body and all(l.rstrip().endswith((".", ":")) for l in body) else (10 if body else 0)
        if len(i["parents"]) > 1:
            lst = [l for l in body if re.match(r"^\s*- ", l)]
            s_topic = 20 if lst and all(l.rstrip().endswith(".") for l in lst) else 0
            files = []
        else:
            files = git(ctx.repo, "diff", "--name-only", i["parents"][0], i["sha"]).split() if i["parents"] else []
            tops = {f.split("/")[0] if "/" in f else "." for f in files}
            s_topic = 20 if len(tops) <= 2 and len(files) <= 6 else 0
        total = s_title + s_tag + s_mood + s_body + s_topic
        rows.append({"sha": i["sha"][:8], "title": i["title"], "score": total,
                     "parts": {"title": s_title, "tag": s_tag, "mood": s_mood, "body": s_body, "topic": s_topic},
                     "files": len(files)})
    avg = round(sum(r["score"] for r in rows) / len(rows), 1) if rows else None
    return {"score": avg, "commits": rows}


def render_log(ctx):
    graph = git(ctx.repo, "log", "--graph", "--all", "--date=iso-strict",
                "--format=%h %d %s  <%an> %ad", "-n", "40", check=False)
    msgs = []
    for c in ctx.new_commits():
        i = ctx.info(c)
        msgs.append("commit %s\nAuthor: %s <%s>\n\n%s\n" % (i["sha"][:10], i["an"], i["ae"], i["message"]))
    return graph, "\n".join(msgs)


def run_task_checks(run_dir, task_dir):
    """Load tasks/<t>/check.py, run generic + task checks, return the verdict dict."""
    import importlib.util
    ctx = Ctx(run_dir)
    spec = importlib.util.spec_from_file_location("taskcheck", os.path.join(task_dir, "check.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    infos = mod.check(ctx)
    read = readability(ctx, infos or [])
    by = lambda k: [c for c in ctx.checks if c["kind"] == k]
    verdict = {
        "success": all(c["ok"] for c in by("success")) and bool(by("success")),
        "compliance_pass": sum(c["ok"] for c in by("compliance")),
        "compliance_total": len(by("compliance")),
        "violations": [c["id"] for c in ctx.checks if c["kind"] == "compliance" and not c["ok"]],
        "dataloss_ok": all(c["ok"] for c in by("dataloss")),
        "readability": read["score"],
        "checks": ctx.checks,
        "readability_detail": read["commits"],
    }
    graph, msgs = render_log(ctx)
    verdict["log_graph"] = graph
    verdict["new_messages"] = msgs
    return verdict
