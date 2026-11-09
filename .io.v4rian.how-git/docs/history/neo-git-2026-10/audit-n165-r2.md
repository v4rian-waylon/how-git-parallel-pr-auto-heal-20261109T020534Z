# neo-git re-audit: `local/n165-fixes` round 2 (2026-10-29)

Scope: the eleven commits `d733554..dff90df` that answer `audit-n165.md`, plus the reword of the eighteen earlier commits. Read-only inspection of `<workspace>/neo-git`; execution in the detached worktree `$TMPDIR/aud-n165r2` (removed afterwards) and per-commit worktrees for the discrimination runs. Repro scripts in the session scratchpad: `lib.sh`, `e1-reissue.sh`, `e1b.sh`, `e2*.sh`, `e3-race.sh`, `e3b.sh`, `e4-roots.sh`, `e5-prepush.sh`, `e6-remote.sh`, `e7-discriminate.sh`, `e8-perf.sh`.

Paths relative to `.io.v4rian.how-git/`; line numbers refer to the file at dff90df.

## Suites (bash 3.2.57, git 2.50.1, macOS 25.5)

| suite | result |
|---|---|
| `test-lifecycle.sh` (full, clean run) | 422 passed, 0 failed |
| `test-hooks.sh` | 60 passed, 0 failed |

A first full run showed 2 failures (`claim-dev-merge dual-vault e2e (n92)`, `version math across release cycles`); both were caused by my own `pkill -f upload-pack` fired during that run, both pass in isolation (3/3 each) and in the clean rerun. Not a branch defect.

## Reword check (tree identity)

VERIFIED. `preflight-bak-2026-10-29/02` (21f10d1) tip tree `54f3e52` equals `d733554^{tree}`; all eighteen reworded commits (`a8603ac..d733554`) have the same tree, one for one, as their originals (`4da96c5..f8afffa`), merge base 0753e12. Only messages and author names changed. The four September commits (eb3e4f9, 02ca0df, 30ec63d, 0753e12) were left as they are: they sit on `origin/pool/v2026.0/n165.fix.off-grid-allocator-ignores-clone-refs`, so rewording them would rewrite pushed history. Correct call; F7 is closed as far as it may be.

## F1 to F9

| item | status | evidence |
|---|---|---|
| F1 dev tracks `.` | closed | `allocate-pool-branch.sh:285-306`; `e6-remote.sh`, eleven configurations: bogus name → origin with notice; `.` with origin → origin with notice; unset or `.` with one non origin remote → that remote with notice; two remotes and no origin → "counting local refs and history only" notice; origin among several, or an explicit tracked remote → silent; no remotes → silent; connected mode prints no notice; a remote without fetch refspec is still refused as single branch |
| F2 unbounded https stall | closed | `:376-405` perl watchdog. `e2c.sh`: never answering remote (`ext::sleep 501`) returns in 4 s with `fetch stopped after 3s`, no `sleep` or `remote-ext` left; a stub fetch that ignores TERM and forks a grandchild dies at the KILL after the 2 s grace (5 s total, no leftover); INT to the perl process ends the fetch group in 1 s and the allocation completes offline; mid transfer kill of a real 2.33 MiB pack (`e2e-partial.sh`) leaves one `objects/pack/tmp_pack_*`, no `.lock`, no refs, FETCH_HEAD 0 bytes, `fsck` clean, the next allocation still runs offline with the next number and `git gc` removes the tmp pack; without perl on PATH the fetch runs unbounded and says so; `ALLOC_FETCH_TIMEOUT=abc` and `=0` exit 2 |
| F3 `[PERF]` tag | closed | a7c7498 is `[REFACTOR]` |
| F4 "never pushed" | closed | header `:50-52`, RUNBOOK:79, README:153-156 now say "outside refs/heads, a normal push or fetch never carries them"; `git grep 'never pushed'` hits only unrelated CHANGELOG and auto-rebase prose |
| F5 fresh clone notice | closed | `view_age` `:354-370`; test asserts `counting refs as of the clone (<time>)` |
| F6 two refusals | closed | `:317-339`, both checks before one exit, combined repair line; test asserts `set-branches` on a `--depth 1` clone |
| F7 commit lens | closed as far as allowed | all 29 rewritable commits carry `v4rian-waylon (Opus)`; every FIX and TEST body has `Receipts:`; hyphens left in bodies are identifiers (`off-grid`, `how-git`, `pre-push`, `test-hooks`, one quoted test name) |
| F8 duplicated paragraph | closed | README and Git_Strategy reduced to one pointer sentence each; header and RUNBOOK are the two sources; CHANGELOG headline is "never reissue a number it can see" |
| F9 reservations pin dev tips | closed | `:779-780` reservation target is dev's root; `:803-827` bounded retention |

## Special attention items

**Watchdog process group.** VERIFIED (`e2b.sh` tree during the stall): the perl child calls `setpgrp(0,0)` then execs `git fetch`, so `git fetch`, `git remote-ext` and the transport command all share the child's pgid while perl stays in the shell's group. TERM to `-pgid`, 2 s grace polled at 100 ms, then KILL to the group, then `waitpid`: no zombie (the child is reaped), no orphan (grandchildren are in the group). A terminal Ctrl-C reaches perl, not the fetch group (it is not the foreground group), and perl's INT handler forwards TERM to the group, so the fetch cannot survive the operator's interrupt. Linux: `setpgrp`, `kill 0, -pgid`, `select` and `waitpid` are POSIX; the test's `date +%s%N` is handled for BSD date; `ps -A -o command=` exists in procps. Linux was not executed here (bash 5 and Linux are absent on this Mac).

**Remote fallback order.** branch.dev.remote if configured → origin → the only remote → none. Notices as in the F1 row. One wording nit: with `.` and a single non origin remote the notice reads "dev tracks '.', not a remote; counting remote 'up'" and does not say origin is absent; harmless.

**Reservation retention and reissue.** The counter's sources are a superset of `SAFE_MAX`'s (remote tracking pool/safety/vault refs of the tracked remote, `[MERGE]` subjects in `--remotes=$TRACKED_REMOTE`, local `refs/heads/vault/**`), so with a stable snapshot `N = 1 + max ≥ SAFE_MAX + 1` and the reservation just created is never pruned by its own run; only a later allocation with a higher `N'` prunes it, and that one is kept in turn. The clone's maximum therefore never decreases. VERIFIED (`e1b.sh`): n1 and n2 pruned when origin shows pool/n3; origin then deletes pool/n3 and the clone runs `fetch --prune`; next allocation is n5, exactly as on d733554 (pre prune). The pruned refs were local only, so other clones lose nothing either. The one hole is G1 below (snapshot not stable between the count and the prune).

**The "unreachable" stall race.** Window measured (`e3-race.sh`): a full three ref `update-ref --stdin` transaction takes 17 to 20 ms wall including process start, so the span between locking the reservation and renaming it on commit is at most about 2 ms; the loser's `rev-parse` runs about 16 ms after its own failure. But git itself retries a locked ref for `core.filesRefLockTimeout` (default 100 ms, confirmed in `git help config`), so the loser fails with `reference already exists` after the winner commits, not on the lock file: VERIFIED by holding the reservation lock open with `prepare` for 50 ms and for 150 ms, both times the loser reported `reference already exists` and saw the ref. The loser can hit the lock file only when the winner holds it longer than the retry window (descheduled or stopped for more than 100 ms between prepare and commit, or killed in between); then `rev-parse` finds no ref and the allocator exits 1 with `atomic local ref creation failed` plus git's message naming the `.lock` path. Never a duplicate. A killed winner leaves a stale `refs/how-git/allocated/nN.lock`; every later allocation of that number exits 1 until the operator removes the file (`e3b.sh`, the message names the path). Pre-existing behaviour, not introduced here.

**Pre-push refusal.** VERIFIED (`e5-prepush.sh`), hook at `githooks/pre-push:24-43`: explicit `refs/how-git/allocated/n1`, `refs/how-git/...:refs/heads/leak`, `dev:refs/how-git/...`, `--mirror` from dev and from a pool branch all exit 1 naming the ref and the remote receives nothing; `git push origin :refs/how-git/allocated/n7` and `--delete` remove a planted ref (rc 0); `--all`, a normal pool branch push and a tag named `how-git/x` pass; empty stdin passes. Nothing else in the hook reads stdin, so draining it breaks nothing; `test-hooks.sh` 60/60.

**Reservations at dev's root.** VERIFIED (`e4-roots.sh`): dev with two roots (unrelated history merged) → `rev-list --max-parents=0 | tail -1` returns the same root on three runs (oldest by commit date, deterministic for a fixed graph); orphan dev → the reservation points at dev itself; after a root changing rewrite of dev the old root stays alive through the reservations (3 objects), so "which dev keeps alive anyway" (`:777`) holds only until such a rewrite; immaterial.

**Discrimination.** VERIFIED (`e7-discriminate.sh`): each new test fails at its `[TEST]` commit and passes at its `[FIX]` commit: `falls back when dev tracks` (66fa85e 0/1 → 3f6a6c4 1/0), `fetch is bounded` (62fe818 → 611a562), `refuses shallow` and `fetches the tracked remote first` (0104479 → 83ffaf4), `reservations are bounded` (fd85c42 → 3d783cc), `pre-push refuses` (4a3b50d → 3e58b3c). The eight racer test still passes at the tip.

## Findings

| severity | count |
|---|---|
| critical | 0 |
| high | 0 |
| medium | 0 |
| low | 4 |

### G1 · low · the reservation just created can be pruned when a concurrent fetch lands between the count and the prune
- **file:line** `scripts/allocate-pool-branch.sh:819-820`
- **evidence** VERIFIED (`e1b.sh`, stub git that adds `[MERGE] pool/v2026.0/n40...` to the `git log --remotes=origin --format=%s` call only, which models a lane's fetch landing a new remote ref after this run's count): allocation n1 then `pruned 1 reservation(s) below n40`, reservations empty; with the local heads deleted and the remote record later gone the next allocation is n1 again. Needs three coincidences (fetch in that window, deletion of an unlanded pool ref on a remote without the `pool-deletions` ruleset, local abandonment of the pair), so low.
- **fix** never prune the number this run allocated: in the awk, `n + 0 < safe && n + 0 != own` with `-v own="$N"`; or compute `SAFE_MAX` before the transaction from the same scan.
- **test** extend `test_allocator_off_grid_reservations_are_bounded` with a `git` shim on PATH that appends a higher landing to the `--remotes` log call and assert the fresh reservation survives.

### G2 · low · the retention scan walks the remote history a second time
- **file:line** `scripts/allocate-pool-branch.sh:809-816`
- **evidence** VERIFIED (`e8-perf.sh`, 20003 commits, 2857 landings): tip 574 to 657 ms per allocation, d733554 367 to 404 ms (first run 864 ms, cold cache). About +0.2 s per allocation, from `git log --remotes=$TRACKED_REMOTE` repeating the walk `history_subjects` already did.
- **fix** have `history_subjects` emit the remote subjects once into a variable and feed both scans, or derive `SAFE_MAX` from the remote subset of the numbers already extracted in `next_n`.
- **test** n/a.

### G3 · low · DOCS title over 72 characters with a joiner
- **file:line** commit dff90df, title 75 chars, "remote fallback, fetch watchdog and reservations"
- **evidence** VERIFIED (`awk length`), lens rules 2 and 8 (`skills/git-commit-audit/SKILL.md:15,30`).
- **fix** `[DOCS] Point README and Git_Strategy at the allocator help and RUNBOOK` (63) or similar, on the unpushed developer branch.
- **test** n/a.

### G4 · low · header overstates what the root reservation pins
- **file:line** `scripts/allocate-pool-branch.sh:776-778` "which dev keeps alive anyway"
- **evidence** VERIFIED (`e4-roots.sh`): after an orphan rebuild of dev the old root commit survives `gc --prune=now` through the reservations (3 objects).
- **fix** "which dev keeps alive until a root changing rewrite; a root is a few objects, never a history".
- **test** n/a.

## Not weakened

The pre-push hook adds a refusal before the branch rule and lets deletes through only for cleanup; the prune deletes only reservations, each guarded by its old value, and only below a number some record outside the reservations carries; the watchdog timeout and `--no-fetch` take the same offline path the previous round verified; the shallow and single branch refusals still exit 2 with no refs created; `--help` still prints the whole header (`ALLOC_FETCH_TIMEOUT` appears twice in the help output).

## Verdict

MERGE. G1 and G3 are one line each if taken in the same pass; G2 and G4 can wait.
