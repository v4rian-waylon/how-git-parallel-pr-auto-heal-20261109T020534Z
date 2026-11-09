# how-git (5028b58) vs neo-git (dev v2026.0.165): agent-runner benchmark, 2026-10-30

24 runs (6 tasks x 2 arms x Opus 5.5 / Fable 5.1, 1 rep each), subagents of one session (identical overhead in both arms; absolute tokens include that overhead, deltas are the signal). Deterministic checkers score every run.

| model | how-git tokens | neo-git tokens | delta |
|---|---:|---:|---:|
| Fable 5.1 | 835,271 | 559,636 | -33% (per task -15% to -43%) |
| Opus 5.5 | 517,346 | 450,378 | -13% (per task -2% to -22%) |

Quality: how-git had 3 compliance misses (Opus merge 12/13, Fable merge 12/13, Fable snapshots 9/11) and 1 data-loss check failure (Fable rewrite re-stamped the author); neo-git had 1 compliance miss (Opus snapshots 10/11) and 0 data-loss failures.

Deterministic load (bench loadbytes): mandated protocol bytes per task cut 85-95%, 91% across 13 task types.

Raw rows: bench-agent-all.jsonl. Prior headless baseline (how-git, 36 runs): baseline-how-git-5028b58/summary.md.
