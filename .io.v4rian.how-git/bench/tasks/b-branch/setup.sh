#!/usr/bin/env bash
# Fixture: bootstrapped repo on a clean dev; nothing allocated yet.
. "$BENCH_LIB/sandbox.sh"
sb_bootstrap
printf '{}\n' > "$BENCH_RUN/vars.json"
