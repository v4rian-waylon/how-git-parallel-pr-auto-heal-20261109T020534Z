"""Per-run metrics from the Claude Code stream-json transcript plus the nested-claude log.

Source of truth for prices: the claude-api skill bundled with Claude Code 2.1.312
(shared/models.md, model table cached 2026-10-06; shared/prompt-caching.md
"Economics": cache writes 1.25x input for the 5-minute TTL and 2x for 1 hour,
cache reads 0.1x except Opus 5.5 at $0.20 and Fable 5.1 at $0.25). USD per
million tokens. Haiku 5.5 is the <=100K-token-prompt tier.
"""
import json
import os
import re

PRICE_SOURCE = ("claude-api skill (Claude Code 2.1.312) shared/models.md + shared/prompt-caching.md, "
                "list prices cached 2026-10-06")
PRICES = {
    "claude-opus-5-5":  {"in": 4.00,  "out": 20.00, "cw5m": 5.00,  "cw1h": 8.00,  "cr": 0.20},
    "claude-fable-5-1": {"in": 10.00, "out": 50.00, "cw5m": 12.50, "cw1h": 20.00, "cr": 0.25},
    "claude-haiku-5-5": {"in": 0.10,  "out": 0.50,  "cw5m": 0.125, "cw1h": 0.20,  "cr": 0.01},
}

GIT_VERB = re.compile(r"\bgit\s+(?:-C\s+\S+\s+|-c\s+\S+\s+)*(commit|push|merge|rebase|tag|checkout|switch|reset|"
                      r"cherry-pick|filter-branch|branch|worktree)\b")
FW_TOOL = re.compile(r"\.io\.v4rian\.how-git/(bin|scripts)/([\w.-]+)")
HOOK_MARK = re.compile(r"(hook|^X |\nX |✗|Refusing|refuses|refused|blocked|rejected|cannot reconcile|AUDIT_FAIL)", re.I)
READERS = ("cat ", "sed ", "head ", "tail ", "less ", "more ", "awk ", "grep ", "rg ", "wc ")
PROTO_PATH = re.compile(r"[\w./~$-]*(?:\.io\.v4rian\.how-git/[\w./&-]+|\.claude/(?:skills|hooks)/[\w./-]+)")


def cost_of(model_usage):
    """USD from a modelUsage dict using PRICES; unknown models fall back to the CLI's costUSD."""
    total = 0.0
    for model, u in (model_usage or {}).items():
        p = PRICES.get(u.get("canonicalModel") or model)
        if not p:
            total += float(u.get("costUSD") or 0)
            continue
        c5 = u.get("cacheCreationEphemeral5mInputTokens")
        c1 = u.get("cacheCreationEphemeral1hInputTokens")
        cw = u.get("cacheCreationInputTokens", 0)
        if c5 is None and c1 is None:
            c5, c1 = cw, 0
        total += (u.get("inputTokens", 0) * p["in"] + u.get("outputTokens", 0) * p["out"]
                  + (c5 or 0) * p["cw5m"] + (c1 or 0) * p["cw1h"]
                  + u.get("cacheReadInputTokens", 0) * p["cr"]) / 1e6
    return round(total, 6)


def _resolve(path, cwd, home):
    path = path.replace("$HOME", home).replace("~", home)
    return path if os.path.isabs(path) else os.path.normpath(os.path.join(cwd, path))


def parse_stream(stream_path, run_dir, real_home):
    repo, home = os.path.join(run_dir, "repo"), os.path.join(run_dir, "home")
    m = {"tool_calls": 0, "tools": {}, "protocol_files": {}, "skills_invoked": [], "fw_tools": {},
         "tool_errors": 0, "hook_denials": 0, "retries": 0, "isolation_leaks": [], "claude_hook_events": 0,
         "init": {}, "result": {}, "assistant_messages": 0}
    if not os.path.exists(stream_path):
        return m
    calls = {}
    failed_verbs, verb_seq = set(), []
    for line in open(stream_path, encoding="utf-8", errors="replace"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        t, st = d.get("type"), d.get("subtype")
        if t == "system" and st == "init":
            m["init"] = {"skills": d.get("skills"), "plugins": [p.get("name") for p in d.get("plugins", [])],
                         "mcp_servers": d.get("mcp_servers"), "agents": d.get("agents"),
                         "model": d.get("model"), "cwd": d.get("cwd"), "apiKeySource": d.get("apiKeySource")}
        elif t == "system" and st and st.startswith("hook"):
            m["claude_hook_events"] += 1
        elif t == "assistant":
            m["assistant_messages"] += 1
            for b in d.get("message", {}).get("content", []):
                if b.get("type") != "tool_use":
                    continue
                name, inp = b.get("name"), b.get("input") or {}
                m["tool_calls"] += 1
                m["tools"][name] = m["tools"].get(name, 0) + 1
                blob = json.dumps(inp)
                if real_home and real_home in blob:
                    m["isolation_leaks"].append(blob[:200])
                calls[b.get("id")] = (name, inp)
                if name == "Skill":
                    sk = inp.get("skill") or inp.get("name") or ""
                    m["skills_invoked"].append(sk)
                    p = os.path.join(home, ".claude", "skills", sk, "SKILL.md")
                    if os.path.exists(p):
                        m["protocol_files"][p] = os.path.getsize(p)
                elif name == "Read":
                    p = _resolve(inp.get("file_path", ""), repo, home)
                    if (".io.v4rian.how-git/" in p or "/.claude/" in p) and os.path.isfile(p):
                        m["protocol_files"][p] = os.path.getsize(p)
                elif name == "Bash":
                    cmd = inp.get("command", "")
                    for tool in FW_TOOL.findall(cmd):
                        key = "%s/%s" % tool
                        m["fw_tools"][key] = m["fw_tools"].get(key, 0) + 1
                    if any(r in cmd for r in READERS):
                        for tok in PROTO_PATH.findall(cmd):
                            p = _resolve(tok, repo, home)
                            if os.path.isfile(p):
                                m["protocol_files"][p] = os.path.getsize(p)
        elif t == "user":
            content = d.get("message", {}).get("content", [])
            if not isinstance(content, list):
                continue
            for b in content:
                if b.get("type") != "tool_result":
                    continue
                name, inp = calls.get(b.get("tool_use_id"), (None, {}))
                text = b.get("content")
                if isinstance(text, list):
                    text = " ".join(x.get("text", "") for x in text if isinstance(x, dict))
                text = text or ""
                err = bool(b.get("is_error"))
                verbs = GIT_VERB.findall(inp.get("command", "")) if name == "Bash" else []
                if err:
                    m["tool_errors"] += 1
                    if name == "Bash" and (verbs or ".io.v4rian.how-git/" in inp.get("command", "")) and HOOK_MARK.search(text):
                        m["hook_denials"] += 1
                for v in verbs:
                    if v in failed_verbs:
                        m["retries"] += 1
                        if not err:
                            failed_verbs.discard(v)
                    elif err:
                        failed_verbs.add(v)
        elif t == "result":
            # A session that schedules wakeups emits one result per segment: usage and
            # num_turns are per segment (summed here), modelUsage and cost are cumulative.
            prev = m["result"] or {}
            seg = d.get("usage") or {}
            usage = dict(prev.get("usage") or {})
            for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"):
                usage[k] = usage.get(k, 0) + seg.get(k, 0)
            m["result"] = {k: d.get(k) for k in ("subtype", "is_error", "duration_ms", "total_cost_usd",
                                                  "modelUsage", "result", "terminal_reason")}
            m["result"]["usage"] = usage
            m["result"]["num_turns"] = (prev.get("num_turns") or 0) + (d.get("num_turns") or 0)
            m["result"]["permission_denials"] = (prev.get("permission_denials") or []) + (d.get("permission_denials") or [])
            m["result"]["segments"] = prev.get("segments", 0) + 1
    return m


def parse_nested(path):
    agg = {"calls": 0, "stub_calls": 0, "input_tokens": 0, "cache_read_input_tokens": 0,
           "cache_creation_input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "seconds": 0}
    if not os.path.exists(path):
        return agg
    for line in open(path):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("stub"):
            agg["stub_calls"] += 1
            continue
        agg["calls"] += 1
        agg["seconds"] += d.get("seconds", 0)
        for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"):
            agg[k] += (d.get("usage") or {}).get(k, 0)
        agg["cost_usd"] += cost_of(d.get("modelUsage")) if d.get("modelUsage") else float(d.get("total_cost_usd") or 0)
    agg["cost_usd"] = round(agg["cost_usd"], 6)
    return agg


def summarize(stream_metrics, nested):
    r = stream_metrics.get("result") or {}
    u = r.get("usage") or {}
    out = {
        "turns": r.get("num_turns"),
        "input_tokens": u.get("input_tokens", 0),
        "cache_read_tokens": u.get("cache_read_input_tokens", 0),
        "cache_creation_tokens": u.get("cache_creation_input_tokens", 0),
        "output_tokens": u.get("output_tokens", 0),
        "cost_usd": cost_of(r.get("modelUsage")),
        "cli_cost_usd": r.get("total_cost_usd"),
        "tool_calls": stream_metrics["tool_calls"],
        "tools": stream_metrics["tools"],
        "fw_tools": stream_metrics["fw_tools"],
        "skills_invoked": stream_metrics["skills_invoked"],
        "protocol_files_read": len(stream_metrics["protocol_files"]),
        "protocol_bytes_read": sum(stream_metrics["protocol_files"].values()),
        "protocol_files": {os.path.basename(os.path.dirname(k)) + "/" + os.path.basename(k): v
                           for k, v in sorted(stream_metrics["protocol_files"].items())},
        "tool_errors": stream_metrics["tool_errors"],
        "hook_denials": stream_metrics["hook_denials"],
        "permission_denials": len(r.get("permission_denials") or []),
        "retries": stream_metrics["retries"],
        "end_state": r.get("subtype"),
        "segments": r.get("segments", 0),
        "final_reply": (r.get("result") or "")[-300:],
        "isolation": {"claude_hook_events": stream_metrics["claude_hook_events"],
                      "leaks": stream_metrics["isolation_leaks"][:5],
                      "skills_listed": (stream_metrics["init"] or {}).get("skills"),
                      "plugins": (stream_metrics["init"] or {}).get("plugins"),
                      "mcp_servers": (stream_metrics["init"] or {}).get("mcp_servers")},
        "nested": nested,
    }
    out["total_cost_usd"] = round(out["cost_usd"] + nested["cost_usd"], 6)
    out["total_tokens"] = (out["input_tokens"] + out["cache_read_tokens"] + out["cache_creation_tokens"]
                           + out["output_tokens"] + nested["input_tokens"] + nested["cache_read_input_tokens"]
                           + nested["cache_creation_input_tokens"] + nested["output_tokens"])
    return out
