# task: f-snapshots
# expect-fail: snapshots-untouched one-pool-allocated
# Edits an original snapshot and never allocates a branch.
echo "# edited" >> "$BENCH_RUN/snapshots/snap-01/calc/README.md"
