# neo-git self-compliance audit (2026-10-30)

Auditor: Fable 5.1, read-only on `<workspace>/neo-git`; gates ran in a detached worktree under `$TMPDIR` (removed afterwards). Fork point: dev `5028b58` (v2026.0.136). Scope: every ref, commit, tag and file after the fork, each judged against the spec as it stood at the PARENT of that artifact (`.io.v4rian.how-git/docs/Git_Strategy.md`, `docs/RUNBOOK.md`, `README.md`, `skills/*/SKILL.md`, `githooks/*`) plus `.neo-git-work/DECISIONS.md`; the current state judged against dev `4150305` (v2026.0.169).

Baseline facts (verified): dev local = origin = `4150305`; main local = origin = `3b83366` (the intro commit, untouched since the fork; `git merge-base main dev` = `3b83366`). 414 commits after the fork (381 non-merge, 33 merges, 1 `[MODE]`); pools n165..n197 contiguous and in order on dev's first-parent line; claim tags v2026.0.137..169 contiguous, annotated, each on its merge, identical SHAs on origin (186 tags local = 186 on origin). Every merge is `--no-ff`, its second parent equals `origin/vault/<pool>`, `origin/safety/<pool>` equals the merge-base, `origin/pool/<pool>` is gone. All 33 merges and all 33 tags are authored, committed and tagged by `v4rian-waylon (Opus) <v4rian-waylon@users.noreply.github.com>`. No em/en dash, no prose "plus", no `Co-Authored-By` in any of the 414 messages; every subject carries an approved tag. No secret pattern in any added line of the 1668 new commits reachable from any ref; no junk file in the dev tree. First-parent author and committer dates never go backwards.

Severity scale: critical (data loss or an unauthorised irreversible act), high (a binding rule broken in published history or on origin), medium (rule broken but documented, or process gate unverifiable), low (hygiene). Remedy classes: fix-forward (new pool), ref cleanup (no history change), history rewrite (only when real at that time and not fixable forward).

---

## Findings

### H-01 Duplicate pool id n165 on origin (allocator uniqueness broken by the 10-30 renumber)

- Severity: high. Remedy: fix-forward (document + vault the abandoned September pool); a history rewrite would restore uniqueness but is not recommended (see H-02).
- Artifact: origin refs `pool/v2026.0/n165.fix.off-grid-allocator-ignores-clone-refs` + `safety/v2026.0/n165.fix.off-grid-allocator-ignores-clone-refs` (September, tip `0753e12`, not in dev) AND `safety/v2026.0/n165.fix.off-grid-allocator-clone-refs-p1` + `vault/v2026.0/n165.fix.off-grid-allocator-clone-refs-p1` (created by the renumber of 2026-10-30 16:33, merge `f28bef5`).
- Rule broken (in force at the renumber, parent spec `a28aaea` = v2026.0.167): Git_Strategy "Working branches": "`nN` is a creation sequence number allocated by the repo's branch-creation endpoint - atomic on the server, no collisions. Off grid the local allocator never reissues a number it can see" (wording since `69d17c5` n166; "no collisions" since the fork). RUNBOOK "Reconcile-merge dual-vault": "more than one non-reconcile candidate matches the same nN ... (which the allocator's uniqueness invariant should prevent)".
- Evidence:
  ```
  $ grep -E '/n165\.' ls-remote.txt | awk '{print $2}'
  refs/heads/pool/v2026.0/n165.fix.off-grid-allocator-ignores-clone-refs
  refs/heads/safety/v2026.0/n165.fix.off-grid-allocator-clone-refs-p1
  refs/heads/safety/v2026.0/n165.fix.off-grid-allocator-ignores-clone-refs
  refs/heads/vault/v2026.0/n165.fix.off-grid-allocator-clone-refs-p1
  $ git merge-base --is-ancestor origin/pool/v2026.0/n165.fix.off-grid-allocator-ignores-clone-refs dev; echo $?   # 1 (abandoned, not in dev)
  ```
  RUNBOOK (dev) "Renumber of n166 to n197" says the September allocation "already held n165 ... so dev went n164 to n166" and then reused n165 anyway. The only other duplicate on origin is the inherited `n96` pair (pre-fork).

### H-02 Two published-history rewrites of dev (10-30 12:15 and 16:33) with no recorded grant; claim tags moved, safety and vault refs deleted and recreated on origin

- Severity: high. Remedy: fix-forward (record the grant or its absence in DECISIONS.md; RUNBOOK entry for the 12:15 renumber, which is documented nowhere in the repo); no further rewrite.
- Artifacts: dev reflog `28f33e2 dev@{2026-10-30 12:15:26}: renumber pools n191-n192 to n190-n191` (rewrote merges `d94f076`,`ad610a3` -> `393a1aa`,`28f33e2`; tags v2026.0.161/.162 re-pointed; "drop unpushed n190 and n193 pairs", preflight-bak-2026-10-30/02) and `c46aa93 dev@{2026-10-30 16:34:21}: renumber pools n166-n197 to n165-n196` (33 merges and 381 commits replayed, tags v2026.0.137..168 re-pointed, 32 safety and 32 vault refs renamed on origin: new names pushed, old names deleted; preflight-bak-2026-10-30/05, bak zip `baks/neo-git-bak-20261030T233300Z.zip`).
- Rules broken (in force at `28f33e2`'s parent `bd40ca3`/v2026.0.160 and at `c46aa93`'s parent `a28aaea`/v2026.0.167):
  - Git_Strategy "Claim-on-Merge Semantics" step 4: "existing tags never move"; RUNBOOK "Tag holes": "Tags are only added, never moved" (both since `efed31b` n171, 10-29 15:08).
  - Git_Strategy "Safety Branches": "Lifetime: permanent. ... is never deleted" (since the fork); RUNBOOK branch shape table: `vault/...` "read-only frozen" (since the fork); Git_Strategy "Working branches": "the no rewrite principle protects merged history, vaults" (since the fork).
  - `skills/how-git/SKILL.md` "Rules at a glance": "Main moves only on the user's explicit instruction; automation never writes `dev` or `main` without a verbatim grant" (since `1c5e792` n182, 10-29 15:24).
- Evidence: `git reflog show dev --date=iso` (lines above); `git for-each-ref refs/stash-bak` holds the dropped n190/n193 pairs; `grep -rn -iE 'confirm|grant|authori' .neo-git-work/*.md *.log *.txt | grep -iE 'renumber|n166|n190'` returns only the 10-29 renumber ("Confirm 167-173"). The RUNBOOK n197 entry describes the mechanics but names no grant. Compliant for its time by contrast: the 10-29 renumber (n1001-n1007 -> n167-n173) is recorded in MERGE-NOTES and RUNBOOK as "under the owner's explicit grant" and is an admin override as Git_Strategy "Hotfix Policy" allows ("an admin override documented in the incident, not a policy").
- Note: mechanics of both rewrites followed `git-history-rewrite` (preflight ref + bak zip, `--force-with-lease`, author name/email/date kept byte for byte, committer = replay time, merge committer date = source tip committer date; verified on all 33 merges: `%cI` of merge == `%cI` of `^2`).

### H-03 Two commits authored under the sessionpass identity landed on dev (pool n184)

- Severity: high. Remedy: fix-forward (record the exception; the identity-map now lists `sessionpass -> waylon-sp`, so `commit-msg`/`pre-push` refuse it in a v4rian-io clone). A history rewrite is NOT the remedy: the spec says a rewrite "keeps the original author name, email and date" (README "Commit identity and time come from the source") and `pre-push` refuses an author-changing rewrite.
- Artifact: `171b22f` `[FIX] Feed test greps from here strings so pipefail cannot flake` and `f15e201` `[DOCS] Note the here string rule for framework tests in README`, author `waylon-sp <waylon@sessionpass.io>`, author date 2026-10-29 14:15, merged by `a5056d8` (n184, 16:22, parent `c49c63d` v2026.0.155).
- Rule broken (in force at `c49c63d`): Git_Strategy "Commit identity follows the origin's org": "Every commit, merge, `[REQ]` allocation and claim tag is authored as the account that belongs to the GitHub org of `remote.origin.url` ... The one exception: commits rebuilt from the user's own snapshots" (since `ffe7aa8` n180, 10-29 15:24). DECISIONS.md ruling 6 (10-29): "tools resolve identity from the origin's GitHub org automatically; hooks refuse wrong identity".
- Evidence:
  ```
  $ git log 5028b58..dev --format='%h|%an|%ae|%aI|%s' | grep waylon-sp
  f15e201|waylon-sp|waylon@sessionpass.io|2026-10-29T14:15:38-07:00|[DOCS] Note the here string rule ...
  171b22f|waylon-sp|waylon@sessionpass.io|2026-10-29T14:15:32-07:00|[FIX] Feed test greps from here strings ...
  ```
  The hook that enforces the rule arrived one merge later (`2917b66` n185, 16:27). The 10-30 republish passed the identity gate legitimately as an author-preserving rewrite.

### H-04 The framework's own lifecycle suite is red on dev: pool n197 merged with a test that aborts the runner

- Severity: high. Remedy: fix-forward (one `fix` pool: move the `ID_V_NAME`/`ID_V_EMAIL` definitions above the first `run_test` that uses them, or define them with the other identity fixtures at the top of the runner; then re-run and record the real counts in STATE.md).
- Artifact: `1940c96` `[TEST] Expect the rewrite check to handle commits sharing a patch` (pool n197, merged by `4150305` at 16:48:37 after the 16:33 renumber, by hand, outside `land.sh`). It adds `env GIT_AUTHOR_NAME="$ID_V_NAME" ...` at `framework-tests/test-lifecycle.sh:573` inside `test_n125_commit_audit_invokes_claude_once_for_all_commits`, whose `run_test` call sits at line 16023, while `ID_V_NAME=` is first assigned at line 16161. Under the runner's `set -u` the whole suite dies inside that test (exit 1, no summary line), so every test registered after it never runs.
- Rules broken (in force at parent `c46aa93` v2026.0.168): `skills/how-git/SKILL.md` "Rules at a glance": "The `required.*` checks (`bin/ci-local` off-grid) are green before a merge; if the budget does not fit, the work does not ship" (since `1c5e792` n182); `ci/tests/push/required.offline-test-suites.sh` is a required push gate (RUNBOOK "Layered CI hooks"); DECISIONS.md "Merge grant: pools merge to dev on their own once gates, the Fable audit and the benchmark pass". STATE.md (16:50) claims "Final full suites on dev: hooks 101/0, bench 13/0, lifecycle 638/0"; that figure predates n197.
- Evidence:
  ```
  $ LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh --filter 'n125 commit-audit invokes claude ONCE'   # at dev 4150305
    n125 commit-audit invokes claude ONCE for all commits ...             (runner exits 1, no PASS/FAIL, no summary)
  kept log: .io.v4rian.how-git/framework-tests/test-lifecycle.sh: line 573: ID_V_NAME: unbound variable
  $ same command in a worktree at c46aa93 (n196)
    1 passed, 0 failed  ALL LIFECYCLE TESTS PASSED
  $ git show 1940c96 -- .io.v4rian.how-git/framework-tests/test-lifecycle.sh | grep -n 'ID_V_NAME'   # 7 added uses, first at hunk @@ -569,6 +569,10 @@
  ```
  `.neo-git-work/land-state.log` has no entry for n197 and no suite output exists for its landing. `test-hooks.sh` (101/0), `test-bench.sh` (13/0), `scripts/lint-protocol.sh` (exit 0) and `bin/doctor` (ok) pass on the same tree.

### M-01 Pool n191 carries 23 non-merge commits (cap "about 20 at most")

- Severity: medium. Remedy: none possible forward (history); record as accepted. The planned p1 split pair was allocated and dropped.
- Artifact: `3ed6646` `[MERGE] pool/v2026.0/n191.feature.merge-body-in-hook into dev: v2026.0.163`; `git rev-list --count --no-merges 3ed6646^1..3ed6646^2` = 23 (every other pool is 3..19). `refs/stash-bak/orphan-pool_v2026.0_n193.feature.merge-body-in-hook-p1` shows the split was allocated then abandoned.
- Rule broken (in force at parent `2337781` v2026.0.162): `skills/how-git/SKILL.md` and `skills/git-commit-audit/SKILL.md`: "One pool is one feature area of about 20 commits at most; bigger work is a sequence of pools" (since `7f1814d` n181, 10-29 15:24); DECISIONS.md "Orchestrator defaults": "Oversized finished branches land as sequential ~20-commit pools". The hard cap `dev_merge_max_commits=20` (MERGE_POLICY, pre-push `mp_check_pool_size`) landed later with `a28aaea` (n195); the 16:34 republish of this merge passed only in claim push mode, as RUNBOOK "Renumber of n166 to n197" admits ("made with the claim push mode for merges that predate the merge shape and pool size gates").

### M-02 Merge n189 body fails the merge shape gate (leaves indented two spaces)

- Severity: medium. Remedy: accept (DECISIONS "Merge message gates vs hole sealing", accepted by Joel 2026-10-29: a landed merge with a non-ruled message gets a warning); a message fix would be a history rewrite.
- Artifact: `862ee3b` `[MERGE] pool/v2026.0/n189.fix.identity-gate-ignores-backups into dev: v2026.0.161`.
- Rule broken (in force at parent `66c563a` v2026.0.160): `skills/git-merge-audit/SKILL.md` rule 6 (since the fork) shows leaves as four-space indented `    - <label>: <summary>.`; DECISIONS ruling 4 "description paragraph + nested list, period on every line". The deterministic gate (`scripts/check-merge-message.sh`, `3ed6646` n191) came two merges later.
- Evidence: `bash .io.v4rian.how-git/scripts/check-merge-message.sh --commit 862ee3b` -> `X merge message: not a list line (topics "- " at column 0, leaves "    - " indented four spaces):   - Excludes preflight-bak-* branches when collecting rewrite originals.` (exit 1). The other 32 merges pass (exit 0).

### M-03 CHANGELOG covers 2 of the 33 landed pools

- Severity: medium. Remedy: fix-forward (one `doc` pool).
- Artifact: `.io.v4rian.how-git/docs/CHANGELOG.md` on dev `4150305`, `## Unreleased` (35 paragraphs, 47 089 bytes).
- Rule: CHANGELOG line 3 (since the fork): "Each section below corresponds to one `vYYYY.cycle.dev` tag ... summarizes the substantive feature, fix, refactor, and docs commits behind each tag"; README file map "CHANGELOG.md <- human-readable companion to the tag chain". The deterministic doc-freshness heuristic (`scripts/workflows/doc-freshness-check.sh`: Unreleased non-empty and >= 80 bytes per merge in main..dev) passes (169 merges x 80 = 13 520 < 47 089), so the gate is green while the substance is missing.
- Evidence: paragraph openers match only n165/n166 ("Makes the off-grid allocator never reissue a number it can see") and n178/n179 ("Lands the git-reconstruct skill"). Zero hits for: bench, benchmark, lazy, lint, merge policy, warp, contradiction, worktree, bash 3, here string, renumber, push-pool, bootstrap-offgrid, contiguous, dirty tree, friction (pools n167-n177, n180-n197). The 10-30 RUNBOOK and README were updated by their pools; the CHANGELOG was not.

### M-04 73 inherited origin `pool/*` refs are merged into dev and never vaulted; 10+ have no safety pair

- Severity: medium (inherited debt, carried deliberately). Remedy: ref cleanup (`scripts/archive-pool-branch.sh` / `bin/post-merge-lifecycle` per ref; no history change). Also the inherited `n96` duplicate pair.
- Rule (since the fork): Git_Strategy "Working branches": "Merged back via PR into dev. Deleted after merge"; RUNBOOK "Land a feature": "the archive script vaults the merged pool branch"; Git_Strategy "Each `pool/` branch has a paired `safety/` branch".
- Evidence: `scratchpad/merged_pools_on_origin.txt` (73 lines, e.g. `pool/n39.feature.off-grid-mode-and-claim-amends-title vault=0` ... `pool/v2026.0/n132.fix.lifecycle-identity vault=0`); origin pools without safety: `pool/v2026.0/n1...`, `n100`, `n115`, `n116`, `n117`, `n119`, `n120`, `n121`, `n123`, `n128` (first 10). DECISIONS "Fork": "refs carried: main, dev, pool/*, safety/*, vault/*" makes the carry deliberate; it does not make the state compliant with the current spec.

### M-05 Merge grant conditions (Fable audit per pool) unverifiable for the 10-30 pools

- Severity: medium (process). Remedy: fix-forward (this audit stands in; record it in DECISIONS/STATE).
- Rule: DECISIONS.md "Merge grant: pools merge to dev on their own once gates, the Fable audit and the benchmark pass"; SPRINT.md (10-30): "one Fable review of the integrated result happens at the end".
- Evidence: every `audit-*.md` in `.neo-git-work/` is dated 2026-10-29 04:27..06:54 (n165, claim-data-safety, hook-correctness, reconstruct, ghost-tools, docs-lanes, pending-branches); nothing covers n189-n197 (merged 10-30 12:08..16:48). Benchmark results exist (`bench-results/how-git-vs-neo-git.md`). Framework gates: see "Gates" below.

### L-01 Local clone keeps `pool/*` refs for all 33 vaulted pools and has no local `vault/*` for them

- Severity: low. Remedy: ref cleanup (local `git branch -D` of the 33 `pool/v2026.0/n165..n197` refs after `git fetch origin 'refs/heads/vault/*:refs/heads/vault/*'`), or leave: the allocator counts them harmlessly.
- Evidence: `comm -13 <(origin heads) <(local heads)` lists the 33 `pool/v2026.0/n1[6-9]x` refs as local-only and the 33 `vault/v2026.0/...` as origin-only. The archive flow renames on origin only (RUNBOOK file map: "archive-pool-branch.sh rename pool/X to vault/X on origin"), so this is compliant hygiene debt.

### L-02 Inherited non-shape branches on origin: `local/reconstruct-tool-pending-allocation`, `dev-landing`, `landing-base`

- Severity: low. Remedy: ref cleanup only on Joel's direction (tips are authored `waylon`, September 13; "Never touch user-authored commits").
- Rule: pre-push (dev) refuses branch destinations other than main, dev, well-formed pool/safety, vault, preflight-bak. Compliant for its time: the fork push (10-29 04:19) ran under the fork-time pre-push, which judged `HEAD`'s name only (`branch=$(git rev-parse --abbrev-ref HEAD)`; `main|dev` exit 0), and DECISIONS "Fork" lists the carried refs.

### L-03 Generated `DEV-MANUAL.md` published inside `preflight-bak-2026-10-29/09`

- Severity: low. Remedy: none (backup refs are immutable copies per `git-snapshot-preflight`); note only. Not reachable from dev or any pool.
- Evidence: `git log --all --not 5028b58 --diff-filter=A --format='%h %D' -- DEV-MANUAL.md` -> `daf16cf origin/preflight-bak-2026-10-29/09`.

### L-04 `[REQ]` subjects and requirement files inside renumbered pools carry the old numbers

- Severity: low; compliant as documented (RUNBOOK "Renumber of n166 to n197": "Requirement files and commit messages inside those pools still name the old numbers").
- Evidence: `98fe5e4 [REQ] active-requirement: pool/v2026.0/n191.fix.identity-gate-ignores-backups` sits in pool n189; `4f6451b ... n193.fix.restore-backup-exclusion` sits in n192; `requirements/pool__v2026.0__n191...` at `862ee3b`, `..._n193...` at `b13fa19`. Only `n197`'s file remains on dev (the next `[REQ]` drops merged lanes' files, per README).

### L-05 Original n194 merge dated 25 s after its source tip

- Severity: low; moot after the 16:33 replay. Pre-renumber `0de77fb` had `%aI` 12:50:36 vs source tip `%cI` 12:50:11 against `git-merge-audit` rule 12 ("date = the source tip's committer date"); every other landing matched to the second because land.sh replayed the pool at merge time. Now `02da78a` has merge `%cI` == `^2 %cI` (16:34:06).

### L-06 Two titles at 73 characters

- `e0953e3`, `bcd57a0` exceed the "Aim for <= 72 chars" guidance (`git-commit-audit` rule 8) but sit inside the hook's hard limit (8-100). Compliant.

---

## Looks wrong, compliant for its time

| Artifact | Why it looks wrong | Why it is compliant |
|---|---|---|
| `1e829ba` `[MODE] switch to off-grid`, a direct commit on dev | DECISIONS ruling 2: no direct commits to dev | RUNBOOK@`5028b58` line 24: "The flip lands as a normal `[MODE] switch to <new>` commit on the checked-out branch"; body matches `bin/set-mode`; identity v4rian-waylon (Opus) |
| `ebf4f91`,`187ecf3`,`aa3dc7e`,`7bd9d05` authored `v4rian-waylon` with no `(<Model>)` | identity rule wants the model in the name | September originals published pre-fork; a rewrite keeps the author; README: "`v4rian-waylon (<Model>)` takes any model or none" |
| Every 10-29 commit has committer date 2026-10-30 16:33 | looks like a mass rewrite | it is the 16:33 replay; the rule (how-git loader, git-history-rewrite) sets committer date = replay time and keeps author dates byte for byte (verified: 0 author-date changes vs `preflight-bak-2026-10-30/05`) |
| Merge author dates (10-29) earlier than their source tip's committer date (10-30) | "merge dated at source tip" | the rule binds the merge's committer date, which equals `^2`'s `%cI` on all 33 merges; first-parent `%at` and `%ct` both monotonic |
| Claim tags .137-.169 tagger dates = original merge times, not 16:33 | tags "re-pointed" | RUNBOOK n173 note: re-pointed "with their messages and tagger dates" (that procedure itself is H-02) |
| `refs/how-git/allocated/n197` left after the pool merged | leaked reservation | RUNBOOK "Off-grid allocation": reservations below the highest recorded number are pruned at the next allocation, "except the one that allocation just made" |
| 26 `local/*` lane branches (all with commits not in dev), 5 `refs/stash-bak/*` | stale refs | lanes were replayed onto allocator pools, so their SHAs differ; two (`local/agent-hooks`, `local/history-docs`) are live worktrees; how-git loader: "manual snapshots and bak zips go to the trash only on the user's direction" |
| 26 `preflight-bak-*` branches on origin | backup noise | README (n189): "the remote's `preflight-bak-*` branches are backup copies"; `pre-push` accepts the exact name shape |
| 33 pool refs absent on origin | "developers never delete" | the claim archive vaulted them (`vault/<pool>` == `^2` on all 33) |
| Pools n165-n172 have no `[REQ]` commit | RUNBOOK describes a `[REQ]` commit per pool | allocator: `ALLOC_REQUIREMENT ... optional` (fork and dev); `[REQ]` exists where `--requirement` was passed (n189, n192, n197) |
| `MERGE_POLICY dev_merge_pr=required` in off-grid mode with no PRs | policy says PR required | README: the PR rule binds "in connected mode" only; off-grid close-up enforces who, approval, gates, cap |

---

## Gates on the current tree (dev `4150305`, detached worktree)

| Gate | Result | Receipt |
|---|---|---|
| `scripts/lint-protocol.sh` (whole tree) | PASS, exit 0 | `gates.sh` run in `wt-audit` (detached at `4150305`) |
| `bin/doctor` | PASS: `ok: v4rian repo health check passed (all bins/scripts/hooks/workflows present + executable)` | same run |
| `framework-tests/test-hooks.sh` | 101 passed, 0 failed (jev corpus, 61 seeded violations) | same run |
| `framework-tests/test-bench.sh` | 13 passed, 0 failed | same run |
| `framework-tests/test-lifecycle.sh` (639 registered `run_test`) | RED, deterministic: the runner aborts inside `n125 commit-audit invokes claude ONCE for all commits` with `line 573: ID_V_NAME: unbound variable` (exit 1, no summary) on every run at `4150305`; the same filtered test passes at `c46aa93` (n196). See H-04. | 4 full runs + 3 filtered runs at dev, 1 filtered run at n196 |
| `scripts/workflows/doc-freshness-check.sh` | not runnable offline (needs `PR_NUMBER`; test mode short-circuits); its heuristic (Unreleased >= 80 B/merge) would PASS, see M-03 | run in `wt-audit` |

Caveat on the lifecycle counts: the full runs also showed 15 to 303 mid-run failures that varied between runs, every one of them `mktemp: mkstemp failed on .../v4rian-lifecycle-XXXXXX.<id>/tmp/...: No such file or directory`, that is the run's own scratch root vanishing. Root cause is the machine, not the repo: `~/.local/share/disk-guard/disk-guard.sh` line 12 runs `rm -rf "${TMPDIR:-/tmp}"/v4rian-lifecycle-*` every 60 s while free space is under `FLOOR_GB=6`; `df -h /` showed 4.3 GiB free and its log records reclaims at 18:25:30 and 18:31:30 during these runs. Two other `bash test-lifecycle.sh` processes (another session, pool n198) ran at the same time and were hit the same way. A run started with a private `TMPDIR` under `/private/tmp` (outside the daemon's glob) had 29 PASS, 0 FAIL and 0 mkstemp errors before it was stopped on the coordinator's instruction. Every test that failed in those runs passed when re-run in isolation (`version bin counts dev merges from git log`, `hooks fire through real git operations`, `claim-dev-merge stamps a ruled body`, `init-release seeds the ruled body`, `merge policy: set-merge-policy help/get/set/reject`, `smart-commit auto-stages all when index empty`, `coverage.sh runs framework-tests with marker`, `merge policy: pre-push refuses direct dev merge`). Environment note for operators: the daemon deletes live lifecycle runs, not only stale ones, whenever the disk is under 6 GB; either free the disk or point `TMPDIR` outside `/var/folders/.../T` before a suite run.

Also observed in the trace runs: the runner's `set -u` turns any unbound variable inside a test function into a silent abort of the whole suite (no FAIL line, no summary); a `run_test` that trapped the function's exit would have surfaced H-04 as one FAIL instead of hiding 160 tests.

---

## Counts

- Critical 0; High 4 (H-01, H-02, H-03, H-04); Medium 5 (M-01..M-05); Low 6 (L-01..L-06).
- Remedy: fix-forward 7 (H-01, H-02, H-03, H-04, M-03, M-05, and the RUNBOOK note for the 12:15 renumber); ref cleanup 3 (M-04, L-01, L-02 on Joel's word); history rewrite 0 recommended (M-01, M-02 are real for their time but the spec's own no-rewrite and keep-author rules make a rewrite a worse violation than the record); none 4 (L-03..L-06).
