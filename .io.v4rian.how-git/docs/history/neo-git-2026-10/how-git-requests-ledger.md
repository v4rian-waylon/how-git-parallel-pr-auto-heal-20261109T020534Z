# how-git requests ledger

Generated 2026-10-29. Checked against neo-git `dev` (5028b58, v2026.0.136), read via `git archive dev`. Paths below are relative to `.io.v4rian.how-git/` ("NS") unless stated. Read-only audit; nothing in any repo was changed.

## Sources searched
- `<workspace>/how-git/FEATURE_REQUESTS.md` (untracked, 463 lines, 14 sections). Primary source, abbreviated FR below.
- `<workspace>/.sp-beta-program/specs/HOWGIT-PROCEDURE.md` (HP): sandbox-reproduced pitfalls (26) from the SessionPass beta program. Dated 2026-10-2x.
- `<workspace>/TODOS.md` (TD): workspace TODOs 2026-05-23/24.
- `<workspace>/how-git-MATURITY.md` and `how-git-MATURITY-2026-06-16.md` (MT): maturity gap lists (June 2026).
- Searched with no how-git content: kai.core, kanbania, tappr, gravity-db, fractaris, native-ui, _spb-v4rlib, Ag/ag.sym9, abstraklib, abstrak.stale-superseded FEATURE_REQUESTS.md (hits were only Iris/sym9 library requests or v4rian text). v4rlib-native-merge/native FEATURE_REQUESTS.md concerns the app skeleton, not how-git. offgrid/TODOS.md is the offGrid music app. `.io.v4rian.how-git/` copies contain no request/bug md. No lifecycle repos found in `$TMPDIR`.
- `how-claude/docs/CONTRADICTIONS.md` and `.neo-git-work/DECISIONS.md` cover the spec contradictions already (item R14).
- Not how-git defects, skipped: `git merge -F -` reads no stdin (git itself), `git remote -v` prints tokens (git), per-repo state notes (cmna missing safety refs, app-beta hooks off), concurrent merges fail the dev lease (expected serialization).

## Counts
OPEN 31 (R14 counted as 7: R14a to R14g) | PARTIAL 3 | FIXED-IN-DEV 11 | CANNOT-TELL 2

---

## OPEN (severity order)

### R01 [HIGH, data loss] claim-dev-merge.sh --dry-run and a plain claim hard-reset local dev
- Source: FR:266-353 (V4Rlib-webapp, 2026-10-2x); HP pitfalls 5 and 21, sandboxes C2/T (`run2-C2.log`, `run6-T.log`). Duplicates merged: HP pitfall 5 (`git v4r claim-dev` alias), HP:416-428.
- Summary: the sync block runs before the dry-run exit, so `git checkout -q -B dev FETCH_HEAD` drops an unpushed off-grid merge; without `--skip-pull` the claim can also tag the previous dev tip (v2026.0.0 case).
- Status: FIXED on branch local/claim-data-safety (pool 4 fix.claim-data-safety, fix 7e6c4bb, failing test first). Was: OPEN. Proof: `NS/scripts/claim-dev-merge.sh:99-108` (sync, no `DRY_RUN` guard) still precedes `:192` (dry-run exit). The alias `v4r claim-dev` in `NS/scripts/_lib.sh:84` forwards `"$@"` with no `--skip-pull` default. The only test, `framework-tests/test-lifecycle.sh:6936`, passes `--dry-run --skip-pull`, so the unsafe form is untested.

### R02 [HIGH] Off-grid allocator reissues spent numbers (n1 again, n61 duplicated)
- Source: FR:461-463 (V4Rlib, helpen-admin-native, 2026-10-28); HP:109-126, pitfall 1, 23; `.neo-git-work/DECISIONS.md` ("n165"). Duplicates merged: V4Rlib two branches numbered n61 (commit eb3e4f9 message), allocation race of two lanes (HP pitfall 23, 6 of 6 trials).
- Summary: counts local `refs/heads/pool|safety` only; ignores remote-tracking refs, vault refs, `[MERGE]` subjects; no lock between simultaneous allocations.
- Status: OPEN in dev. `NS/scripts/allocate-pool-branch.sh:230-243` (`list_refs_for_prefix` uses `refs/heads/` in off-grid mode) and `:371-385` (`next_n` reads pool/ and safety/ only). No lock in the script. Fix exists but unmerged: neo-git branch `pool/v2026.0/n165.fix.off-grid-allocator-ignores-clone-refs` (commits eb3e4f9, 30ec63d, 0753e12, 02ca0df). It covers the three ref gaps; the lock for simultaneous allocations is not in those commit subjects (CANNOT-TELL, unverified).

### R03 [HIGH] claim-dev-merge.sh tags and pushes a tag for a commit dev never received
- Source: FR:92-111 (iris-bootstrap-lifecycle-test, 2026-08-26).
- Summary: with a non-spec merge subject (`MERGED_POOL` not detected) the dev push is skipped but the tag and tag push run anyway; the tag dangles on origin.
- Status: FIXED on branch local/claim-data-safety (pool 4 fix.claim-data-safety, fix 920685d, failing test first). Was: OPEN. Proof: dev push sits inside the `MERGED_POOL` branch (`NS/scripts/claim-dev-merge.sh:~296-315`), `else` at `:315-317` only logs, tag at `:320-338` gated only on `ALREADY_CLAIMED`. No test for it.

### R04 [HIGH, credential leak] attach.sh stamps the tokenized remote URL into SPEC
- Source: FR:115-131 (swarm, 2026-08-31).
- Summary: `source=` takes the framework checkout's origin URL verbatim, including `user:token@`; the SPEC is staged and committed.
- Status: OPEN. `NS/scripts/attach.sh:142-143` (`SRC_URL=$(git config remote.origin.url)`), stamped at `:264-265` via `stamp_spec` (`_lib.sh:939-943`); no userinfo strip, no credential guard. `sync-framework.sh:325` restamps `source=$SOURCE` the same way (same exposure when `--source` is an authenticated URL).
- Closed: FIXED on branch local/hook-correctness (roadmap pool 5), fix d521cd6 with its failing [TEST] first; lifecycle 424/0 after the audit fixes, hooks 62/0 (2026-10-29).

### R05 [MED-HIGH] finalize-pool-merge dies on empty ARGS under bash 3.2 (stock macOS)
- Source: FR:218-262 (V4Rlib/how-claude, 2026-10), FR:431-441 (V4Rlib native tier merges, 2026-10-27), HP:410-412 and pitfall 4. Three reports merged.
- Summary: `"${ARGS[@]}"` with an empty array under `set -u` is "unbound variable"; wrapper exits non-zero after the claim already succeeded.
- Status: FIXED on branch local/claim-data-safety (pool 4 fix.claim-data-safety, fix f237f64, failing test first). Was: OPEN. `NS/bin/finalize-pool-merge:164-169` unchanged (`echo` guarded with `:-`, the call is not). No bash 3.2 test. The "scan the framework for the same shape" ask was not done either.

### R06 [MED] finalize-pool-merge exits 1 silently unless the pool branch sorts last
- Source: FR:357-427 (two consumer repos, 2026-10).
- Summary: `$(... | while ...; [ ... ] && echo ...; done | head -1)` takes the exit status of the last test; with `pipefail` + `set -e` the diagnostic at the empty-value check never runs.
- Status: FIXED on branch local/claim-data-safety (pool 4 fix.claim-data-safety, fix f88129c, failing test first). Was: OPEN. `NS/bin/finalize-pool-merge:141-144` has the same shape (the comment at `:137-140` only fixed the prefix glob, n156).

### R07 [MED] FRAMEWORK_REPO marker is never cleared on a seed-inherited consumer
- Source: FR:65-88 (dcluttr-eval, 2026-08-26).
- Summary: only `step_consumer_cleanup` checks `is_template`; it logs and falls through without removing the marker, while other scripts gate on the marker alone.
- Status: OPEN. `NS/scripts/bootstrap-ci-steps.sh:705-722` has no `rm -f "$marker"`; marker-only checks remain in `scripts/workflows/ci-dispatch.sh:85,100`, `scripts/audits/coverage.sh:49`, and the usr-layer wrappers `ci/audits/push/required.*.sh`. Only `attach.sh:203` removes the marker. No test.
- Closed: FIXED on branch local/hook-correctness (roadmap pool 5), fix 417f6fa with its failing [TEST] first; lifecycle 424/0 after the audit fixes, hooks 62/0 (2026-10-29).

### R08 [MED] prepare-commit-msg flattens a list-shaped merge body when the message comes from a file
- Source: FR:135-152 (swarm off-grid close-up, 2026-08-31); HP pitfall 9.
- Summary: `commit --amend -F` reports source `message`, so the hook runs and `cap_paragraph` joins a nested list into one line and cuts it at the sentence cap; the close-up's tag then points at the pre-amend commit.
- Status: OPEN. `NS/githooks/prepare-commit-msg:32-37` skips only `merge|squash|commit`; no list detection and no `[MERGE]` subject skip in `NS/scripts/lib/auto-fix-commit-message.sh`. No change to tag placement after amend (`claim-dev-merge.sh:320`).
- Closed: FIXED on branch local/hook-correctness (roadmap pool 5), fix 79f881e with its failing [TEST] first; lifecycle 424/0 after the audit fixes, hooks 62/0 (2026-10-29).

### R09 [MED] post-checkout branch-name regex lacks the versioned prefix (and the "remote rejects" claim is wrong)
- Source: FR:23-38 (native-beta, 2026-08-11) and FR:154-215 (kanbania, 2026-10-10); HP pitfall 15. Duplicate merged.
- Summary: `post-checkout` warns on every allocator-created `pool/vYYYY.S/nN...` branch; asks for one shared constant and a corrected `Expected:` line.
- Status: OPEN. `NS/githooks/post-checkout:25` has no `(v[0-9]{4}\.[0-9]+/)?`; `NS/githooks/pre-push:36` has it. No shared constant (`githooks/` has no lib).
- Closed: FIXED on branch local/hook-correctness (roadmap pool 5), fix 7cab2e8 with its failing [TEST] first; lifecycle 424/0 after the audit fixes, hooks 62/0 (2026-10-29).

### R10 [MED] attach and sync-framework commit through the consumer's pre-commit hook (dash scrub drifts the vendored copy)
- Source: FR:443-445 (helpen-admin-native, 2026-10-27).
- Summary: the consumer's pre-commit rewrites em/en dashes inside `.io.v4rian.how-git/`, so a fresh attach differs from canonical in 31 files; `diff -rq` reports false drift.
- Status: OPEN. `NS/scripts/attach.sh:299` (`git commit -F`) and `NS/scripts/sync-framework.sh:417` have no `--no-verify`; the pre-commit skip list (`NS/githooks/pre-commit:37-43`) names only a few framework paths, not the whole namespace.
- Closed: FIXED on branch local/hook-correctness (roadmap pool 5), fix 61a3a00 with its failing [TEST] first; lifecycle 424/0 after the audit fixes, hooks 62/0 (2026-10-29).

### R11 [MED] SPEC `ref=` stamped is the local SHA, not the SHA the tag resolves to in the cloned source; doctor does not check it
- Source: FR:447-449 (helpen-admin-native, 2026-10-27).
- Status: OPEN. `NS/scripts/attach.sh:144-145` takes `SRC_SHA`/`SRC_TAG` from the local source checkout; `sync-framework.sh:236-242` still dies "does not exist in the source"; `NS/bin/doctor:143-149` only checks SPEC presence.
- Closed: FIXED on branch local/hook-correctness (roadmap pool 5), fix 33601e0 with its failing [TEST] first; lifecycle 424/0 after the audit fixes, hooks 62/0 (2026-10-29).

### R12 [MED] pre-push refuses a lane on a detached HEAD
- Source: HP pitfall 22 (`run8-detached-push.log`).
- Summary: `pre-push` reads the branch as `HEAD`, fails the name pattern, and the push cannot be made; operators must switch to the pool branch first.
- Status: OPEN. `NS/githooks/pre-push:24-38` takes `git rev-parse --abbrev-ref HEAD` and validates it with no refspec/detached handling (and, per HP:165, polices only the current branch, not the pushed refs).
- Closed: FIXED on branch local/hook-correctness (roadmap pool 5), fix e67e869 with its failing [TEST] first; lifecycle 424/0 after the audit fixes, hooks 62/0 (2026-10-29).

### R13 [LOW-MED] Parallel lanes always collide on `active-requirement`
- Source: HP pitfall 24 (run7 d2).
- Summary: every pool's `[REQ]` commit adds the same file, so the second lane merging gets add/add.
- Status: OPEN. Allocator writes the file per pool (`NS/scripts/allocate-pool-branch.sh:531-613`); no `.gitattributes` and no merge driver in dev.
- Closed: FIXED on branch local/hook-correctness (roadmap pool 5): per-lane requirement files, fix 6a71a49 (replaces the 3cfa1a8 merge driver after audit HC-01/HC-02), works for forge-side merges too; lifecycle 424/0, hooks 62/0 (2026-10-29).

### R14 Spec contradictions found by a compliance audit (FR:451-459). Each sub-item still holds in dev.
- R14a [MED] Merge body shape: `NS/skills/git-merge-audit/SKILL.md:140` ("one paragraph", also `:28`) vs `:29-43` (nested labelled list). OPEN. (Same conflict reported by HP pitfall 16.)
- R14b [MED] Merge title length: `git-merge-audit/SKILL.md:20` (72) vs `NS/githooks/commit-msg` (140 for merge) and `claim-dev-merge.sh:209` (longer `[MERGE]` subjects). OPEN. (HP pitfall 17.)
- R14c [MED] Single-commit work: `git-commit-audit/SKILL.md:18,97` and `git-strategy-audit/SKILL.md:56-58` ("straight to dev") vs `docs/Git_Strategy.md:58` ("No direct commits"). OPEN.
- R14d [MED] Version source: `git-merge-audit/SKILL.md:22-24,138-139` and `git-commit-audit/SKILL.md:107` say `cat VERSION`; `docs/Git_Strategy.md` says tags are the seal and `bin/version` has no VERSION file. OPEN.
- R14e [LOW] Branch kinds: `git-strategy-audit/SKILL.md:28,81-83` regex omits `doc`; `pre-push:36` accepts it (`Git_Strategy.md:13` lists it). OPEN.
- R14f [LOW] Safety refs: `Git_Strategy.md:130-135` ("permanent, never deleted") vs `:380-383` and `bin/ship:10` (GC'd after release). OPEN.
- R14g [LOW] Identity: `git-history-rewrite/SKILL.md:12` and `git-snapshot-preflight/SKILL.md:16` take identity from `git config`; no env/per-org rule in the framework. OPEN.

### R15 [LOW-MED] git-commit-audit skill contradicts itself: title length and approved tags
- Source: FR:42-61 (native-beta, 2026-08-11); HP:240-243.
- Status: OPEN. `NS/skills/git-commit-audit/SKILL.md:8` says 8-100 chars, `:30` still says 72; `:22` lists no `[REQ]` or `[MODE]` (the auto-fix `APPROVED` set at `scripts/lib/auto-fix-commit-message.sh:214` also lacks them). Related: git-merge-audit "CI auto-tags" at `:126` is wrong off-grid (HP pitfall 15).

### R16 [LOW-MED] RUNBOOK and requirements still say off-grid allocation is connected-only
- Source: HP pitfall 15; MT-06-16:53,75 (HG-I05).
- Status: OPEN (docs). `NS/docs/RUNBOOK.md:30` and `NS/REQUIREMENTS.md:407` (HG-I05, P3, "documented limitation") contradict `allocate-pool-branch.sh` (`MODE = off-grid` path at `:230-238`) and `bin/create-pool-branch`.

### R17 [LOW-MED] prepare-commit-msg rewrites message content that cannot be opted out of, even with `--no-verify`
- Source: HP:219-243, pitfalls 9 and 25.
- Summary: "plus" becomes "and" anywhere (also inside symbol phrases), a path-led bullet gets relabeled (`npm run test:unit` becomes `npm run test: unit`), a fourth sentence is cut, on rebase replays and in the allocator's `[REQ]` body.
- Status: OPEN (design gap, no escape hatch). `NS/scripts/lib/auto-fix-commit-message.sh:143` (banned word "plus"), `:278-342` (bullet rewrites); `prepare-commit-msg` runs regardless of `--no-verify` (git behavior).
- Closed: FIXED on branch local/hook-correctness (roadmap pool 5), fix 3e95ffd with its failing [TEST] first; lifecycle 424/0 after the audit fixes, hooks 62/0 (2026-10-29).

### R18 [LOW] pre-commit dash scrub rewrites dash characters inside staged code
- Source: HP:229-232, pitfall 10 (`/[--]/` regex incident); pitfall 20 (requirement text with dashes fails the push dash gate).
- Status: OPEN (by design but unguarded). `NS/githooks/pre-commit:87-98` replaces `-`/`-` in any staged text file; only a path skip list exists (`:37-43`). The allocator `[REQ]` commit (plumbing) does not scrub, so requirement text with dashes reaches the push gate raw.
- Closed: FIXED on branch local/hook-correctness (roadmap pool 5), fix eaf8e5b with its failing [TEST] first; lifecycle 424/0 after the audit fixes, hooks 62/0 (2026-10-29).

### R19 [LOW] Tag holes are permanent; one non-pool merge on dev spends a version
- Source: HP pitfalls 12 and 19 (V4Rlib v2026.0.76 hole).
- Status: FIXED on branch local/claim-data-safety (pool 4 fix.claim-data-safety, fix a1d79aa, failing test first). Was: OPEN (design). `NS/bin/version:111-118` counts first-parent merges by design ("unfailing primitive"); no repair or hole-detection command in dev (only the consumer-side `hg_verify_claim` in HP).

### R20 [LOW] Hooks off (core.hooksPath unset): merge succeeds, claim never runs
- Source: HP:404-410, pitfall 3.
- Status: FIXED on branch local/claim-data-safety (pool 4 fix.claim-data-safety, fix 0e18733, failing test first). Was: OPEN. `NS/bin/doctor:86` has a hooksPath drift probe, but nothing warns at merge time and `finalize-pool-merge` is not the default path; no automatic recovery beyond `heal.sh`.

### R21 [LOW] mktemp without trap in two scripts
- Source: MT-06-16:65.
- Status: FIXED on branch local/claim-data-safety (pool 4 fix.claim-data-safety, fix 938595b, failing test first). Was: OPEN. `NS/scripts/claim-main-release.sh:228` (`MSG_FILE=$(mktemp)`) and `NS/scripts/auto-rebase-pools-after-dev-merge.sh:532` (`mktemp -d`) have no `trap` (grep found none in either file).

### R22 [LOW, feature] bin/reject-pr
- Source: TD:92-108 (2026-05-23).
- Status: OPEN. No `bin/reject-pr` in `NS/bin/`.

### R23 [LOW, feature] PR body vs merge commit body parity check
- Source: MT gap 7.
- Status: OPEN. No parity workflow or script (`grep -i parity` in `validate-pr-open.sh` and `claim-dev-merge.sh` finds only the "full parity with the PR" comment at `claim-dev-merge.sh:201`).

### R24 [LOW, feature] Scheduled GC of released safety anchors
- Source: MT gap 9 (June 2026).
- Status: OPEN. `NS/bin/ship:10` GC runs only at the main release; no scheduled workflow in `.github/workflows/`.

### R25 [LOW, feature] Rebase of local (unpushed) pool branches (`bin/sync`-style)
- Source: MT gap 8.
- Status: OPEN. `NS/scripts/auto-rebase-pools-after-dev-merge.sh` works on pushed pool refs (per MT); no local-branch sweep in `NS/bin/`.

---

## PARTIAL

### P1 `docs|test` branch kinds
- Source: MT:80-81,101; TD note.
- Status: PARTIAL. `doc` accepted in `NS/githooks/pre-push:36` and `post-checkout:25`; `test` kind still rejected.

### P2 JIRA and API integration
- Source: TD:52-63 (2026-05-23).
- Status: PARTIAL. `NS/bin/jira-ingress` and `NS/scripts/jira-ingress.sh` exist; Linear/Notion/Slack abstraction not present.

### P3 Off-grid allocation tooling (HG-I05, `bin/bootstrap-offgrid`)
- Source: MT-06-16:53,75.
- Status: PARTIAL. Off-grid allocator works (`allocate-pool-branch.sh:230-238`), but no `bin/bootstrap-offgrid` and R02 applies.

## CANNOT-TELL

### C1 Template default branch (main) carries no template content
- Source: FR:4-19 (native-beta, 2026-08-11). Concerns the hosted `v4rian-io/how-git` default branch and the `how-new` skill (outside the repo). neo-git is private and off-grid; remote state not checked.

### C2 Automatic conceptual isolation in the reconcile flow
- Source: TD:76-90 (post-pool/n26). The auto-rebase reconcile flow exists (n141 to n145 merges on dev), but whether the >50 percent trigger described in the TODO is implemented was not verified.

---

## FIXED-IN-POOL (not on dev yet)

- Pool 4 `fix.claim-data-safety`, branch `local/claim-data-safety` (17 commits, 2026-10-29): R01, R03, R05, R06, R19 (self-healing: next claim seals unclaimed merges, RUNBOOK "Claim safety" explains why not made impossible), R20, R21, plus the dirty-tree claim (audit change 10: untracked files pass, tracked edits refused with exact commands). Fable audit (audit-claim-data-safety.md, F0 to F8) fixed on the same branch, 32 commits: F0 bin/version fallback by version order (flake root cause, 16/16 green), F1 holes sealed before pushes and missing tags republished, F2 twin-only adoption with no trust in CI variables, F3/F4 --at by REV year and prior releases with a walk across releases, F5 heal.sh/set-mode/finalize/ship install the fallback and doctor reports it, F6 named refusal for an untracked file in the sync path, F7 help text, F8 README trimmed to a RUNBOOK link. Lifecycle 426/426, hooks 60/60.

## FIXED-IN-DEV

- F1 off-grid mode for claim ceremonies (TD:122-162): `NS/MODE`, `bin/set-mode`, `bin/finalize-pool-merge`, `bin/ship`, RUNBOOK mode table (`docs/RUNBOOK.md:14-36`).
- F2 `bin/version` starts main counter at 0 (TD:65-74): `NS/bin/version:97-113`.
- F3 restore test workflow bound to PRs (TD:110-121): superseded by `.github/workflows/ci-dispatch.yml` with `ci/tests/push/required.offline-test-suites.sh`.
- F4 allocator endpoint (MT gap 1): `.github/workflows/allocate-pool-branch.yml`, `NS/services/branch-creator/README.md`, `scripts/allocate-pool-branch.sh`.
- F5 `bin/commit` wrapper (MT gap 2): `NS/bin/smart-commit` and `scripts/lib/auto-fix-commit-message.sh`.
- F6 single source of truth for version (MT gap 3): claim delegates to `bin/version --seal` (comment at `claim-dev-merge.sh:~113`).
- F7 CI claim failure surfacing (MT gap 4): `scripts/workflows/claim-retry.sh`, retry loop in `ci-dispatch.yml`, 4320-minute timeout (README:116).
- F8 PR title as merge commit title (MT gap 6): `scripts/bootstrap-ci-steps.sh:434`, `claim-dev-merge.sh:174`.
- F9 finalize-pool-merge cannot see prefixed pools (HP:424): `bin/finalize-pool-merge:137-140` (prefix glob, v2026.0.128).
- F10 `version.build` not ignored (HP pitfall 26): `/version.build` in canonical `.gitignore:42` (consumer copies may still lack it).
- F11 `bin/version` and mode-flip tooling surface (MT mode in doctor/status): `bin/status` and `bin/doctor` report mode (RUNBOOK:12).

## Not tracked as defects
Skills and memory outside the repo (how-new, global how-git loader) were not read for requests. Two requests ask for lifecycle tests (R01, R03, R05, R06, R07): none of those tests exist in `framework-tests/test-lifecycle.sh` (834 `test_` mentions, none cover those cases by name).
