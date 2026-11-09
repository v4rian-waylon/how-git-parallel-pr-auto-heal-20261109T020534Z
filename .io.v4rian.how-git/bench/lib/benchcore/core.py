"""Arms, auth, sandbox materialisation and the run loop."""
import datetime
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import time

from . import checks, metrics

BENCH = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIB = os.path.join(BENCH, "lib")
TASKS = os.path.join(BENCH, "tasks")
MODELS = {"opus": "claude-opus-5-5", "fable": "claude-fable-5-1", "haiku": "claude-haiku-5-5"}
REAL_HOME = os.path.expanduser("~")


def framework_repo():
    return subprocess.run(["git", "-C", BENCH, "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True).stdout.strip()


# ---------------------------------------------------------------------------
# Arms
# ---------------------------------------------------------------------------

def load_arm(spec, repo):
    """spec: a name with arms/<name>.conf, or NAME=LOADER:REF (LOADER a path or @ref:<path>)."""
    if "=" in spec:
        name, rest = spec.split("=", 1)
        loader, _, ref = rest.rpartition(":")
        conf = {"ref": ref, "loader": loader, "bundle": "arms/how-git/bundle"}
    else:
        name, conf = spec, {}
        path = os.path.join(BENCH, "arms", name + ".conf")
        if not os.path.exists(path):
            sys.exit("bench: no arm config %s" % path)
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip()
    sha = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", conf["ref"] + "^{commit}"],
                         capture_output=True, text=True).stdout.strip()
    if not sha:
        sys.exit("bench: arm %s ref %s does not resolve in %s" % (name, conf["ref"], repo))
    bundle = conf.get("bundle", "arms/how-git/bundle")
    bundle = bundle if os.path.isabs(bundle) else os.path.join(BENCH, bundle)
    # An empty loader= means the bundle's own loader (the baseline arm). A named
    # loader must resolve: falling back would silently measure the baseline twice.
    lo = conf.get("loader", "")
    if lo.startswith("@ref:"):
        r = subprocess.run(["git", "-C", repo, "show", "%s:%s" % (sha, lo[5:])], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("bench: arm %s loader %s does not exist at %s (%s); refusing to fall back to the baseline"
                     % (name, lo[5:], conf["ref"], sha[:7]))
        loader_text, loader_src = r.stdout, "%s@%s" % (lo[5:], sha[:7])
    elif lo:
        p = lo if os.path.isabs(lo) else os.path.join(BENCH, lo)
        if not os.path.isfile(p):
            sys.exit("bench: arm %s loader %s does not exist; refusing to fall back to the baseline" % (name, p))
        loader_text, loader_src = open(p).read(), p
    else:
        p = os.path.join(bundle, "dot-claude", "skills", "how-git", "SKILL.md")
        if not os.path.isfile(p):
            sys.exit("bench: arm %s bundle loader %s does not exist" % (name, p))
        loader_text, loader_src = open(p).read(), "bundle:" + os.path.relpath(p, BENCH)
    import hashlib
    return {"name": name, "ref": conf["ref"], "sha": sha, "bundle": bundle, "loader_text": loader_text,
            "loader_src": loader_src, "loader_md5": hashlib.md5(loader_text.encode()).hexdigest(),
            "loader_bytes": len(loader_text.encode())}


# ---------------------------------------------------------------------------
# Auth: use what already exists, never mint, refresh or write a credential.
# ---------------------------------------------------------------------------

def resolve_auth():
    """Order: ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN, BENCH_TOKEN_FILE, the newest
    long-lived `claude setup-token` token in the ag.i pool (read-only; it has no refresh
    lineage, so using it can never burn the CLI login). Returns (env-dict, source)."""
    if os.environ.get("ANTHROPIC_API_KEY"):
        return {"ANTHROPIC_API_KEY": os.environ["ANTHROPIC_API_KEY"]}, "env ANTHROPIC_API_KEY"
    if os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        return {"CLAUDE_CODE_OAUTH_TOKEN": os.environ["CLAUDE_CODE_OAUTH_TOKEN"]}, "env CLAUDE_CODE_OAUTH_TOKEN"
    tf = os.environ.get("BENCH_TOKEN_FILE")
    if tf and os.path.exists(tf):
        raw = open(tf).read().strip()
        try:
            raw = json.loads(raw).get("accessToken", raw)
        except ValueError:
            pass
        return {"CLAUDE_CODE_OAUTH_TOKEN": raw}, "BENCH_TOKEN_FILE"
    best = None
    for f in glob.glob(os.path.join(REAL_HOME, ".config", "ag-intake", "auths", "*.json")):
        try:
            rec = json.load(open(f))
        except ValueError:
            continue
        if rec.get("custody") == "longterm" and rec.get("accessToken"):
            if not best or rec.get("addedAtMs", 0) > best[0].get("addedAtMs", 0):
                best = (rec, f)
    if best:
        return {"CLAUDE_CODE_OAUTH_TOKEN": best[0]["accessToken"]}, "ag.i longterm pool " + os.path.basename(best[1])
    return None, "none"


# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

def settings_json():
    deny_root = "/" + REAL_HOME  # "//abs/path" is the absolute-path form of a permission rule
    return {
        "includeCoAuthoredBy": False,
        "attribution": {"commit": "", "pr": ""},
        "autoMemoryEnabled": False,
        "permissions": {"deny": ["Read(/%s/**)" % deny_root, "Edit(/%s/**)" % deny_root,
                                 "Write(/%s/**)" % deny_root]},
    }


def materialize(run, arm, repo):
    os.makedirs(os.path.join(run, "logs"))
    for d in ("bin", "baks", "tmp"):
        os.makedirs(os.path.join(run, d))
    subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", repo, os.path.join(run, "fw")], check=True)
    subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "advice.detachedHead=false",
                    "checkout", "-q", "--detach", arm["sha"]], cwd=os.path.join(run, "fw"), check=True)
    home = os.path.join(run, "home")
    shutil.copytree(os.path.join(arm["bundle"], "dot-claude"), os.path.join(home, ".claude"))
    os.makedirs(os.path.join(home, ".claude", "skills", "how-git"), exist_ok=True)
    with open(os.path.join(home, ".claude", "skills", "how-git", "SKILL.md"), "w") as f:
        f.write(arm["loader_text"])
    with open(os.path.join(home, ".claude", "settings.json"), "w") as f:
        json.dump(settings_json(), f, indent=1)
    with open(os.path.join(home, ".gitconfig"), "w") as f:
        f.write("[user]\n\tname = bench-unset-identity\n\temail = unset@bench.invalid\n"
                "[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n")
    shim = os.path.join(run, "bin", "claude")
    shutil.copy(os.path.join(LIB, "claude-shim"), shim)
    os.chmod(shim, 0o755)


def sandbox_env(run, mode, auth=None, nested_model=None):
    home = os.path.join(run, "home")
    env = {
        "HOME": home, "USER": os.environ.get("USER", "bench"), "LOGNAME": os.environ.get("USER", "bench"),
        "SHELL": "/bin/bash", "TERM": "dumb", "LANG": "en_US.UTF-8", "TMPDIR": os.path.join(run, "tmp"),
        "PATH": os.path.join(run, "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
        "CLAUDE_CONFIG_DIR": os.path.join(home, ".claude"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "BAKS_DIR": os.path.join(run, "baks"), "BAKS_MIRROR": os.path.join(run, "baks-mirror-disabled"),
        "BENCH_RUN": run, "BENCH_FW": os.path.join(run, "fw"), "BENCH_LIB": LIB,
        "BENCH_PYTHON": sys.executable, "BENCH_CLAUDE_MODE": mode,
        "BENCH_NESTED_LOG": os.path.join(run, "logs", "nested.jsonl"),
        "BENCH_REAL_CLAUDE": shutil.which("claude") or "",
        "DISABLE_AUTOUPDATER": "1",
    }
    if nested_model:
        env["BENCH_NESTED_MODEL"] = nested_model
    if auth:
        env.update(auth)
    return env


def task_dirs(filter_):
    all_ = sorted(d for d in os.listdir(TASKS) if os.path.isdir(os.path.join(TASKS, d)))
    if not filter_:
        return all_
    want = [f.strip() for f in filter_.split(",") if f.strip()]
    return [d for d in all_ if any(d == w or d.split("-")[0] == w for w in want)]


def build_prompt(task, run):
    pre = open(os.path.join(TASKS, "preamble.md")).read()
    body = open(os.path.join(TASKS, task, "prompt.md")).read()
    vp = os.path.join(run, "vars.json")
    vars_ = json.load(open(vp)) if os.path.exists(vp) else {}
    for k, v in vars_.items():
        if isinstance(v, str):
            body = body.replace("{{%s}}" % k, v)
    return pre + body


# ---------------------------------------------------------------------------
# One run
# ---------------------------------------------------------------------------

def prepare_run(run, arm, task, repo):
    """Build one run dir exactly as a measured run starts: sandbox, fixture, pre-state
    snapshot and the task prompt. Returns (prompt, None) or (None, error)."""
    materialize(run, arm, repo)
    open(os.path.join(run, "TASK"), "w").write(task + "\n")
    arm_meta = {k: v for k, v in arm.items() if k != "loader_text"}
    json.dump(arm_meta, open(os.path.join(run, "ARM.json"), "w"), indent=1)
    henv = sandbox_env(run, "stub")
    r = subprocess.run(["bash", os.path.join(TASKS, task, "setup.sh")], cwd=run, env=henv,
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, "fixture setup failed: " + (r.stderr or r.stdout)[-500:]
    pre = checks.snapshot(run)
    json.dump(pre, open(os.path.join(run, "pre.json"), "w"))
    prompt = build_prompt(task, run)
    open(os.path.join(run, "logs", "prompt.md"), "w").write(prompt)
    return prompt, None


def one_run(opts, arm, model, task, rep, out_root, auth):
    run = os.path.join(out_root, "runs", "%s.%s.%s.r%d" % (arm["name"], model.replace("claude-", ""), task, rep))
    prompt, err = prepare_run(run, arm, task, opts.repo)
    if err:
        return {"run": run, "arm": arm["name"], "model": model, "task": task, "rep": rep, "error": err}
    t0 = time.time()
    if opts.dry:
        aenv = sandbox_env(run, "stub")
        r = subprocess.run(["bash", os.path.join(TASKS, task, "reference.sh")], cwd=os.path.join(run, "repo"),
                           env=aenv, capture_output=True, text=True)
        open(os.path.join(run, "logs", "reference.log"), "w").write(r.stdout + r.stderr)
        mode = "dry-reference" if r.returncode == 0 else "dry-reference-failed"
    else:
        aenv = sandbox_env(run, "meter", auth=auth, nested_model=opts.nested_model or model)
        cmd = [aenv["BENCH_REAL_CLAUDE"], "-p", prompt, "--model", model, "--output-format", "stream-json",
               "--verbose", "--include-hook-events", "--no-session-persistence",
               "--max-turns", str(opts.max_turns), "--permission-mode", "bypassPermissions"]
        if opts.max_budget_usd:
            cmd += ["--max-budget-usd", str(opts.max_budget_usd)]
        if opts.disallow:
            cmd += ["--disallowedTools", opts.disallow]
        if opts.effort:
            cmd += ["--effort", opts.effort]
        with open(os.path.join(run, "logs", "stream.jsonl"), "w") as so, \
                open(os.path.join(run, "logs", "stderr.txt"), "w") as se:
            # Own process group, so a timeout also reaps whatever the agent left
            # running in the background (test suites, watchers).
            p = subprocess.Popen(cmd, cwd=os.path.join(run, "repo"), env=aenv, stdout=so, stderr=se,
                                 stdin=subprocess.DEVNULL, start_new_session=True)
            try:
                rc = p.wait(timeout=opts.timeout)
                mode = "agent" if rc == 0 else "agent-rc%d" % rc
            except subprocess.TimeoutExpired:
                mode = "agent-timeout"
            finally:
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
                if p.poll() is None:
                    p.wait()
    wall = round(time.time() - t0, 1)
    verdict = checks.run_task_checks(run, os.path.join(TASKS, task))
    sm = metrics.parse_stream(os.path.join(run, "logs", "stream.jsonl"), run, REAL_HOME)
    nested = metrics.parse_nested(os.path.join(run, "logs", "nested.jsonl"))
    met = metrics.summarize(sm, nested)
    res = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
           "run": run, "arm": arm["name"], "arm_ref": arm["ref"], "arm_sha": arm["sha"][:10],
           "loader_src": arm["loader_src"], "loader_md5": arm["loader_md5"], "loader_bytes": arm["loader_bytes"],
           "model": model, "task": task, "rep": rep, "mode": mode, "wall_s": wall,
           "max_turns": opts.max_turns, "price_source": metrics.PRICE_SOURCE}
    res.update(met)
    res.update({k: verdict[k] for k in ("success", "compliance_pass", "compliance_total", "violations",
                                        "dataloss_ok", "readability")})
    res["checks"] = verdict["checks"]
    json.dump(res, open(os.path.join(run, "result.json"), "w"), indent=1)
    from . import report
    report.write_run_report(run, res, verdict)
    return res


def run_matrix(opts):
    opts.repo = opts.framework_repo or framework_repo()
    arms = [load_arm(a, opts.repo) for a in opts.arms.split(",")]
    models = [MODELS.get(m, m) for m in opts.models.split(",")]
    tasks = task_dirs(opts.tasks)
    if not tasks:
        sys.exit("bench: no task matches --tasks %s" % opts.tasks)
    auth, auth_src = (None, "dry") if opts.dry else resolve_auth()
    if not opts.dry and not auth:
        sys.exit("bench: no usable credential (set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN); "
                 "the harness never starts a login flow")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_root = opts.out or os.path.join(os.environ.get("TMPDIR", "/tmp"), "neo-bench", stamp + ("-dry" if opts.dry else ""))
    os.makedirs(out_root, exist_ok=True)
    plan = [(a, m, t, r) for a in arms for m in models for t in tasks for r in range(1, opts.reps + 1)]
    print("bench: %d run(s) -> %s (auth: %s)" % (len(plan), out_root, auth_src), flush=True)
    for a in arms:
        print("  arm %-8s ref %s (%s) loader %s (%d B)" % (a["name"], a["ref"], a["sha"][:10], a["loader_src"],
                                                         a["loader_bytes"]), flush=True)
    results_path = os.path.join(out_root, "results.jsonl")
    from concurrent.futures import ThreadPoolExecutor
    results = []

    def go(item):
        a, m, t, r = item
        res = one_run(opts, a, m, t, r, out_root, auth)
        with open(results_path, "a") as f:
            f.write(json.dumps({k: v for k, v in res.items() if k != "checks"}) + "\n")
        flag = "ok " if res.get("success") else "FAIL"
        print("  [%s] %-7s %-16s %-13s r%d  %s  compliance %s/%s  dataloss %s  read %s  turns %s  $%s  %ss" % (
            flag, a["name"], m, t, r, res.get("mode", res.get("error", "")[:60]), res.get("compliance_pass"),
            res.get("compliance_total"), "ok" if res.get("dataloss_ok") else "LOSS", res.get("readability"),
            res.get("turns"), res.get("total_cost_usd"), res.get("wall_s")), flush=True)
        if res.get("violations"):
            print("         violations: %s" % ", ".join(res["violations"]), flush=True)
        return res

    with ThreadPoolExecutor(max_workers=max(1, opts.jobs)) as ex:
        results = list(ex.map(go, plan))
    from . import report
    summary = report.summary_markdown([r for r in results if "error" not in r])
    open(os.path.join(out_root, "summary.md"), "w").write(summary)
    print("\n" + summary)
    print("results: %s\nsummary: %s" % (results_path, os.path.join(out_root, "summary.md")))
    bad = [r for r in results if "error" in r]
    for r in bad:
        print("ERROR %s: %s" % (r["run"], r["error"]), file=sys.stderr)
    if opts.dry:
        failed = [r for r in results if "error" in r or not r.get("success") or r.get("violations")
                  or not r.get("dataloss_ok") or r.get("mode") != "dry-reference"]
        if failed:
            print("dry: %d reference run(s) did not pass every check" % len(failed), file=sys.stderr)
            return 1
        print("dry: every reference solution passes every checker on every arm")
    return 1 if bad else 0


# ---------------------------------------------------------------------------
# Checker self-test: known-bad solutions must trip the named checks.
# ---------------------------------------------------------------------------

def selftest(arm_name="how-git", out=None):
    repo = framework_repo()
    arm = load_arm(arm_name, repo)
    root = out or os.path.join(os.environ.get("TMPDIR", "/tmp"), "neo-bench",
                               datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-selftest")
    cases = sorted(glob.glob(os.path.join(BENCH, "selftest", "*.sh")))
    bad = 0
    for case in cases:
        head = dict(l[2:].split(":", 1) for l in open(case) if l.startswith("# ") and ":" in l[:20])
        task = head["task"].strip()
        want = head["expect-fail"].split()
        run = os.path.join(root, os.path.basename(case)[:-3])
        materialize(run, arm, repo)
        open(os.path.join(run, "TASK"), "w").write(task + "\n")
        env = sandbox_env(run, "stub")
        subprocess.run(["bash", os.path.join(TASKS, task, "setup.sh")], cwd=run, env=env, check=True,
                       capture_output=True)
        json.dump(checks.snapshot(run), open(os.path.join(run, "pre.json"), "w"))
        subprocess.run(["bash", case], cwd=os.path.join(run, "repo"), env=env, capture_output=True)
        v = checks.run_task_checks(run, os.path.join(TASKS, task))
        failing = {c["id"] for c in v["checks"] if not c["ok"]}
        missed = [w for w in want if w not in failing]
        ok = not missed and not v["success"] if any(
            c["kind"] == "success" and c["id"] in want for c in v["checks"]) else not missed
        bad += 0 if ok else 1
        print("[%s] %-22s expected to fail: %s%s" % ("ok " if ok else "BAD", os.path.basename(case), " ".join(want),
                                                    "" if not missed else "  MISSED: " + " ".join(missed)))
    print("selftest: %d/%d cases caught" % (len(cases) - bad, len(cases)))
    return 1 if bad else 0
