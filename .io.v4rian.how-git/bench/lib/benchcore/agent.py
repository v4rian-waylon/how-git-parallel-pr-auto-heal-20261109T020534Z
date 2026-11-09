"""Agent-runner mode: build run dirs for an external agent, then ingest its usage.

`bench export` materialises every arm x task run dir exactly as `bench run` does
(fixture repo, arm framework, sandbox HOME with only that arm's loader and skills)
and writes AGENT_PROMPT.md, the full instruction an external agent follows.
`bench ingest` runs the deterministic checkers on the finished run dir and appends
one results.jsonl row carrying the usage numbers the agent runner reported, so
`bench summary` and `bench diff` read it like any measured run.
"""
import datetime
import json
import os
import shlex
import sys

from . import checks, core, metrics, report

RUN_MODEL_SLOT = "agent"


def env_prefix(run):
    """The exact `env -i ...` prefix that gives a command the sandbox env (stub nested
    audits: the external agent's runner holds no credential the shim could forward)."""
    env = core.sandbox_env(run, "stub")
    return "env -i " + " ".join("%s=%s" % (k, shlex.quote(v)) for k, v in sorted(env.items()))


def agent_prompt(run, arm, task_prompt):
    home = os.path.join(run, "home")
    repo = os.path.join(run, "repo")
    loader = os.path.join(home, ".claude", "skills", "how-git", "SKILL.md")
    skills = sorted(os.path.join(home, ".claude", "skills", d, "SKILL.md")
                    for d in os.listdir(os.path.join(home, ".claude", "skills"))
                    if os.path.isfile(os.path.join(home, ".claude", "skills", d, "SKILL.md")))
    hooks = sorted(os.path.join(home, ".claude", "hooks", f)
                   for f in os.listdir(os.path.join(home, ".claude", "hooks"))) \
        if os.path.isdir(os.path.join(home, ".claude", "hooks")) else []
    ident = ("GIT_AUTHOR_NAME='v4rian-waylon (<your model name>)' GIT_COMMITTER_NAME='v4rian-waylon (<your model name>)' "
             "GIT_AUTHOR_EMAIL=v4rian-waylon@users.noreply.github.com "
             "GIT_COMMITTER_EMAIL=v4rian-waylon@users.noreply.github.com")
    lines = [
        "# Benchmark run: arm %s, task %s" % (arm["name"], open(os.path.join(run, "TASK")).read().strip()),
        "",
        "You are the agent under measurement in one how-git benchmark run. Follow these rules exactly;",
        "a run that breaks them is discarded.",
        "",
        "## Sandbox rules",
        "",
        "1. Work only inside the repository `%s`. Never read, write or run anything in another repository," % repo,
        "   in `~/.claude`, in your own skills, memories or settings, or anywhere outside `%s`." % run,
        "2. Your only protocol source is the arm's loader `%s`." % loader,
        "   Wherever the task says \"invoke the `how-git` skill\" (or any skill), do not use your Skill tool:",
        "   read that loader with your file tools and follow it. Skills it names live at these absolute paths:",
    ]
    lines += ["   - `%s`" % s for s in skills]
    lines += [
        "   Paths it gives under `.io.v4rian.how-git/` are relative to the repository; `~` and `$HOME` mean `%s`." % home,
    ]
    if hooks:
        lines += ["   Hooks it names under `~/.claude/hooks/`: " + ", ".join("`%s`" % h for h in hooks) + "."]
    lines += [
        "3. Run every shell command (git, framework scripts, tests) from `%s` with this exact prefix," % repo,
        "   so the arm's git hooks, sandbox HOME, identity config and backup dirs apply:",
        "",
        "   ```",
        "   cd %s && %s <command>" % (shlex.quote(repo), env_prefix(run)),
        "   ```",
        "",
        "   `env -i` clears every other variable, so put the commit identity after the prefix:",
        "   `%s`." % ident,
        "4. Never pass `--no-verify`, never edit the hooks, `home/` or `fw/`, and never touch `origin.git` except by",
        "   pushing to it.",
        "5. When finished, stop. The orchestrator ingests the run with `bench ingest %s` and your usage numbers." % run,
        "",
        "## Task prompt",
        "",
        task_prompt.rstrip(),
        "",
    ]
    return "\n".join(lines)


def export(opts):
    repo = opts.framework_repo or core.framework_repo()
    arms = [core.load_arm(a, repo) for a in opts.arms.split(",") if a]
    tasks = core.task_dirs(opts.tasks)
    if not tasks:
        sys.exit("bench: no task matches --tasks %s" % opts.tasks)
    out_root = os.path.abspath(opts.out)
    os.makedirs(os.path.join(out_root, "runs"), exist_ok=True)
    bad = 0
    for a in arms:
        for t in tasks:
            run = os.path.join(out_root, "runs", "%s.%s.%s.r%d" % (a["name"], RUN_MODEL_SLOT, t, opts.rep))
            if os.path.exists(run):
                print("  [skip] %s exists; export never overwrites a run dir" % run)
                bad += 1
                continue
            prompt, err = core.prepare_run(run, a, t, repo)
            if err:
                print("  [FAIL] %s: %s" % (run, err), file=sys.stderr)
                bad += 1
                continue
            path = os.path.join(run, "AGENT_PROMPT.md")
            open(path, "w").write(agent_prompt(run, a, prompt))
            print("  [ok ] %-8s %-13s %s" % (a["name"], t, path))
    print("export: %d run dir(s) under %s" % (len(arms) * len(tasks) - bad, out_root))
    return 1 if bad else 0


def usage_cost(model, o):
    """USD at list price. With the token split given, exact as `bench run` prices it;
    with only a total, every token is priced at the input rate (an estimate)."""
    if model not in metrics.PRICES:
        sys.exit("bench: no list price for model %s (known: %s)" % (model, ", ".join(sorted(metrics.PRICES))))
    split = [o.input_tokens, o.output_tokens, o.cache_read_tokens, o.cache_write_tokens]
    if any(v is not None for v in split):
        u = {"inputTokens": o.input_tokens or 0, "outputTokens": o.output_tokens or 0,
             "cacheReadInputTokens": o.cache_read_tokens or 0, "cacheCreationInputTokens": o.cache_write_tokens or 0}
        return metrics.cost_of({model: u}), "token split at list price"
    return round(o.tokens * metrics.PRICES[model]["in"] / 1e6, 6), "total tokens at the input list price (estimate)"


def ingest(o):
    run = os.path.abspath(o.run)
    task_file, arm_file = os.path.join(run, "TASK"), os.path.join(run, "ARM.json")
    if not (os.path.isfile(task_file) and os.path.isfile(arm_file)):
        sys.exit("bench: %s is not an exported run dir (TASK and ARM.json required)" % run)
    task = open(task_file).read().strip()
    arm = json.load(open(arm_file))
    model = core.MODELS.get(o.model, o.model)
    cost, basis = usage_cost(model, o)
    verdict = checks.run_task_checks(run, os.path.join(core.TASKS, task))
    nested = metrics.parse_nested(os.path.join(run, "logs", "nested.jsonl"))
    split = {"input_tokens": o.input_tokens, "output_tokens": o.output_tokens,
             "cache_read_tokens": o.cache_read_tokens, "cache_creation_tokens": o.cache_write_tokens}
    res = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
           "run": run, "arm": arm["name"], "arm_ref": arm["ref"], "arm_sha": arm["sha"][:10],
           "loader_src": arm["loader_src"], "loader_md5": arm["loader_md5"], "loader_bytes": arm["loader_bytes"],
           "model": model, "task": task, "rep": int(run.rsplit(".r", 1)[-1]) if ".r" in run else 1,
           "mode": "external-agent", "wall_s": round(o.duration_ms / 1000.0, 1), "max_turns": None,
           "price_source": metrics.PRICE_SOURCE, "cost_basis": basis,
           "turns": None, "tool_calls": o.tool_uses, "total_tokens": o.tokens,
           "cost_usd": cost, "total_cost_usd": round(cost + nested["cost_usd"], 6), "nested": nested}
    res.update({k: v for k, v in split.items() if v is not None})
    res.update({k: verdict[k] for k in ("success", "compliance_pass", "compliance_total", "violations",
                                        "dataloss_ok", "readability")})
    res["checks"] = verdict["checks"]
    json.dump(res, open(os.path.join(run, "result.json"), "w"), indent=1)
    report.write_run_report(run, res, verdict)
    results = os.path.abspath(o.results) if o.results else \
        os.path.join(os.path.dirname(os.path.dirname(run)), "results.jsonl")
    row = {k: v for k, v in res.items() if k != "checks"}
    kept = [l for l in (open(results).read().splitlines() if os.path.exists(results) else [])
            if l.strip() and json.loads(l).get("run") != run]  # re-ingest replaces the run's row
    with open(results, "w") as f:
        f.write("".join(l + "\n" for l in kept) + json.dumps(row) + "\n")
    for c in verdict["checks"]:
        print("[%s] %-10s %-28s %s" % ("x" if c["ok"] else " ", c["kind"], c["id"], c["detail"]))
    print("success=%s compliance=%s/%s dataloss_ok=%s readability=%s tokens=%d $%s (%s)" % (
        res["success"], res["compliance_pass"], res["compliance_total"], res["dataloss_ok"], res["readability"],
        o.tokens, res["total_cost_usd"], basis))
    print("results: %s" % results)
    return 0 if res["success"] else 1
