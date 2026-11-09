#!/usr/bin/env bash
# sandbox.sh - fixture helpers sourced by every task's setup.sh and reference.sh.
#
# The runner exports, before sourcing:
#   BENCH_RUN   the run directory (repo/, origin.git/, home/, fw/, baks/ live here)
#   BENCH_FW    the arm's framework checkout (a git checkout of neo-git at the arm ref)
#   BENCH_LIB   this directory
# Every fixture repo is off-grid: origin is the local bare repo $BENCH_RUN/origin.git,
# never GitHub. Fixture commits use a deterministic clock so two runs of one task
# start from the same history shape regardless of the arm.

set -euo pipefail

: "${BENCH_RUN:?BENCH_RUN unset}"
: "${BENCH_FW:?BENCH_FW unset}"

SB_REPO="$BENCH_RUN/repo"
SB_ORIGIN="$BENCH_RUN/origin.git"
SB_AGENT_NAME="v4rian-waylon (Opus)"
SB_AGENT_EMAIL="v4rian-waylon@users.noreply.github.com"
SB_EPOCH=1767607200   # 2026-01-05T10:00:00Z
mkdir -p "$BENCH_RUN/logs"

# Next fixture timestamp: one hour after the previous one.
sb_tick() {
  local f="$BENCH_RUN/.clock" n=0
  [ -f "$f" ] && n=$(cat "$f")
  n=$((n + 1)); echo "$n" > "$f"
  echo "@$((SB_EPOCH + n * 3600)) +0000"
}

# Run a command with the fixture identity and the next fixture date exported
# (git itself, or framework scripts that commit internally).
sb_dated() {
  local d; d=$(sb_tick)
  GIT_AUTHOR_NAME="$SB_AGENT_NAME" GIT_COMMITTER_NAME="$SB_AGENT_NAME" \
  GIT_AUTHOR_EMAIL="$SB_AGENT_EMAIL" GIT_COMMITTER_EMAIL="$SB_AGENT_EMAIL" \
  GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" "$@"
}

# sb_commit <title> <body> <path>...  stage the named paths and commit through the hooks.
sb_commit() {
  local title="$1" body="$2"; shift 2
  git add -- "$@"
  printf '%s\n\n%s\n' "$title" "$body" > "$BENCH_RUN/.msg"
  if ! sb_dated git commit -q -F "$BENCH_RUN/.msg" >>"$BENCH_RUN/logs/fixture.log" 2>&1; then
    echo "sb_commit failed: $title (see logs/fixture.log)" >&2; return 1
  fi
}

# sb_commit_raw: same, but bypasses the hooks (plants a deliberately bad message).
sb_commit_raw() {
  local title="$1" body="$2"; shift 2
  git add -- "$@"
  printf '%s\n\n%s\n' "$title" "$body" > "$BENCH_RUN/.msg"
  sb_dated git commit -q --no-verify -F "$BENCH_RUN/.msg" >/dev/null
}

# sb_bootstrap: intro commit, attach the arm framework, flip off-grid, seed dev,
# push main and dev to the bare origin. Leaves the repo on dev.
sb_bootstrap() {
  local log="$BENCH_RUN/logs/fixture.log"
  git init -q --bare "$SB_ORIGIN"
  mkdir -p "$SB_REPO"; cd "$SB_REPO"
  git init -q -b main
  printf '# demo\n\nDemo consumer repository the how-git benchmark harness drives through scripted git tasks.\n' > README.md
  printf '.DS_Store\n' > .gitignore
  git add README.md .gitignore
  printf 'demo\n\nDemo consumer repository the how-git benchmark harness drives through scripted git tasks.\n' > "$BENCH_RUN/.msg"
  sb_dated git commit -q --no-verify -F "$BENCH_RUN/.msg"
  bash "$BENCH_FW/.io.v4rian.how-git/scripts/attach.sh" . >>"$log" 2>&1
  # attach commits with the ambient date; re-date it on the fixture clock.
  sb_dated git commit -q --amend --no-edit --no-verify --reset-author
  LIFECYCLE_TEST_MODE=1 sb_dated bash .io.v4rian.how-git/bin/set-mode off-grid >>"$log" 2>&1
  git branch -f dev main
  git remote add origin "$SB_ORIGIN"
  git push -q origin main dev >>"$log" 2>&1
  git checkout -q dev >>"$log" 2>&1
}

# sb_alloc <short-name> <kind> <requirement>: allocate a pool/safety pair off-grid,
# print the pool branch name.
sb_alloc() {
  sb_dated bash .io.v4rian.how-git/bin/create-pool-branch "$1" --no-jira --kind "$2" \
    --requirement "$3" >>"$BENCH_RUN/logs/fixture.log" 2>&1
  git for-each-ref --format='%(refname:short)' refs/heads/pool/ | grep "\.$1\$" | head -1
}

# sb_push_pair <pool>: push the pool and its safety twin to origin.
sb_push_pair() {
  local p="$1" s
  s="safety/${1#pool/}"
  git push -q origin "$p:refs/heads/$p" "$s:refs/heads/$s" >>"$BENCH_RUN/logs/fixture.log" 2>&1
}

# sb_sum_merge_msg <pool> <file>: the add-sum pool's merge message in the ruled
# shape (git-merge-audit rule 5); the title carries the version the claim will
# take, from the arm's own bin/version --next-dev.
sb_sum_merge_msg() {
  local v; v=$(bash .io.v4rian.how-git/bin/version --next-dev)
  cat > "$2" <<M
[MERGE] $1 into dev: $v

Adds the sum helper and its test.

- Sum helper.
    - src/sum.sh: prints the sum of two integer arguments.
- Test.
    - tests/sum_test.sh: checks that 2 and 3 sum to 5.
M
}

# sb_merge_pool <pool> <body-file>: off-grid close-up of a pool into dev (the
# post-merge hook claims the tag, pushes dev and vaults the pool).
sb_merge_pool() {
  git checkout -q dev >>"$BENCH_RUN/logs/fixture.log" 2>&1
  sb_dated git merge -q --no-ff "$1" -F "$2" >>"$BENCH_RUN/logs/fixture.log" 2>&1
}
