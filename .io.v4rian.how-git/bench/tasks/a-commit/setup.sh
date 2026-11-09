#!/usr/bin/env bash
# Fixture: bootstrapped repo, allocated pool checked out, change left uncommitted.
. "$BENCH_LIB/sandbox.sh"
sb_bootstrap
POOL=$(sb_alloc add-sum feature "Add a sum helper with a test.")
sb_push_pair "$POOL"
git checkout -q "$POOL" 2>>"$BENCH_RUN/logs/fixture.log"
mkdir -p src tests
printf '#!/bin/sh\n# Prints the sum of two integers.\necho $(( $1 + $2 ))\n' > src/sum.sh
printf '#!/bin/sh\nset -e\n[ "$(sh src/sum.sh 2 3)" = 5 ] || { echo FAIL; exit 1; }\necho ok\n' > tests/sum_test.sh
printf '{"POOL": "%s", "SUM_BLOB": "%s", "TEST_BLOB": "%s"}\n' "$POOL" \
  "$(git hash-object src/sum.sh)" "$(git hash-object tests/sum_test.sh)" > "$BENCH_RUN/vars.json"
