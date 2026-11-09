#!/usr/bin/env bash
# Fixture: a finished pool with two commits, pushed with its safety twin.
. "$BENCH_LIB/sandbox.sh"
sb_bootstrap
POOL=$(sb_alloc add-sum feature "Add a sum helper with a test.")
git checkout -q "$POOL" 2>>"$BENCH_RUN/logs/fixture.log"
mkdir -p src tests
printf '#!/bin/sh\n# Prints the sum of two integers.\necho $(( $1 + $2 ))\n' > src/sum.sh
sb_commit "[NEW] Add the sum helper" "Adds a shell helper that prints the sum of its two integer arguments." src/sum.sh
printf '#!/bin/sh\nset -e\n[ "$(sh src/sum.sh 2 3)" = 5 ] || { echo FAIL; exit 1; }\necho ok\n' > tests/sum_test.sh
sb_commit "[TEST] Cover the sum helper" "Adds a test script that checks that 2 and 3 sum to 5." tests/sum_test.sh
sb_push_pair "$POOL"
printf '{"POOL": "%s", "POOL_TIP": "%s"}\n' "$POOL" "$(git rev-parse HEAD)" > "$BENCH_RUN/vars.json"
