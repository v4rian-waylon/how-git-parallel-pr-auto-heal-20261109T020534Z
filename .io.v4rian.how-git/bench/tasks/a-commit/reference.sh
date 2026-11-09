#!/usr/bin/env bash
# Gold solution (used by --dry to prove the checker passes a correct run).
set -euo pipefail
export GIT_AUTHOR_NAME="v4rian-waylon (Opus)" GIT_COMMITTER_NAME="v4rian-waylon (Opus)"
export GIT_AUTHOR_EMAIL=v4rian-waylon@users.noreply.github.com GIT_COMMITTER_EMAIL=v4rian-waylon@users.noreply.github.com
bash tests/sum_test.sh >/dev/null
git add src/sum.sh tests/sum_test.sh
git commit -q -F - <<'M'
[NEW] Add the sum helper with its test

Adds a shell helper that prints the sum of its two integer arguments and a test script that checks that 2 and 3 sum to 5.
M
P=$(git rev-parse --abbrev-ref HEAD)
git push -q origin "$P:refs/heads/$P"
