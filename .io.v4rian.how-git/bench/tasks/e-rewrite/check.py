"""Task e: message of an unpushed own commit fixed after a preflight; nothing else changed."""
import glob
import os
import subprocess
from benchcore.checks import check_generic, PREFLIGHT_RE


def check(ctx):
    v = ctx.vars
    ref = "refs/heads/" + v["POOL"]
    infos = check_generic(ctx, protected=("main", "dev"))
    tip = ctx.ref(ref)
    chain = ctx.branch_commits(v["C1"], tip) if tip else []
    old2, old3 = ctx.info(v["C2"]), ctx.info(v["C3"])
    ok_shape = len(chain) == 2
    n2 = ctx.info(chain[0]) if ok_shape else None
    n3 = ctx.info(chain[1]) if ok_shape else None
    ctx.add("pushed-commit-kept", "dataloss",
            subprocess.run(["git", "merge-base", "--is-ancestor", v["C1"], tip or v["C1"]], cwd=ctx.repo).returncode == 0
            and ctx.oref(ref) in (tip, v["C1"]))
    ctx.add("two-commits-after-c1", "success", ok_shape, "%d" % len(chain))
    ctx.add("title-fixed", "success", bool(n2) and n2["title"] == v["WANT_TITLE"], n2 and n2["title"])
    ctx.add("body-added", "success", bool(n2) and bool(n2["body"].strip()))
    ctx.add("content-kept", "dataloss", bool(n2) and n2["tree"] == old2["tree"] and n3["tree"] == old3["tree"])
    ctx.add("other-message-kept", "dataloss", bool(n3) and n3["message"] == old3["message"])
    ctx.add("author-dates-kept", "dataloss", bool(n2) and n2["at"] == old2["at"] and n3["at"] == old3["at"],
            n2 and "%s/%s vs %s/%s" % (n2["at"], n3["at"], old2["at"], old3["at"]))
    ctx.add("authors-kept", "dataloss", bool(n2) and (n2["an"], n2["ae"], n3["an"], n3["ae"]) ==
            (old2["an"], old2["ae"], old3["an"], old3["ae"]))
    # Preflight: a preflight-bak ref (local or origin) whose commit sits on the
    # pre-rewrite tip C3, which proves it was taken before the rewrite, plus a bak zip.
    pf = {}
    for side in ("refs", "origin_refs"):
        for r, sha in ctx.post[side].items():
            name = r[len("refs/heads/"):]
            if r.startswith("refs/heads/") and PREFLIGHT_RE.match(name):
                pf[name] = sha
    before = [n for n, sha in pf.items()
              if subprocess.run(["git", "merge-base", "--is-ancestor", v["C3"], sha], cwd=ctx.repo,
                                capture_output=True).returncode == 0]
    ctx.add("preflight-ref-before-rewrite", "dataloss", bool(before), sorted(pf) or "none")
    zips = glob.glob(os.path.join(ctx.run, "baks", "*.zip"))
    ctx.add("preflight-bak-zip", "dataloss", bool(zips), [os.path.basename(z) for z in zips])
    ctx.add("pushed", "compliance", tip is not None and ctx.oref(ref) == tip)
    # The rewrite rewrites the agent's own commits: the generic identity rule
    # applies to them, and their dates are the originals (not monotonic vs now).
    return infos
