"""Task d: dev promoted to main by a --no-ff release merge, pushed, tags untouched."""
from benchcore.checks import check_generic, MERGE_MAIN_RE


def check(ctx):
    infos = check_generic(ctx, protected=("dev",))
    main, dev = ctx.ref("refs/heads/main"), ctx.vars["DEV"]
    i = ctx.info(main)
    ctx.add("main-is-merge", "success", len(i["parents"]) == 2, i["title"])
    ctx.add("main-merges-dev", "success", len(i["parents"]) == 2 and i["parents"][1] == dev)
    ctx.add("no-ff", "compliance", len(i["parents"]) == 2 and i["parents"][0] == ctx.ref("refs/heads/main", "pre"))
    m = MERGE_MAIN_RE.match(i["title"])
    ctx.add("release-title-spec", "compliance", bool(m) and m.group(1) == ctx.vars["TAG"], i["title"])
    ctx.add("main-pushed", "success", ctx.oref("refs/heads/main") == main)
    new_tags = [r for r in ctx.post["refs"] if r.startswith("refs/tags/") and not r.endswith("^{}")
                and r not in ctx.pre["refs"]]
    ctx.add("no-new-tag", "compliance", not new_tags, new_tags)
    return infos
