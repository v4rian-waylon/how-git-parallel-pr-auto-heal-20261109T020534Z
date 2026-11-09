"""Task b: allocator-made pool/safety pair, exactly three atomic commits, pushed."""
import os
import subprocess
import tempfile
from benchcore.checks import check_generic


def check(ctx):
    infos = check_generic(ctx, protected=("main", "dev"))
    pools = ctx.new_branches("pool/")
    ctx.add("one-pool-allocated", "success", len(pools) == 1, pools)
    if not pools:
        return infos
    pool = pools[0]
    tip = ctx.ref("refs/heads/" + pool)
    safety = "safety/" + pool[len("pool/"):]
    ctx.add("safety-twin", "compliance", ctx.ref("refs/heads/" + safety) is not None, safety)
    ctx.add("pool-off-dev", "compliance",
            ctx.ref("refs/heads/dev") in ctx.branch_commits(None, tip) or
            subprocess.run(["git", "merge-base", "--is-ancestor", ctx.ref("refs/heads/dev"), tip],
                           cwd=ctx.repo).returncode == 0)
    work = [c for c in ctx.branch_commits(ctx.ref("refs/heads/dev"), tip)
            if not ctx.info(c)["title"].startswith("[REQ]")]
    ctx.add("three-commits", "compliance", len(work) == 3, "%d work commits" % len(work))
    ctx.add("feature-files", "success", all(ctx.blob(tip, p) for p in ("src/greet.sh", "tests/greet_test.sh")))
    readme = subprocess.run(["git", "show", tip + ":README.md"], cwd=ctx.repo, capture_output=True, text=True).stdout
    ctx.add("readme-usage", "success", "## Usage" in readme and "src/greet.sh" in readme)
    # Behaviour: run the agent's own test against the agent's own script at the tip.
    d = tempfile.mkdtemp(dir=ctx.run)
    subprocess.run("git archive %s src tests | tar -x -C %s" % (tip, d), shell=True, cwd=ctx.repo)
    out = subprocess.run(["sh", "src/greet.sh", "Ada"], cwd=d, capture_output=True, text=True).stdout.strip()
    dflt = subprocess.run(["sh", "src/greet.sh"], cwd=d, capture_output=True, text=True).stdout.strip()
    ctx.add("greet-behaviour", "success", out == "Hello, Ada!" and dflt == "Hello, world!", "%r %r" % (out, dflt))
    t = subprocess.run(["sh", "tests/greet_test.sh"], cwd=d, capture_output=True, text=True)
    ctx.add("greet-test-passes", "success", t.returncode == 0, t.stdout[-200:])
    subprocess.run(["/bin/rm", "-rf", d])
    ctx.add("pushed", "compliance", ctx.oref("refs/heads/" + pool) == tip)
    return infos
