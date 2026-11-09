#!/usr/bin/env bash
set -euo pipefail
export GIT_AUTHOR_NAME="v4rian-waylon (Opus)" GIT_COMMITTER_NAME="v4rian-waylon (Opus)"
export GIT_AUTHOR_EMAIL=v4rian-waylon@users.noreply.github.com GIT_COMMITTER_EMAIL=v4rian-waylon@users.noreply.github.com
v() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$BENCH_RUN/vars.json" "$1"; }
P=$(v POOL); C1=$(v C1); C2=$(v C2); C3=$(v C3)
bash "$HOME/.claude/hooks/git-preflight.sh" . "rewrite $P message" >/dev/null
# Replay C2 with the fixed message and C3 verbatim, both keeping their dates.
replay() {  # <sha> <message-file>
  local c=$1 m=$2
  GIT_AUTHOR_NAME="$(git log -1 --format=%an $c)" GIT_AUTHOR_EMAIL="$(git log -1 --format=%ae $c)" \
  GIT_AUTHOR_DATE="$(git log -1 --format=%ad --date=raw $c)" \
  GIT_COMMITTER_NAME="$(git log -1 --format=%cn $c)" GIT_COMMITTER_EMAIL="$(git log -1 --format=%ce $c)" \
  GIT_COMMITTER_DATE="$(git log -1 --format=%cd --date=raw $c)" \
    git commit-tree "$c^{tree}" -p "$(git rev-parse HEAD)" -F "$m"
}
printf '[FIX] Guard the sum helper against missing arguments\n\nMakes the sum helper refuse anything but two arguments with a usage line and exit code 2.\n' > "$BENCH_RUN/m2"
git log -1 --format=%B "$C3" > "$BENCH_RUN/m3"
git reset -q --hard "$C1"
N2=$(replay "$C2" "$BENCH_RUN/m2"); git reset -q --hard "$N2"
N3=$(replay "$C3" "$BENCH_RUN/m3"); git reset -q --hard "$N3"
git push -q origin "$P:refs/heads/$P"
