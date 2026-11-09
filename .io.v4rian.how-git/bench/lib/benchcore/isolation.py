"""Isolation receipt: one cheap probe session in a real benchmark sandbox.

Proves, from the session's own stream-json, that a benchmark agent sees only its
arm: the skill listing holds the arm's skills plus Claude Code built-ins, no user
plugin, MCP server or Claude Code hook loads (so the operator's Stop hook can never
fire), the operator's CLAUDE.md is absent from context and unreadable, and the arm
loader is what the how-git skill returns.
"""
import datetime
import json
import os
import subprocess

from . import core, metrics

PROBE = """This is an isolation probe; answer from what you actually see.
1. Invoke the `how-git` skill, then quote its first markdown heading line.
2. Use the Read tool on `{real_claude_md}` and report whether it succeeded.
3. Without tools: is any user-level CLAUDE.md, memory index, or text naming Joel or waylon-mm present in your context? Answer yes or no and quote it if yes.
4. List the skill names available to you, comma separated.
End with one line: PROBE-END."""

OPERATOR_ONLY_SKILLS = ("how-deploy", "sym9", "how-compile", "jseek", "voice-ask", "warpcode", "how-think")


def probe(o):
    repo = core.framework_repo()
    arm = core.load_arm(o.arm, repo)
    auth, src = core.resolve_auth()
    if not auth:
        print("isolation: no usable credential; the harness never starts a login flow")
        return 1
    root = os.path.join(os.environ.get("TMPDIR", "/tmp"), "neo-bench",
                        datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-isolation")
    run = os.path.join(root, "probe")
    core.materialize(run, arm, repo)
    subprocess.run(["bash", os.path.join(core.TASKS, "b-branch", "setup.sh")], cwd=run,
                   env=core.sandbox_env(run, "stub"), check=True, capture_output=True)
    env = core.sandbox_env(run, "meter", auth=auth, nested_model=o.model)
    real_md = os.path.join(core.REAL_HOME, ".claude", "CLAUDE.md")
    cmd = [env["BENCH_REAL_CLAUDE"], "-p", PROBE.format(real_claude_md=real_md), "--model", o.model,
           "--output-format", "stream-json", "--verbose", "--include-hook-events", "--no-session-persistence",
           "--max-turns", "8", "--permission-mode", "bypassPermissions"]
    stream = os.path.join(run, "logs", "stream.jsonl")
    with open(stream, "w") as so:
        subprocess.run(cmd, cwd=os.path.join(run, "repo"), env=env, stdout=so, stderr=subprocess.DEVNULL,
                       stdin=subprocess.DEVNULL, timeout=600)
    sm = metrics.parse_stream(stream, run, core.REAL_HOME)
    res = sm["result"] or {}
    reply = res.get("result") or ""
    skills = (sm["init"] or {}).get("skills") or []
    loader_head = next((l for l in arm["loader_text"].splitlines() if l.startswith("# ")), "")
    read_denied = any(d.get("tool_name") == "Read" for d in res.get("permission_denials") or []) \
        or "denied" in reply.lower() or "not permitted" in reply.lower()
    receipt = {
        "arm": arm["name"], "model": o.model, "auth_source": src, "run": run,
        "skills_listed": skills,
        "arm_skills_present": all(s in skills for s in ("how-git", "how-preflight", "how-push")),
        "operator_skills_absent": not any(s in skills for s in OPERATOR_ONLY_SKILLS),
        "plugins": (sm["init"] or {}).get("plugins"),
        "mcp_servers": (sm["init"] or {}).get("mcp_servers"),
        "claude_hook_events": sm["claude_hook_events"],
        "loader_heading_expected": loader_head,
        "loader_heading_quoted": loader_head in reply,
        "operator_claude_md_read_denied": read_denied,
        "permission_denials": res.get("permission_denials"),
        "isolation_leak_inputs": sm["isolation_leaks"],
        "cost_usd": metrics.cost_of(res.get("modelUsage")),
        "reply": reply[-1500:],
    }
    receipt["isolated"] = (receipt["arm_skills_present"] and receipt["operator_skills_absent"]
                           and receipt["claude_hook_events"] == 0 and not receipt["mcp_servers"]
                           and receipt["loader_heading_quoted"] and read_denied)
    path = os.path.join(root, "isolation-receipt.json")
    json.dump(receipt, open(path, "w"), indent=1)
    print(json.dumps({k: v for k, v in receipt.items() if k != "reply"}, indent=1))
    print("--- agent reply ---\n" + receipt["reply"])
    print("receipt: " + path)
    return 0 if receipt["isolated"] else 1
