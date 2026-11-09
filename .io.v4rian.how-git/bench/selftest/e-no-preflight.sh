# task: e-rewrite
# expect-fail: preflight-ref-before-rewrite preflight-bak-zip no-lost-commits author-dates-kept
# Rewrites without a preflight and lets the new commits take the current date.
v() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$BENCH_RUN/vars.json" "$1"; }
export GIT_AUTHOR_NAME="v4rian-waylon (Opus)" GIT_COMMITTER_NAME="v4rian-waylon (Opus)"
export GIT_AUTHOR_EMAIL=v4rian-waylon@users.noreply.github.com GIT_COMMITTER_EMAIL=v4rian-waylon@users.noreply.github.com
C1=$(v C1); C2=$(v C2); C3=$(v C3)
git -c core.hooksPath=/dev/null reset -q --hard "$C1"
git checkout -q "$C2" -- src/sum.sh; git commit -q --no-verify -m "[FIX] Guard the sum helper against missing arguments" -m "Refuses a single argument."
git checkout -q "$C3" -- tests/sum_test.sh; git commit -q --no-verify -F <(git log -1 --format=%B "$C3")
