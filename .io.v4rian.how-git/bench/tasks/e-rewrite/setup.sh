#!/usr/bin/env bash
# Fixture: fix pool with three own commits; the middle message is defective; only the first is pushed.
. "$BENCH_LIB/sandbox.sh"
sb_bootstrap
POOL=$(sb_alloc sum-guard fix "Guard the sum helper against missing arguments.")
git checkout -q "$POOL" 2>>"$BENCH_RUN/logs/fixture.log"
mkdir -p src tests
printf '#!/bin/sh\n# Prints the sum of two integers.\necho $(( $1 + $2 ))\n' > src/sum.sh
sb_commit "[NEW] Add the sum helper" "Adds a shell helper that prints the sum of its two integer arguments." src/sum.sh
C1=$(git rev-parse HEAD)
sb_push_pair "$POOL"
printf '#!/bin/sh\n# Prints the sum of two integers.\n[ $# -eq 2 ] || { echo "usage: sum.sh A B" >&2; exit 2; }\necho $(( $1 + $2 ))\n' > src/sum.sh
sb_commit_raw "[NEW] guard sum args" "" src/sum.sh
C2=$(git rev-parse HEAD)
printf '#!/bin/sh\n[ "$(sh src/sum.sh 2 3)" = 5 ] || exit 1\nsh src/sum.sh 2 2>/dev/null && exit 1\necho ok\n' > tests/sum_test.sh
sb_commit "[TEST] Cover the missing argument guard" "Adds a test that checks the sum and the refusal of a single argument." tests/sum_test.sh
C3=$(git rev-parse HEAD)
printf '{"POOL": "%s", "C1": "%s", "C2": "%s", "C3": "%s", "BAD_TITLE": "[NEW] guard sum args", "WANT_TITLE": "[FIX] Guard the sum helper against missing arguments"}\n' \
  "$POOL" "$C1" "$C2" "$C3" > "$BENCH_RUN/vars.json"
