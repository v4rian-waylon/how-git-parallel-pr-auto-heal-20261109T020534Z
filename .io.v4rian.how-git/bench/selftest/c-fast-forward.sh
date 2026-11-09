# task: c-merge-dev
# expect-fail: dev-is-merge merged-pool-tip no-ff merge-title-spec tag-claimed
# Fast-forward merge, no claim.
P=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["POOL"])' "$BENCH_RUN/vars.json")
git checkout -q dev 2>/dev/null
git -c core.hooksPath=/dev/null merge -q --ff-only "$P"
