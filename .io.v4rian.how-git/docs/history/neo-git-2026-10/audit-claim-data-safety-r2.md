# Audit r2: local/claim-data-safety (6d5bed4..ce5986e, the F0-F8 fix commits)

Auditor: Fable 5.1, 2026-10-29. Read-only on neo-git; executed in detached $TMPDIR worktrees (removed). Range: 15 commits (7 TEST+FIX pairs + 1 DOCS), 13 files, +498/-106. Scenario scripts: `<scratchpad>/s1-twin.sh`, `s2-holes.sh`, `s3-publish.sh`, `s4-fallback.sh`, `s5-misc.sh`, `s6-more.sh`, `s7-wt.sh`, `s8-wtdiag.sh`, `disc2.sh` (+ `r2-lib.sh`).

## Suites (branch worktree, /bin/bash 3.2.57)
- test-hooks.sh: 60 passed, 0 failed.
- test-lifecycle.sh: 426 passed, 0 failed (the r1 flake `version math across release cycles` green; matches the [DOCS] body).

## Discrimination (brief item 4)
Each new test run at its own [TEST] commit (fix absent) FAILS: F0 @ca5798a (`expected v2026.2.0, got v2026.1.3`), F2 @cd0deab, F1 @b87d711, F3 @f70cfd8, F4 @f70cfd8 (`expected v2026.0.2, got ''`), F5 @658fbbe, F6 @671d660 (`expected 2, got 128`), F7 @481231f. All pass at the tip (suite run). Receipt: `disc2.out`.

## r1 findings: closure check
- F0 closed. `bin/version:210-215` picks the highest `vYEAR.S.D` tag merged into dev by numeric sort. Against neo-git's real history: `--seal` = v2026.0.136, `--next-dev` = v2026.0.137, identical to the pre-fix binary; `--seal --at` recomputed for all 125 tagged first-parent dev merges: 125 agree, 0 mismatches. Pre-release `v2026.5.1-b.1`, `milestone/*`, `snap/*`, `v2026.120.0..v2026.122.5` are not reachable from dev (`git tag --merged dev`), so they cannot enter the fallback; in a fixture a pre-release tag on the dev tip is excluded by the regex (VERIFIED, s2). Residual: G5.
- F1 closed. Seal runs after the dev push and before any tag push (`claim-dev-merge.sh:525-532`); `publish_claim_tags` re-pushes every annotated "dev tag" `vN.N.N` on HEAD's history that `ls-remote` lacks. Test F1 (reject tags once, rerun) passes and discriminates. Residuals: G3, G8.
- F2 closed. Adoption only when tree and `%P` match (`:154-157`). s1: same tree + different parents (squash) refused rc=2; same parents + different tree refused; two local commits ahead with a twin of the first refused; `CI=true GITHUB_ACTIONS=true` changes nothing (F2 test). Can a divergence pass that loses content? No: equal parents force the local-only set to be exactly the tip, equal trees make its content identical; only author/committer/message/signature of that one commit are replaced (s1 a: author `mallory` adopted, local hand-written body now reflog-only). See G10.
- F3 closed. `--at` takes the year from REV's UTC committer date (`bin/version:166`). s2 (prior year with a release, hole on Dec 31, hole on Jan 2 before the first new-year claim): sealed `v2025.0.3 v2025.1.0 v2025.1.1 v2026.0.1`, HEAD `v2026.0.2`, pre-framework merge left alone, `for-each-ref` diff before/after shows additions only (no tag moved). Residual: G9.
- F4 closed. `dev_line_merges` jumps a release merge to its second parent (`:270-289`); `--at` counts only releases whose shipped tip precedes REV. s2 second cycle and F4 test green. `--seal --at <release merge>` returns the reused release tag (correct). Residual: G11.
- F5 closed with two gaps. heal.sh, set-mode, finalize-pool-merge, ship install the shim; doctor reports a missing or non-executable shim; path with spaces and subdirectory cwd fine (s4 a, d). Gaps: G2 (linked worktree, pre-existing), G7 (exec bit).
- F6 closed for the file/file collision (test F6, rc=2 with path and `mv`). Gaps: G1 (ignored file, silent overwrite), G4 (file vs directory).
- F7 closed for the four `--help` headers. Gap: G6 (one stale step line).
- F8 closed: README:319-322 is one paragraph + link; anchor `#claim-safety-what-the-claim-will-and-will-not-do` matches RUNBOOK.md:145.

## New findings

### G1 [high] The sync silently overwrites an ignored local file that origin dev newly tracks (claim-dev-merge.sh:134-136, 147)
- The guard intersects `git ls-files --others --exclude-standard` (ignored files excluded) with the sync diff; `git reset --keep` then overwrites ignored paths without a word. Contract (RUNBOOK:148, help, `_lib.sh:1757` "a sync that would overwrite one is refused by name") promises the refusal.
- VERIFIED (s5 a): local `secrets.local` ignored via `.git/info/exclude`, content `MINE_PRIVATE`; origin dev adds a tracked `secrets.local`. Claim: `→ fast-forwarded local dev to origin/dev`, rc continues; `secrets.local now: [THEIRS]`. No reflog, no backup; local-only content gone. Pre-R01 `checkout -B` did the same, but this branch is the one stating the guarantee.
- Fix: build `hit` from `git ls-files --others --exclude-standard` plus `git ls-files --others --ignored --exclude-standard` (one `-z`-safe list), refuse by name with the same `mv` lines; mention "ignored included" in the message. Test: F6 variant with the file listed in `.git/info/exclude`, expecting rc 2 and the content intact.

### G2 [medium, pre-existing on dev] A hook-driven claim refuses inside a linked worktree: every tracked file reported as modified (claim-dev-merge.sh:46, githooks/post-merge, 15 scripts)
- git exports `GIT_DIR=<repo>/.git/worktrees/<wt>` (no `GIT_WORK_TREE`) to hooks run in a linked worktree. `REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)` then resolves to `.io.v4rian.how-git/scripts` (cwd becomes the work tree), the script `cd`s there and `claim_tree_guard` lists the whole tree as staged/modified.
- VERIFIED (s7, s8): worktree merge with hooks on or via the shim: `X claim-dev-merge: tracked changes in the work tree ...` listing 130 paths, `tag=[]`; probe hook prints `GIT_DIR=.../.git/worktrees/wt GIT_WORK_TREE=unset`, `toplevel-from-scripts-dir=.../wt/.io.v4rian.how-git/scripts`. Same merge in the main checkout claims. On dev 5028b58 the same scenario also leaves `tag=[]` (the old clean check listed the scripts dir as `??`), so pre-existing; the by-hand claim inside the worktree works (rc=0, v2026.0.1). 15 scripts use the same `git -C "$SCRIPT_DIR"` pattern (archive-pool-branch, auto-rebase, claim-main-release, heal, open-pr, attach, post-merge-lifecycle, validate-pr-open, sync-framework, bootstrap-ci, init-pool-merge, create-pool-branch, init-release, finalize-pool-merge).
- Fix: `unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE` at the top of `githooks/post-merge` (and the shim) before handing over, or resolve `REPO_ROOT` with `git rev-parse --show-toplevel` from the hook cwd. Test: R20/F5 shape inside `git worktree add`. Separate pool acceptable (not this ledger's item), but RUNBOOK:149 now promises the shim "runs the claim" without the worktree caveat.

### G3 [medium] Hole detection and tag republishing depend on a local tag set the claim never refreshes (claim-dev-merge.sh:120, 292-299, 320-324)
- The sync `git fetch -q origin dev` has no destination refspec, so git never auto-follows tags (VERIFIED: side clone, `fetch origin dev` after a new tagged commit, `git tag -l` stays empty). `seal_unclaimed_merges` reads only local tags.
- VERIFIED (s3 d): a clone missing v2026.0.2/v2026.0.3 (present on origin) seals both again as new tag objects ("sealed by a later claim" subject) on the same commits; publish skips them by name; every later `git fetch --tags` prints `! [rejected] v2026.0.2 -> v2026.0.2 (would clobber existing tag)` x2 for good. VERIFIED (s6 b): a tagless checkout (no local `v*` tag) seals nothing and says nothing; origin ends `v2026.0.1 v2026.0.3`, the hole stays. Whether the ci-dispatch `fetch-depth: 0` checkout carries tags is UNVERIFIED (actions/checkout `fetch-tags` defaults false).
- Fix: in the sync fetch `origin dev 'refs/tags/v*:refs/tags/v*'` (no `+`, so an existing tag is never moved and a differing one fails loudly), and in `seal_unclaimed_merges` treat a name present in the `ls-remote` tag list as sealed. Test: s3 d shape expecting no local mint and a clean `fetch --tags`; tagless shape expecting the hole sealed.

### G4 [low] F6 misses the file-vs-directory collision; rc=128 after "left in place" (claim-dev-merge.sh:134)
- VERIFIED (s5 b): local untracked file `notes`, origin adds `notes/a.txt`: `→ ... untracked file(s) left in place ...` then `error: Untracked working tree file 'notes' would be overwritten by merge. fatal: Could not reset index file`, rc=128. No loss. Fix: also match any untracked path that is a prefix directory of a diff path (or catch the `reset --keep` failure and print the mv lines). Test: the scenario, rc 2.

### G5 [low] Fallback hijack by any `vYEAR.N.M` tag reachable from dev (bin/version:213-214)
- VERIFIED (s2): after a release, a stray lightweight `v2026.9.9` on an old dev commit makes `--seal` return `v2026.9.9` (release would reuse it). Same exposure as before (describe), narrower than claim tags. Fix: restrict to annotated tags whose subject starts with `dev tag ` (`for-each-ref --merged`), or take the tag pointing at the released dev tip. Test: the scenario expecting v2026.0.3.

### G6 [low] Help step 3 still says "refuse a divergence outside CI" (claim-dev-merge.sh:27-28)
- Contradicts F2 (twin-only, every environment). One line. Test: extend F7 with a negative grep.

### G7 [low] heal.sh says it installs the fallback but never restores a lost exec bit (_lib.sh:1786-1788, heal.sh:69-74)
- `ensure_merge_hook_fallback` skips the write (and the chmod) when the body already matches. VERIFIED (s4 e): `chmod -x` shim, doctor: `fallback post-merge ... is not executable; run heal.sh`; heal.sh: `→ installing the fallback post-merge`; `heal restored exec? NO`; doctor still complains. Fix: `[ -x "$shim" ] || chmod +x "$shim"` after the content check. Test: F5 variant.

### G8 [low] `publish_claim_tags` recognises claim tags by subject text only (claim-dev-merge.sh:322-324)
- VERIFIED (s6 c): a lightweight `v2026.0.7` on a commit whose subject starts with `dev tag` is pushed (`%(contents:subject)` of a lightweight tag is the commit subject). Fix: add `%(objecttype)` and require `tag`. Also VERIFIED: a claim tag deliberately deleted on origin comes back at the next claim (s3 b; add-only by design, state it in RUNBOOK), and when `ls-remote --tags` fails the function treats every claim tag on dev as missing and re-pushes all of them (s3 c: 3 pushes; 136 on neo-git) instead of aborting.

### G9 [low] A hole with a future committer year is sealed into that year now (bin/version:166)
- VERIFIED (s5 f): hole dated 2027-01-05 in 2026: `sealed ... as v2027.0.1`, pushed. Consistent with the live count (the 2027 chain will continue at .2), but surprising; one warning line when REV's year differs from today's.

### G10 [info] Twin adoption drops the local merge's author and hand-written body
- VERIFIED (s1 a). By the rule; print the dropped subject and body (or `git branch backup/...`) so the operator keeps them without reflog archaeology.

### G11 [low] A merge into main that dev never took: live `--seal` v2026.2.0 vs `--seal --at HEAD` v2026.1.0 (s6 a)
- Outside the model (main only receives dev); when dev does take it both agree (s5 d). Document, or count SERIES from releases only.

### G12 [info] What the first claim on neo-git itself will do
- 11 untagged first-parent merges on dev (2026-05-25): 9 get minted and pushed (`v2026.0.35 .51 .52 .53 .56 .73 .74 .75 .77`), 2 report `already seals <sha>; left as is` because `v2026.0.84`/`v2026.0.89` sit on amended twins off the first-parent line (c2f6649, 88ec694). 125/125 existing tags agree with the recount, so the numbers are the ones those merges spent. Intended R19 behaviour; stating it in the merge body avoids a surprise.

## Items checked and clean
- Twin check rejects every non-metadata divergence (s1 b-d); `sync_dev_to` keeps the F6 refusal on the adopt path.
- Hole walk: never stops at a tagged merge, skips merges older than the first claim tag, jumps release merges to the shipped dev tip, second claim re-seals nothing (s2); bash 3.2 compatible (`grep -Fxf <(...)`, `awk` reverse, no arrays).
- Tags never moved: `for-each-ref` before/after diff shows additions only (s2); `git tag -a` on an existing name would fail loudly.
- Non-claim tags stay local: lightweight, annotated non-"dev tag", `milestone/*`, `snap/*`, pre-release (s3 a).
- Shim: path with spaces, subdirectory cwd, body drift rewritten, consumer-owned slot untouched and documented (s4); common-dir hooks are what git runs in worktrees.
- `--at` on a root commit, a non-merge, a bogus ref: `v2026.0.0`, cycle value, `X version: --at nonsense is not a commit` rc 2.
- Commit hygiene: 15 commits, TEST then FIX, atomic, titles in the approved set, author and committer `v4rian-waylon (Opus)`, bodies match diffs (426/426 and the per-area test counts hold); no `Co-Authored-By`.
- Docs: README cut to one paragraph with a valid anchor; RUNBOOK and Git_Strategy state the new rules once each; no new token waste beyond G6.

## Counts
critical 0 | high 1 (G1) | medium 2 (G2 pre-existing, G3) | low 7 (G4-G9, G11) | info 3 (G10, G12 + CI-tags UNVERIFIED)

## Verdict
FIX-THEN-MERGE. Land G1 (include ignored files in the refusal, one test), G3 (fetch `refs/tags/v*` in the sync, treat origin-present names as sealed), G6 and G7 (one line each), then rerun both suites. G2 belongs to its own pool (hook `unset GIT_DIR`, 15 scripts) but should be noted in RUNBOOK's hooks-off bullet before this merges.
