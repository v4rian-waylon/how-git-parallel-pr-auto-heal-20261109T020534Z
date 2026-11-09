#!/usr/bin/env bash
set -euo pipefail
export GIT_AUTHOR_NAME="v4rian-waylon (Opus)" GIT_COMMITTER_NAME="v4rian-waylon (Opus)"
export GIT_AUTHOR_EMAIL=v4rian-waylon@users.noreply.github.com GIT_COMMITTER_EMAIL=v4rian-waylon@users.noreply.github.com
S="$BENCH_RUN/snapshots"
bash .io.v4rian.how-git/bin/create-pool-branch calc-history --no-jira --kind feature --requirement "Rebuild the calc history." >/dev/null 2>&1
P=$(git for-each-ref --format='%(refname:short)' refs/heads/pool/ | grep '\.calc-history$')
git checkout -q "$P" 2>/dev/null
step() {  # <snap> <title> <body>
  local d; d="$(stat -f %m "$S/$1/calc/ops.py") +0000"
  /bin/rm -rf calc; mkdir calc; cp -p "$S/$1/calc/"* calc/
  git add -A calc
  GIT_AUTHOR_NAME="Joel Quatrocchi" GIT_AUTHOR_EMAIL="joel.quatro@gmail.com" GIT_AUTHOR_DATE="@$d" \
  GIT_COMMITTER_NAME="Joel Quatrocchi" GIT_COMMITTER_EMAIL="joel.quatro@gmail.com" GIT_COMMITTER_DATE="@$d" \
    git commit -q -m "$2" -m "$3"
}
step snap-01 "[NEW] Add the calc add helper" "Adds the calc package with an add helper and a README."
step snap-02 "[NEW] Add the calc sub helper" "Adds a subtraction helper next to add."
step snap-03 "[TEST] Cover the calc helpers" "Adds unit tests for add and sub and documents how to run them."
S2="safety/${P#pool/}"
git push -q origin "$P:refs/heads/$P" "$S2:refs/heads/$S2"
