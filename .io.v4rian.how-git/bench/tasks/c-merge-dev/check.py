"""Task c: --no-ff merge of the pool into dev, claimed tag, pushed, pool vaulted."""
import re
from benchcore.checks import check_generic, MERGE_DEV_RE


def check(ctx):
    infos = check_generic(ctx, protected=("main",))
    pool, pool_tip = ctx.vars["POOL"], ctx.vars["POOL_TIP"]
    dev = ctx.ref("refs/heads/dev")
    i = ctx.info(dev)
    ctx.add("dev-is-merge", "success", len(i["parents"]) == 2, i["title"])
    ctx.add("merged-pool-tip", "success", len(i["parents"]) == 2 and i["parents"][1] == pool_tip)
    ctx.add("no-ff", "compliance", len(i["parents"]) == 2 and i["parents"][0] == ctx.ref("refs/heads/dev", "pre"))
    m = MERGE_DEV_RE.match(i["title"])
    ctx.add("merge-title-spec", "compliance", bool(m) and m.group(1) == pool, i["title"])
    tag = m.group(2) if m else None
    tagref = "refs/tags/%s" % tag
    peeled = ctx.post["refs"].get(tagref + "^{}") or ctx.post["refs"].get(tagref)
    ctx.add("tag-claimed", "success", tag is not None and peeled == dev, tag)
    opeeled = ctx.post["origin_refs"].get(tagref + "^{}") or ctx.post["origin_refs"].get(tagref)
    ctx.add("tag-pushed", "compliance", tag is not None and opeeled == dev)
    ctx.add("dev-pushed", "success", ctx.oref("refs/heads/dev") == dev)
    vault = [r for r in ctx.post["origin_refs"] if r.startswith("refs/heads/vault/") and r.endswith(pool.split("/")[-1])]
    ctx.add("pool-vaulted", "compliance", bool(vault), vault)
    body = [l for l in i["body"].splitlines() if l.strip()]
    items = [l for l in body if re.match(r"^\s*- ", l)]
    # git-merge-audit / loader: nested list, period on every line (a "Changes:"-style header fails).
    no_period = [l.strip() for l in body if not l.rstrip().endswith(".")]
    ctx.add("merge-body-nested-list", "compliance",
            bool(items) and any(l.startswith("  ") for l in items) and not no_period,
            "%d list lines; no period: %s" % (len(items), no_period[:3]))
    return infos
