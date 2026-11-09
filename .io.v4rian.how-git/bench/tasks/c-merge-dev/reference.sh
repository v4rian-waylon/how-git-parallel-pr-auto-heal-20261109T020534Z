#!/usr/bin/env bash
set -euo pipefail
export GIT_AUTHOR_NAME="v4rian-waylon (Opus)" GIT_COMMITTER_NAME="v4rian-waylon (Opus)"
export GIT_AUTHOR_EMAIL=v4rian-waylon@users.noreply.github.com GIT_COMMITTER_EMAIL=v4rian-waylon@users.noreply.github.com
P=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["POOL"])' "$BENCH_RUN/vars.json")
git checkout -q dev 2>/dev/null
. "$BENCH_LIB/sandbox.sh"
sb_sum_merge_msg "$P" "$BENCH_RUN/merge.msg"
git merge -q --no-ff "$P" -F "$BENCH_RUN/merge.msg" >/dev/null 2>&1
