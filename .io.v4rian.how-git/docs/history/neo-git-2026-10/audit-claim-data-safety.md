# Audit: local/claim-data-safety (pool 4 fix.claim-data-safety)

Auditor: Fable 5.1, 2026-10-29. Read-only on neo-git; executed in detached $TMPDIR worktrees (removed). Branch: 17 commits on dev 5028b58 (`dev...local/claim-data-safety`, 11 files, +710/-93). Scenario scripts: `<scratchpad>/scen-*.sh`, `flaky-repro.sh`, `disc.sh`.

## Suites (branch worktree, bash 3.2.57 is `bash` on this Mac)
- test-hooks.sh: 60 passed, 0 failed.
- test-lifecycle.sh: 417 passed, 1 failed (`version math across release cycles`, the pre-existing flake; see F0). The [DOCS] body's "418 of 418" is run-dependent.

## Discrimination (brief item 4)
- Branch test file run against the dev tree: all 12 new `cds` tests FAIL on dev except `R01 CI rerun adopts origin dev` (a contract-preservation test, expected to pass on dev).
- Single-fix revert in an isolated worktree (`disc.sh`): R19 a1d79aa FAIL, R21 938595b FAIL, R20 0e18733 FAIL, R06 f88129c FAIL, R05 f237f64 FAIL when reverted alone. R01 7e6c4bb, R03 920685d, dirty a08c550 could not be reverted in isolation (later hunks overlap); verified only through the dev-tree run.

## Findings

### F0 [medium, pre-existing on dev] Flaky `version math across release cycles` (test-lifecycle.sh:4209, assertion :4255)
- VERIFIED reproduction: `--filter "version math across release cycles"` on dev 5028b58, 8 runs: 3 FAIL, always `expected 'v2026.1.3', got 'v2026.0.5' (second release reuses the sealed dev tag)`.
- Root cause: `bin/version:184` post-release fallback `git describe --tags --match "v$YEAR.*" --abbrev=0 "$DEV_REF"`. `git describe` scores candidate tags with a committer-date-ordered walk; when the release merge R1 (dev->main, cycle 0) and the next cycle's first pool merge M6 share a committer second, R1 is popped before M6 (same date, insertion order), M6 never propagates the v.1.3 flag down through R1, and every cycle-0 commit is charged to v2026.1.3's depth. Receipt from a failing replica run (`flaky-repro.sh`, `git describe --debug`): `lightweight 11 v2026.0.5` / `lightweight 12 v2026.1.3` -> picks v2026.0.5; `bash -x bin/version`: `SERIES=2 DEV_IN_CYCLE=0 SEAL_DEV=-1 FALLBACK=v2026.0.5`. Graph showed R1 `ct=...271` and M6 `ct=...271` (same second). The fast test body lands the release and the next merge inside one second roughly half the time, hence 3/5.
- Production exposure: the same fallback feeds `claim-main-release.sh` (release reuses `--seal`); a release and the next pool merge within one second is unrealistic, so the defect is test-visible only, but the selection rule is wrong in kind (depth heuristic instead of version order).
- Deterministic fix (verified): replace the describe call with version-ordered selection of reachable tags:
  ```sh
  FALLBACK=$(git tag --merged "$DEV_REF" -l "v${NOW_YEAR}.*" 2>/dev/null \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k2,2n -k3,3n | tail -1 || true)
  ```
  Receipts: replica 12/12 green; `--filter version` 6 runs x 15 PASS; whole flaky test 0/12 failures. `sort -t. -kN,Nn` is BSD+GNU safe (no `-V`).
- Test: keep the existing test; optionally pin the race by giving R1 and M6 the same `GIT_COMMITTER_DATE` in the fixture so the old code fails every run.

### F1 [high] R19 self-healing breaks on one failed tag push; hole and local-only tag become permanent (claim-dev-merge.sh:241-270, :467, :473)
- `seal_unclaimed_merges run` (:473) runs after the HEAD tag push (:467) under `set -e`; a rejected tag push exits before any backfill. The walk (:246) stops at the first tagged first-parent merge, so once the next claim tags its own HEAD the older hole is behind a tagged merge and never visited again. The resume path re-pushes only the tag of the current HEAD.
- VERIFIED (`scen-r03-midway.sh` part c, origin pre-receive rejecting `refs/tags/*` once): claim3 rc=1, local tags `v2026.0.1 v2026.0.2 v2026.0.4`, hole `4c3de53` untagged (v2026.0.3 never minted). Hook removed, claim4 rc=0: origin tags `v2026.0.1 v2026.0.2 v2026.0.5`; v2026.0.3 never created, v2026.0.4 never pushed. README:332-333 and RUNBOOK:151 promise "no holes".
- Also :255-257 prints "already seals another commit" for a tag that exists and points at `cand` (wrong diagnosis), and :265-268 leaves a failed backfill push to a by-hand command with no retry.
- Fix: (1) call `seal_unclaimed_merges run` right after dev is published and before the HEAD tag push, so a tag-push failure cannot skip it; (2) do not stop at the first tagged merge: walk every first-parent merge of the current year and treat "tag exists and points at cand" as sealed; (3) after sealing, push every local `v*` tag on the dev first-parent line that `git ls-remote --tags origin` lacks (covers the resume case and the by-hand message). Test: part c of the scenario as a lifecycle test (reject tags once, rerun, assert origin holds a contiguous chain).

### F2 [medium] `CI=true` in the environment turns the divergence refusal into a reset of local dev (claim-dev-merge.sh:110, :133-135)
- Detection is the bare `CI` variable. In connected mode local claims are only possible with `CI=true` (or `LIFECYCLE_TEST_MODE=1`), so an operator who exports `CI=true` to get past the gate, or inherits it from `act`/a CI-like shell, hits the adopt path on a real divergence.
- VERIFIED (`scen-ci-spoof.sh`): connected mode, local dev with an unpushed pool merge, origin dev with an unrelated commit. Run without `CI`: rc=2, refusal. Run with `CI=true`: rc=0, `adopted origin/dev ... over the diverged CI checkout`, local merge no longer on dev (reflog only). Off-grid + `CI=true` is a no-op (gate at :78).
- Fix: adopt origin only when the divergence is the rerun shape the comment describes: every local-only commit has the same tree and parents as origin's tip (amended twin), else refuse even in CI; optionally require `GITHUB_ACTIONS=true` as well. Test: connected mode, `CI=true`, unrelated divergence -> refusal, local dev untouched; the existing CI-rerun test keeps passing.

### F3 [medium] R19 seals a prior-year merge with a bogus `vYEAR.0.0` tag, permanently (claim-dev-merge.sh:253, bin/version:136-139 with `NOW_YEAR`)
- `--seal --at REV` samples the merge counts "since $NOW_YEAR-01-01" from REV; a REV committed last year counts 0, SERIES 0 -> SEAL_DEV 0 -> `v2026.0.0`, a slot that cannot exist (cycle 0 is 1-based). The tag is then minted and pushed and "never moves".
- VERIFIED (`scen-r19-edges.sh` part 2): unclaimed merge dated 2025-12-31, first claim in 2026: `sealed unclaimed merge ec81b1b as v2026.0.0`; tags `v2025.0.1 v2026.0.0 v2026.0.1`.
- Fix: in `--at` mode derive the year from REV's committer date (`git log -1 --format=%cd --date=format:%Y REV`) and count from that year's January 1; or skip candidates from a prior year with an explicit message. Test: the fixture above, expecting `v2025.0.2` (or an explicit skip), never `v2026.0.0`.

### F4 [medium] R19 never seals a hole that precedes a release, silently (claim-dev-merge.sh:246-252)
- After `dev` fast-forwards onto main's release merge, dev's first-parent line runs R1 -> previous main; the walk from `HEAD^1` meets no tagged merge (`found=false`) and returns without a word. Even when it did reach the hole, `--seal --at` samples SERIES from today's main, so a cycle-0 merge resolves to the fallback and is reported as "already seals another commit".
- VERIFIED (`scen-r19-edges.sh` part 1): v2026.0.1 claimed, non-pool merge (spent v2026.0.2 per `bin/version --seal` at the time), release, next claim prints `dev tag to claim: v2026.1.0` and nothing about the hole; tags `v2026.0.1 v2026.1.0`, hole untagged. The release itself would have reused v2026.0.2, a tag that does not exist (pre-existing claim-main-release exposure, out of scope).
- Fix: bound the walk by year, not by the first tagged merge (see F1 fix 2), and make `--at` sample main as of REV (SERIES_at = main merges this year that are ancestors of REV, DEV_at = dev merges reachable from REV not reachable from that main point). At minimum print one line when untagged candidates were skipped. Test: part 1 of the scenario, expecting the hole sealed as v2026.0.2.

### F5 [medium] R20 fallback is installed by four scripts only; heal.sh, doctor, set-mode, finalize-pool-merge, ship and a fresh clone get none (_lib.sh:68, :1768; RUNBOOK:150)
- `ensure_merge_hook_fallback` runs inside `ensure_hooks_path`, called only by claim-dev-merge.sh:55, claim-main-release.sh:51, open-pr.sh:58, sync-framework.sh:141. heal.sh sets `core.hooksPath` itself (heal.sh:55-57) and never installs the shim. The shim lives in `.git/hooks`, so a fresh clone has none until one of the four runs.
- VERIFIED: consumer built with heal.sh + set-mode: `shim present? NO`. Fresh clone, hooks never activated, `git merge --no-ff` into dev: no warning, `tags: ''`. RUNBOOK:150 "any framework script run has installed a fallback" is false; HP pitfall 3 (app-beta, hooks off) is the fresh-clone shape.
- Fix: call `ensure_merge_hook_fallback` from heal.sh and from every bin entry that sources `_lib.sh` (finalize-pool-merge, ship, set-mode, doctor), and have `bin/doctor` report a missing shim. Test: heal.sh, unset `core.hooksPath`, merge -> warning + claim (mirror of `test_cds_R20` with heal.sh instead of open-pr --doctor); fresh clone case documented as still unclaimed or covered by attach/clone instructions.

### F6 [low] Untracked file that the fast-forward would overwrite: guard says "never reads or writes them", then git dies with rc=128 (_lib.sh:1757, claim-dev-merge.sh:129)
- VERIFIED (`scen-untracked-clobber.sh`): local dev behind origin, origin adds `notes.txt`, local untracked `notes.txt`: `→ claim-dev-merge: 1 untracked file(s) left in place (the claim never reads or writes them)` then `error: Untracked working tree file 'notes.txt' would be overwritten by merge. fatal: Could not reset index file`, rc=128. No data loss (file intact, dev unmoved), but an unhandled exit and a contradicting message.
- Fix: after the fetch, intersect `git ls-files --others --exclude-standard` with `git diff --name-only HEAD FETCH_HEAD`; refuse with the path and `mv <file> <file>.local` / rerun lines, or catch the `reset --keep` failure and print them. Test: the scenario, expecting exit 2 with the path named.

### F7 [low] `--help` text contradicts the new tree contract
- claim-dev-merge.sh:26 "Verify working tree is clean (no uncommitted changes)", claim-main-release.sh:17, finalize-pool-merge:29 and :108 ("cleanliness"), ship:19 "refuses ... if the working tree is dirty". The header is the `--help` output (`sed -n '2,33p'`), the surface DECISIONS wants agents to read. Fix: one line each: "tracked changes refused, untracked files left in place". Test: assert_grep in the existing help tests.

### F8 [low] Contract stated three times
- README.md:319-335 (14 lines), RUNBOOK.md:145-151 (6 bullets), Git_Strategy.md:270-271 repeat the same five rules. Per DECISIONS ("bin/* --help replaces runbook/strategy reads") keep the RUNBOOK section, reduce README to one sentence with a link, keep the two Git_Strategy flow steps. Token waste only.

## Items checked and clean
- R01 sync: `--dry-run` fetches nothing; fast-forward uses `reset --keep` (aborts on conflicting tracked edits); ahead/behind/equal paths verified; refusal lists both sides and gives backup + redo commands.
- R03 ordering: dev published before tag on every path; `ls-remote` read + `--force-with-lease=<read sha>`; twin check (same tree + parents); foreign origin tip aborts before tag; unreachable origin aborts before tag. VERIFIED parts a/b: tag rejected -> local tag, origin dev advanced, rerun pushes the tag (`never reached origin; pushing it (resume)`); dev rejected -> no tag anywhere, rerun completes.
- R05 `${ARGS[@]+"${ARGS[@]}"}` correct; the whole suite already runs under /bin/bash 3.2.57 (it is `bash` on this Mac). Framework scan for the same shape: 30 other `"${arr[@]}"` sites (bootstrap-ci-steps.sh:341-416, ci-local:106-179, create-pool-branch:202-358, ship:125, jira-ingress.sh:726,773, sync-framework.sh:308-310, pre-commit:111 ...); not audited here, the ledger's "scan" ask stays open.
- R06 `for-each-ref --points-at` correct; `| head -1` SIGPIPE under pipefail is theoretical for a one-line output.
- R21 traps: all three mktemp sites covered; worktree cleanup also drops the registration; no second EXIT trap overwrites them.
- Dirty-tree guard: unmerged, staged, unstaged detected; stash command quotes paths; nothing stashed automatically; untracked ignored by the amend (commits the index). `git-common-dir` relative path resolves correctly because callers `cd "$REPO_ROOT"` first and the path is used in the same cwd.
- Shallow clone / detached HEAD: `HEAD^1` missing -> backfill returns 0; claim refuses non-dev HEAD.
- Concurrency: dev lease rejects a racing push before any tag; tag pushes are add-only.
- Commit hygiene: 17 commits, TEST then FIX pairs, atomic, titles in the approved tag set, identity `v4rian-waylon (Opus)` on author and committer throughout; bodies match diffs. Overstatements in docs are F1/F4/F5, not in commit bodies.

## Counts
critical 0 | high 1 (F1) | medium 5 (F0 flaky root cause, F2, F3, F4, F5) | low 3 (F6, F7, F8)

## Verdict
FIX-THEN-MERGE. Land F0's deterministic fallback, F1's backfill ordering/walk/tag re-push, F2's twin-only adoption, F3's year-at-REV, F5's heal.sh shim install (F4 at least the diagnostic), then rerun both suites.
