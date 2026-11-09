"""Task a: one atomic commit holding the given change, pushed."""
from benchcore.checks import check_generic


def check(ctx):
    pool = ctx.vars["POOL"]
    ref = "refs/heads/" + pool
    infos = check_generic(ctx, protected=("main", "dev"))
    tip = ctx.ref(ref)
    commits = ctx.branch_commits(ctx.ref(ref, "pre"), tip)
    ctx.add("committed-on-pool", "success", len(commits) >= 1, "%d new commit(s)" % len(commits))
    ctx.add("content-landed", "success",
            tip and ctx.blob(tip, "src/sum.sh") == ctx.vars["SUM_BLOB"]
            and ctx.blob(tip, "tests/sum_test.sh") == ctx.vars["TEST_BLOB"])
    ctx.add("tree-clean", "success", ctx.post["status"].strip() == "", ctx.post["status"][:200])
    ctx.add("atomic-single-commit", "compliance", len(commits) == 1, "%d commits" % len(commits))
    ctx.add("pushed", "compliance", tip is not None and ctx.oref(ref) == tip)
    return infos
