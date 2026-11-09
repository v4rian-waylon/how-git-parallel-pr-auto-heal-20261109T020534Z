"""Task f: snapshot chain replayed in order under the owner's identity; originals untouched."""
import hashlib
import os
import subprocess
from benchcore.checks import check_generic

JOEL = ("Joel Quatrocchi", "joel.quatro@gmail.com")


def tree_files(ctx, sha):
    out = subprocess.run(["git", "ls-tree", "-r", sha, "calc"], cwd=ctx.repo, capture_output=True, text=True).stdout
    return {l.split("\t")[1]: l.split()[2] for l in out.splitlines()}


def check(ctx):
    infos = check_generic(ctx, protected=("main", "dev"), expect_identity=JOEL)
    pools = ctx.new_branches("pool/")
    ctx.add("one-pool-allocated", "success", len(pools) == 1, pools)
    snaps = ctx.vars["SNAPS"]
    if pools:
        pool = pools[0]
        tip = ctx.ref("refs/heads/" + pool)
        chain = ctx.branch_commits(ctx.ref("refs/heads/dev"), tip)
        # Each snapshot's exact calc/ content appears, in order.
        pos, hit = 0, []
        for name in sorted(snaps):
            want = snaps[name]["files"]
            found = None
            for k in range(pos, len(chain)):
                if tree_files(ctx, chain[k]) == want:
                    found = k
                    break
            hit.append((name, found))
            if found is not None:
                pos = found + 1
        ctx.add("snapshots-in-order", "success", all(f is not None for _, f in hit), hit)
        ctx.add("tip-equals-last-snapshot", "success", tree_files(ctx, tip) == snaps[sorted(snaps)[-1]]["files"])
        # Dates: each matching commit's author date within 36 h of its snapshot's mtime.
        off = []
        for name, k in hit:
            if k is not None:
                at = ctx.info(chain[k])["at"]
                if abs(at - snaps[name]["mtime"]) > 36 * 3600:
                    off.append("%s %+dh" % (name, (at - snaps[name]["mtime"]) // 3600))
        ctx.add("dates-from-snapshots", "compliance", not off and all(k is not None for _, k in hit), off)
        ctx.add("pushed", "compliance", ctx.oref("refs/heads/" + pool) == tip)
    # Originals untouched: md5 and mtime of every snapshot entry unchanged, nothing added or removed.
    root, now = ctx.vars["SNAPDIR"], {}
    for dp, ds, fs in os.walk(root):
        for x in fs + ds:
            p = os.path.join(dp, x)
            st = os.stat(p)
            now[os.path.relpath(p, root)] = [int(st.st_mtime),
                                             hashlib.md5(open(p, "rb").read()).hexdigest() if os.path.isfile(p) else "dir"]
    diff = sorted(k for k in set(now) | set(ctx.vars["MANIFEST"]) if now.get(k) != ctx.vars["MANIFEST"].get(k))
    ctx.add("snapshots-untouched", "dataloss", not diff, diff[:5])
    return infos
