#!/usr/bin/env bash
# Fixture: bootstrapped repo on dev plus three folder snapshots outside the repo.
. "$BENCH_LIB/sandbox.sh"
sb_bootstrap
S="$BENCH_RUN/snapshots"
mkdir -p "$S/snap-01/calc" "$S/snap-02/calc" "$S/snap-03/calc"
printf '# calc\n\nTiny calculator helpers.\n' > "$S/snap-01/calc/README.md"
printf 'def add(a, b):\n    return a + b\n' > "$S/snap-01/calc/ops.py"
cp "$S/snap-01/calc/README.md" "$S/snap-02/calc/README.md"
printf 'def add(a, b):\n    return a + b\n\n\ndef sub(a, b):\n    return a - b\n' > "$S/snap-02/calc/ops.py"
printf '# calc\n\nTiny calculator helpers.\n\nRun the tests with `python3 -m unittest calc/test_ops.py`.\n' > "$S/snap-03/calc/README.md"
cp "$S/snap-02/calc/ops.py" "$S/snap-03/calc/ops.py"
printf 'import unittest\n\nfrom ops import add, sub\n\n\nclass OpsTest(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n\n    def test_sub(self):\n        self.assertEqual(sub(5, 3), 2)\n' > "$S/snap-03/calc/test_ops.py"
# Snapshot dates: 2026-02-02, 2026-02-09, 2026-02-16 at 18:30 local file time.
touch -t 202602021830 "$S"/snap-01/calc/* "$S"/snap-01/calc "$S"/snap-01
touch -t 202602091830 "$S"/snap-02/calc/* "$S"/snap-02/calc "$S"/snap-02
touch -t 202602161830 "$S"/snap-03/calc/* "$S"/snap-03/calc "$S"/snap-03
"${BENCH_PYTHON:-python3}" - "$S" "$BENCH_RUN/vars.json" <<'PY'
import hashlib, json, os, subprocess, sys
root, out = sys.argv[1], sys.argv[2]
snaps, manifest = {}, {}
for snap in sorted(os.listdir(root)):
    files = {}
    for dp, _, fs in os.walk(os.path.join(root, snap)):
        for f in fs:
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, os.path.join(root, snap))
            files[rel] = subprocess.run(["git", "hash-object", p], capture_output=True, text=True).stdout.strip()
    snaps[snap] = {"files": files, "mtime": int(os.stat(os.path.join(root, snap, "calc", "ops.py")).st_mtime)}
for dp, ds, fs in os.walk(root):
    for x in fs + ds:
        p = os.path.join(dp, x)
        st = os.stat(p)
        manifest[os.path.relpath(p, root)] = [int(st.st_mtime),
            hashlib.md5(open(p, "rb").read()).hexdigest() if os.path.isfile(p) else "dir"]
json.dump({"SNAPDIR": root, "SNAPS": snaps, "MANIFEST": manifest}, open(out, "w"), indent=1)
PY
