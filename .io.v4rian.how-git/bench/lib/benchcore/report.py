"""Per-run reviewer report, matrix summary table and the A/B diff."""
import json
import os
from collections import defaultdict

NUM = [("success", "success %"), ("compliance_rate", "compliance %"), ("dataloss_ok", "no loss %"),
       ("readability", "readability"), ("turns", "turns"), ("tool_calls", "tool calls"),
       ("input_tokens", "input"), ("cache_read_tokens", "cache read"), ("cache_creation_tokens", "cache write"),
       ("output_tokens", "output"), ("protocol_bytes_read", "protocol B read"), ("hook_denials", "hook denials"),
       ("retries", "retries"), ("nested_calls", "nested AI calls"), ("total_tokens", "total tokens"),
       ("total_cost_usd", "$ total"), ("wall_s", "wall s")]
LOWER_IS_BETTER = {"turns", "tool_calls", "input_tokens", "cache_read_tokens", "cache_creation_tokens",
                   "output_tokens", "protocol_bytes_read", "hook_denials", "retries", "nested_calls",
                   "total_tokens", "total_cost_usd", "wall_s"}


def write_run_report(run, res, verdict):
    lines = ["# %s / %s / %s / rep %d" % (res["arm"], res["model"], res["task"], res["rep"]), "",
             "mode %s, success %s, compliance %s/%s, data loss %s, readability %s" % (
                 res["mode"], res["success"], res["compliance_pass"], res["compliance_total"],
                 "none" if res["dataloss_ok"] else "DETECTED", res["readability"]),
             "turns %s, tool calls %s, tokens in %s / cache read %s / cache write %s / out %s, $%s, %ss" % (
                 res.get("turns"), res.get("tool_calls"), res.get("input_tokens"), res.get("cache_read_tokens"),
                 res.get("cache_creation_tokens"), res.get("output_tokens"), res.get("total_cost_usd"), res["wall_s"]),
             "", "## Checks", ""]
    for c in verdict["checks"]:
        lines.append("- [%s] %s %s %s" % ("x" if c["ok"] else " ", c["kind"], c["id"], c["detail"]))
    lines += ["", "## Readability (deterministic)", ""]
    for r in verdict["readability_detail"]:
        lines.append("- %s %3d %s %s" % (r["sha"], r["score"], r["parts"], r["title"]))
    lines += ["", "## History for the human reviewer", "", "```", verdict["log_graph"].rstrip(), "```", "",
              "## New commit messages", "", "```", verdict["new_messages"].rstrip(), "```", "",
              "## Protocol files read", ""]
    for k, v in (res.get("protocol_files") or {}).items():
        lines.append("- %s %d B" % (k, v))
    lines += ["", "## Final reply", "", "```", str(res.get("final_reply", "")), "```", ""]
    open(os.path.join(run, "report.md"), "w").write("\n".join(lines))


def _row_values(r):
    v = dict(r)
    v["success"] = 100.0 if r.get("success") else 0.0
    v["dataloss_ok"] = 100.0 if r.get("dataloss_ok") else 0.0
    tot = r.get("compliance_total") or 0
    v["compliance_rate"] = 100.0 * r.get("compliance_pass", 0) / tot if tot else None
    v["nested_calls"] = (r.get("nested") or {}).get("calls", 0)
    return v


def aggregate(results, key=("arm", "model", "task")):
    groups = defaultdict(list)
    for r in results:
        groups[tuple(r[k] for k in key)].append(_row_values(r))
    agg = {}
    for g, rows in groups.items():
        a = {"n": len(rows)}
        for k, _ in NUM:
            vals = [x[k] for x in rows if isinstance(x.get(k), (int, float))]
            a[k] = round(sum(vals) / len(vals), 4) if vals else None
        viol = defaultdict(int)
        for x in rows:
            for v in x.get("violations") or []:
                viol[v] += 1
        a["violations"] = dict(viol)
        agg[g] = a
    return agg


def _fmt(v):
    if v is None:
        return "-"
    if isinstance(v, float):
        return ("%.4f" % v).rstrip("0").rstrip(".") if abs(v) < 10 else "%.0f" % v
    return str(v)


def summary_markdown(results):
    if not results:
        return "No results.\n"
    agg = aggregate(results)
    cols = ["arm", "model", "task", "n"] + [label for _, label in NUM] + ["violations"]
    out = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    for g in sorted(agg):
        a = agg[g]
        viol = ", ".join("%s x%d" % kv for kv in sorted(a["violations"].items())) or "-"
        out.append("| " + " | ".join(list(g) + [str(a["n"])] + [_fmt(a[k]) for k, _ in NUM] + [viol]) + " |")
    tot = defaultdict(float)
    for r in results:
        tot["cost"] += r.get("total_cost_usd") or 0
        tot["tokens"] += r.get("total_tokens") or 0
    out += ["", "Runs %d, total tokens %d, total cost $%.4f (prices: %s)." % (
        len(results), tot["tokens"], tot["cost"], results[0].get("price_source", ""))]
    return "\n".join(out) + "\n"


def load(path):
    return [json.loads(l) for l in open(path) if l.strip()]


def diff_markdown(a_rows, b_rows, a_label="A", b_label="B", key=("model", "task")):
    """Per (model, task): metric mean in A, in B, and the % delta B vs A."""
    A, B = aggregate(a_rows, key), aggregate(b_rows, key)
    out = ["Diff %s -> %s (delta = (B - A) / A; for cost-like metrics negative is better)." % (a_label, b_label), ""]
    for g in sorted(set(A) | set(B)):
        a, b = A.get(g), B.get(g)
        out += ["### " + " / ".join(g), "", "| metric | %s | %s | delta |" % (a_label, b_label), "|---|---|---|---|"]
        for k, label in NUM:
            av = a.get(k) if a else None
            bv = b.get(k) if b else None
            if av is None and bv is None:
                continue
            if isinstance(av, (int, float)) and isinstance(bv, (int, float)) and av:
                d = 100.0 * (bv - av) / abs(av)
                better = (d < 0) if k in LOWER_IS_BETTER else (d > 0)
                delta = "%+.1f%%%s" % (d, "" if abs(d) < 0.05 else (" better" if better else " worse"))
            elif av == bv:
                delta = "="
            else:
                delta = "n/a"
            out.append("| %s | %s | %s | %s |" % (label, _fmt(av), _fmt(bv), delta))
        out.append("")
    return "\n".join(out)
