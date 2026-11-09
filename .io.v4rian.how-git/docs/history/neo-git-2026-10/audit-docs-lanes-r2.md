# Audit round 2: docs lanes (local/spec-contradictions 18 + local/lean-skills 5 + local/lazy-loader 3, stacked on dev 5028b58)

Auditor: Fable 5.1, read-only, 2026-10-29. Worktree `$TMPDIR/aud-dl2` at 7dedd1c (removed after the run). Paths relative to `.io.v4rian.how-git/` at 7dedd1c unless stated. Round 1: `audit-docs-lanes.md` (DL-01..DL-09). Diff round 1 tip 8ab8932 → 7dedd1c: 9 files, +77/-73 (PR template, lifecycle test, commit-audit, history-preservation, merge-audit, shuttle, snapshots, strategy-audit, loader).

## Suites (VERIFIED, worktree at 7dedd1c, sequential)

- `framework-tests/test-hooks.sh`: 60 passed, 0 failed (rc 0).
- `framework-tests/test-lifecycle.sh`: 407 passed, 0 failed (rc 0).
- Discrimination of the changed tests (mutate, `--filter`, restore with `git checkout HEAD --`): old dev template → `0 passed, 1 failed` ("pattern 'git-merge-audit rule 5' not in ..."); empty `skills/git-shuttle/tools/` dir → fail "skills name missing tool: skills/git-shuttle/tools/_snapshot-scope.sh"; empty `.github/workflows/audit-pushed-branch.yml` → fail "skills name missing workflow: dev-merge.yml"; `Section IX` appended to git-snapshots → fail "skills carry retired spec phrases"; clean tree → `1 passed`.

## Round 1 findings, status

| Id | Status | Receipt |
|---|---|---|
| DL-01 merge vs PR shape | PARTIAL → R2-01 | 71413a6: rule 10 now states the `PR #N <url>` paragraph and the diff check; template is paragraph + nested list; rule 6 bans enumeration again. Not checked: what `validate-pr-open.sh` does to the PR body before the claim copies it (below). |
| DL-02 git-snapshots ruling 2 | CLOSED | d3bba4b: `:108` "give every topic its own working branch, a single commit included", `:111` "sections A-J", `:128` `<working branches>`; lint grep in the loader test fails on `single-commit-to-dev|Section IX` (mutation above). |
| DL-03 history-preservation ruling 6 | CLOSED | d3bba4b `:88` now points at Git_Strategy "Commit identity follows the origin's org"; lint grep covers `run as the user.s identity`. |
| DL-04 ghost tools and workflows | CONDITIONAL → R2-06 | 1e3bd96 extends the test: resolves every `skills/<s>/tools/<x>.sh` and `<w>.yml` the skills name, but only when `skills/git-shuttle/tools/` or `audit-pushed-branch.yml` exists; otherwise prints SKIP. Discriminates once pool 10 lands (mutations b, c). The skills still carry no "(pool 10)" marker. |
| DL-05a dash escape | CLOSED | commit-audit E.29 and loader hook line carry the `-` / `-` escape rule. |
| DL-05b inline enumeration | CLOSED | merge-audit 6 "method names or a comma-separated inline enumeration each fail the rule". |
| DL-05c branch-name words | CLOSED | commit-audit G.34 "no `zipN`, `bak`, `wip`, `snapshot` or `historical`". |
| DL-05d 20 commits | CLOSED | loader rule and G.34 "about 20 commits at most". |
| DL-05e bootstrap row | CLOSED | loader row "Bootstrap a new repo": `git-strategy-audit`, `git-commit-audit`; `bin/doctor`. |
| DL-05f close-up tail | ACCEPTED | `bin/finalize-pool-merge:8-9,35` "vault the pool branch into vault/, and push everything ... The claim script does the amend, tag, vault, and push" (header only, runtime UNVERIFIED). |
| DL-06 BSD-only recipes | CLOSED | commit-audit F.30 `date -r` + GNU `date -d "@$EPOCH"`, `stat -f %m` + GNU `stat -c %Y`; shuttle D.7.1-2 `stat -f '%B'` + GNU `stat -c '%W'`, `date -r` + GNU `date -d @`. GNU branch UNVERIFIED on this host (the commit says so). |
| DL-07 author dates later than descendants | RESET → R2-02 | all 26 commits now `2026-10-29T06:23:35-07:00` to `06:23:39`, author == committer, monotonic (`git log --format='%at %ct'` 0 mismatches, 0 backwards). Whether that reset is allowed: below. |
| DL-08 cosmetic | CLOSED | J is a paragraph plus three bullets; zips row Tools column empty, `git-snapshot-preflight` named in the Read column; strategy-audit `:74` "`post-checkout` warns on a misnamed branch, `pre-push` refuses to push one" matches `githooks/post-checkout:2,63` and `githooks/pre-push:59` `exit 1`. |
| DL-09 pre-existing stale text | OPEN (info) | README `:97-99` how-push, `:339` build-on-tag section; lint pool. |

## New findings

### R2-01 [MEDIUM] Rule 5, rule 10 and the template describe a connected-mode body the shipped PR path does not produce
- `skills/git-merge-audit/SKILL.md:26` ("every merge ... and its PR body"), `:94` ("the PR body verbatim ... write the PR body in the rule 5 shape, since it becomes the merge body"), `:103-104` (lens), `.github/PULL_REQUEST_TEMPLATE.md:7-13`.
- Evidence VERIFIED by running `auto_fix_message` (the pass `scripts/validate-pr-open.sh:312` runs over every PR body with `AUTO_FIX_DERIVED_TAG` exported at `:309`, then `gh pr edit --body` at `:324`) over a rule 5 shaped body in the worktree:
  - tip lib: first line becomes `[REFACTOR] Lands the parser rewrite with error recovery for malformed input.`; the nested list collapses to `- Parser. - Block grammar: ... - Error recovery: ...` and the `- Tests.` topic is cut (ledger R08, fixed on local/hook-correctness 79f881e, pool 5).
  - hook-correctness lib (`_lib.sh` sourced): list intact, but the first line is still `[REFACTOR] Lands the parser ...` and the leaf `Fixtures: add ...` becomes `Fixtures: Adds ...`.
  - `validate-pr-open.sh:316-319` then appends `<!-- opened-via-correct-flow run=<id> -->`; `claim-dev-merge.sh:241,271-273` copies that body verbatim under `PR #N <url>` (no signature strip: `grep -n 'opened-via' scripts/claim-dev-merge.sh` → nothing).
  - The template's own `<!-- ... -->` block stays in the body unless the author deletes it (dev template through the tip lib → `[REFACTOR] <!--`); the new template does not say to delete it.
- So every connected merge body is: `PR #N <url>`, blank, `[TAG] <paragraph>`, list, blank, HTML comment. Rule 8's lens (`:104`) flags it three times (`\[[A-Z_]+\]` on the tag, `/` on the URL, `<` on the comment), rule 5's "every list line ending with a period ... no header" is met but the shape claimed for "its PR body" is not. Ruling 4 asked to "first verify ... merge vs PR"; the verification is still incomplete.
- Fix: in rule 10 state the shape the claim actually writes today (PR line, the validator's tag prefix and signature trailer) and name the pool 8 changes that make rule 5 true for PRs (no `AUTO_FIX_DERIVED_TAG` on bodies, claim strips the signature, lens excludes the PR line); add "delete this comment" to the template comment. Or move the whole PR-shape sentence out of rule 5 into pool 8 and leave rule 5 for the merge body alone.
- Test: the gh-mock claim test already in the pool 8 backlog, asserting `git log -1 --format=%b` after the amend.

### R2-02 [MEDIUM] The `--ignore-date` reset contradicts the branch's own rewrite rule, and the protocol has no rule for the replay's dates or the merge order
- `skills/git-history-rewrite/SKILL.md:12` "a rewrite (message fix, retag, amend, replay) preserves each commit's original author name, email and date byte for byte"; `skills/git-commit-audit/SKILL.md:73` (I) "A rewrite keeps each commit's original author name, email and date"; `skills/how-git/SKILL.md:49` same; `git-commit-audit:56` (F.30) "a replayed commit keeps its own `%aI`"; `:57` (F.31) "monotonic on the branch, ≤ now"; `git-merge-audit:66-74` (12) merge date = source tip `%aI`.
- Evidence VERIFIED: reflog `local/lazy-loader@{0..2}` and `local/spec-contradictions@{0,1}` are `rebase (finish)` entries; every author date on `dev..local/lazy-loader` is now 06:23:35-39 (the round 1 dates were 05:39-05:56), so the rebase replayed 26 own, unpushed commits with new author dates: exactly what `:12` forbids for a "replay", and F.30 says "set no date variables" for real-time commits. Nothing in the three skills says unpushed same-session commits are exempt.
- Precedent on dev (VERIFIED): `5028b58` (n164) and both pool commits `89ee86d`, `aef10b0` carry one timestamp `2026-07-19T07:38:00-07:00`; `2ef9134` (n163) and `93917ef` likewise `20:54:48`; the last six first-parent merges are monotonic. The project's practice is to stamp a pool's commits and merge with one instant at replay, which the tip rule now forbids by its letter.
- Consequence at merge time (VERIFIED tips, `git log -1 --format=%aI`): this lane 06:23:39; lanes that merge before it per ROADMAP order: n165 06:28:46, reconstruct 06:30:39, claim-data-safety 06:25:23, hook-correctness 06:27:51, ghost-tools 06:40:29. With F.30 (replay keeps `%aI`) and rule 12 (merge dated at the source tip) dev's first-parent goes back from 06:40:29 to 06:23:39 after pool 10. If the allocator was given `--requirement`, the pool's `[REQ]` commit (dated now, `scripts/allocate-pool-branch.sh:531-560`) also precedes work dated 06:23.
- Does a check break? No tool checks date order: `grep -rn -i 'monoton|backwards|%at|%ct|committer-date|ignore-date' githooks scripts bin ci` → only the claim scripts preserving `ORIG_*_DATE` (`claim-dev-merge.sh:218-219,286-288`, `claim-main-release.sh:148,236`) and `_lib.sh:1572-1584` reading `%cI` for the release-notes open-pools table. The only assertions are prose: F.31 (rebuild section) and the global loader's lesson "after any plumbing replay, assert that dates never go backwards" (`~/.claude/skills/how-git/SKILL.md:84`), which the in-repo loader did not carry over (R2-08b).
- Fix (a ruling, one sentence in commit-audit F and history-rewrite `:12`): either "the author date of an unpushed, never-shared commit of the current session may be re-stamped; the replay onto the pool stamps every commit at the replay instant (dev precedent n159-n164) so dev stays monotonic", or "a replay keeps `%aI` and a merge takes max(source tip, dev tip)". Until one is written, the orchestrator's replay violates whichever rule it does not pick.
- Test: a lifecycle assertion over `git log --first-parent --format=%at dev` after two sequential pool merges.

### R2-03 [LOW] Rule 10's diff check fails on web-authored PR bodies
- `skills/git-merge-audit/SKILL.md:94` `diff <(gh pr view <N> --json body -q .body) <(git log -1 --format=%b <merge> | sed '1,/^$/d')`.
- Evidence: git's `-F` cleanup drops `\r` (VERIFIED, scratch repo: body given with CRLF, `git log -1 --format=%b | od -c` shows `\n` only); GitHub returns `\r\n` for bodies typed in the web editor (UNVERIFIED here, no gh call). The two sides then differ on every line.
- Fix: `gh pr view ... | tr -d '\r'`.

### R2-04 [LOW] `bin/init-release` seeds the dev→main PR with a markdown header the rule now forbids
- `bin/init-release:202` `printf '## Summary\n\n%s\n'` from the CHANGELOG Unreleased section. Template comment: "No markdown headers"; rule 6 fails a header. Pool 8 backlog lists it; the skill does not. Fix: one clause in rule 10 ("`bin/init-release` still writes `## Summary`; pool 8").

### R2-05 [LOW] Commit atomicity
- 71413a6 bundles DL-01 (template, rule 10, lens, test) with DL-05b (rule 6 enumeration ban); d3bba4b bundles ruling 2 (git-snapshots) with ruling 6 (git-history-preservation). Both bodies state both concerns truthfully. Fix: split at the replay, or accept.

### R2-06 [INFO] DL-04 closure depends on merge order
- Skills name `_snapshot-scope.sh`, `content-match.sh`, `integration-check.sh`, `audit-pushed-branch.yml`, `dev-merge.yml`, `main-merge.yml` without a pool marker; `git ls-tree -r local/ghost-tools` has all six; MERGE-NOTES "take lean-skills' version" of git-shuttle is safe (every name it carries resolves there). Green on dev alone only because the test SKIPs.

### R2-07 [INFO] Cosmetic
- Lifecycle test label "PULL_REQUEST_TEMPLATE present + carries macro sections" now checks the shape, not sections. README `:97-99`, `:339` pre-existing (DL-09).

### R2-08 [LOW] Binding rules still without an in-repo home (inventory below)
- a) Global loader rows 70-71 and `:38`: "v4rian: amend only before the push that triggers the claim" and "never amends or force-pushes main after the claim has tagged". Tip: `grep -rn 'after the claim|amend only' skills/` → nothing; merge-audit 17 covers the tag race only.
- b) Global `:84` "after any plumbing replay, assert that dates never go backwards and that no commit is empty". Tip: F.31 "monotonic on the branch" sits in "F. Dates (rebuild commits)"; nothing binds a replay (see R2-02); "no empty commits" survives in the loader.
- c) Global `:85` pinned-SHA lesson (consumer pins after a library rewrite): rebuild guidance, acceptable loss.
- Fix: one clause in merge-audit 17 for a), one in F.31 or history-rewrite `:12` for b).

## PR template + rule 10 parity vs `claim-dev-merge.sh` (VERIFIED by reading, no gh run)

`claim-dev-merge.sh:222-256`: connected + `gh` present → `PR_NUM` from the `Merge pull request #N` subject or `gh pr list --head`; body = `gh pr view --json body`; on an empty fetch or no `PR_NUM` it falls back to the existing merge body (`:244,:250`) and, with no `PR_NUM`, prepends nothing (`:266`); the URL is added only when `OWNER_REPO` resolves (`:268-270`), else bare `PR #N`. Rule 10's statement (PR paragraph, blank, PR body verbatim) is right for the resolved case and silent on the two fallbacks (bare `PR #N`; no paragraph at all when the PR number cannot be resolved, where the `sed '1,/^$/d'` check would strip the macro paragraph instead). The PR body itself is not the author's text but the validator's rewrite (R2-01). Off-grid: body preserved (`:254`), rule 10's last sentence correct. Amend keeps author and dates (`:286-288`).

## Loader: rows vs the global decision tree, and bytes per row

Each row loads the right skills (checked row by row against `~/.claude/skills/how-git/SKILL.md:65-77`): commit → commit-audit; branch or hotfix → strategy-audit (global hotfix row folded in); merge to dev → merge-audit; release → merge-audit + runtime-audit (the global "em-dash scrub on `main..dev`" is the pre-commit scrub plus the push-range gate in `scripts/audits/commit-audit.sh`); rewrite → preservation + rewrite (preflight named); zips → snapshots with preflight first; folders → shuttle (tools ghost, R2-06); replay → reconcile-intent (new, correct); verify → matching audit; after a push → how-dev only with a CI (ruling 7); credentials → token-discovery; bootstrap → strategy + commit (global `how-new` is a workspace skill); adopt → tools. Loader 6,452 B against the 6,500 B test cap (48 B headroom). Every `bin/*` named exits 0 on `--help` (`create-pool-branch` only with `--no-jira`, as the row says).

Old baseline (VERIFIED at dev): loader 11,532 + 4 memories 3,754 + 13 git-* skills 147,364 + how-dev 5,636 + how-push 1,147 + how-preflight 4,070 + Git_Strategy 22,302 + RUNBOOK 49,222 = 245,027 B ≈ 61,256 tokens (4 B/token). New = loader 6,452 + the row's skills at 7dedd1c + each named `--help` as printed.

| Row | Bytes | ≈ tokens | Saving |
|---|---|---|---|
| Compose a commit | 18,739 | 4,684 | 92% |
| Create a working branch or hotfix | 19,265 | 4,816 | 92% |
| Merge a pool into dev | 23,413 | 5,853 | 90% |
| Release dev to main | 32,847 | 8,211 | 87% |
| Rewrite my own history | 21,439 | 5,359 | 91% |
| Rebuild from bak zips, orchestrator only / full chain (+10 sub-skills) | 15,355 / 96,343 | 3,838 / 24,085 | 94% / 61% |
| Rebuild from working-tree folders, orchestrator only / full chain (+8) | 19,324 / 85,325 | 4,831 / 21,331 | 92% / 65% |
| Replay or rebase across diverged history | 14,183 | 3,545 | 94% |
| Verify runtime (largest audit) | 20,948 | 5,237 | 91% |
| After a push | 14,275 | 3,568 | 94% |
| GitHub API call needing credentials | 11,460 | 2,865 | 95% |
| Bootstrap a new repo (new row) | 27,020 | 6,755 | 89% |
| Adopt or migrate the framework | 12,053 | 3,013 | 95% |

Round 1 → round 2 drift: +212 B loader, +586 B commit-audit, +116 B merge-audit; savings move by at most one point.

## Rule inventory diff, dev → 7dedd1c (V verbatim or tightened, R rephrased, E enforced by a named tool, M moved, X vanished)

- **git-commit-audit** (dev 43 + I + J + ritual → 37 + I + J). A1-3 V (folded) · A4 R · A5 R (ruling 2) · B6 V+ · B7 R · B8 R/E · B9 M→H.36 · B10 R/E · C11-13 V · C14 M→merge-audit · C15 R/E · C16 V (the "(as a title)" qualifier dropped: tighter) · C17 E · D18-27 V (V.10 recipes compressed) · E28-30 V · E31 R ("project still imports" X) · F32 R (ruling 8: both platforms, no ASK ONCE, no UTC-Z form) · F33-35 V · G36 R (ruling 2) · G37 V+ (branch words back, 20 commits, legacy → strategy-audit) · G38-39 V · H40 R (bin/version) · H41 M · H42 V · H43 R · I V+ · J R · ritual R (step "quote one bullet into the lens" X, minor). New A4 "plan the split before staging". Lost and binding: none.
- **git-merge-audit** (dev 1-17 + parity + lens → same + Legacy). 1 V · 2 V · 3 E ("sentence case" X, moot) · 4 V · 4a R (ruling 3) · 5 R (ruling 4, 1-5 → 1-3 sentences, tightened to the auto-fix cap) · 6 R (enumeration and method names back; `Adds:` colon headers X, superseded) · 7 V · 8 R (prose recap shape X, the contradiction) · 9 V · 8-10 V · 11-13 V · 14-16 V · 17 R (ghosts, pool 10) · parity 10 R (R2-01, R2-03) · lens R · retro V · Legacy new. Lost and binding: none.
- **git-shuttle** (dev 511 lines → 105). Principles 1-5 R (identity and dates derived, rulings 6 and 8) · Steps 1-7 R (every option and halt kept; `agi-call.mjs` path and `127.0.0.1:8094` X on purpose; "set default branch via workspace preference" X, minor; identity's four asked sources X by ruling 6) · A V · B R (tool, pool 10) · C V · C.5 V · D V · D.5 R · D.6 R (`[CLEANUP]` → `[REFACTOR]`, every cluster a branch, allocator names) · D.7 V (both platforms; LA zone X by ruling 8) · E R (`Changes:` always X by ruling 5; in-the-moment list V) · F R (nested list; claim or by-hand tag) · G V · output and state V · banned V · table V. Lost and binding: none.
- **Loader** (global 11,532 B → in-repo 6,452 B). Memories X (workspace) · read-all → one row R · model R · confirm line X (stated) · audits before ship R · receipts V · plan names every skill V · merge grant, no PR, parity R ("deliver meanwhile" X, guidance) · push each ref, ls-remote R (`--all` X, resolves the preflight contradiction) · one defect one pool V · no empty commits, FF main V · intro commit V · no invented Jira V · cherry-pick diff V · merge body V+ · hash compare V · trash R · sym9 grant R · allocator R (ls-remote workaround X, pool 1) · dash escape V (restored) · off-grid close-up R (tail → `bin/finalize-pool-merge`) · ceremony identity R · dirty-tree and `[REQ]` workarounds X (pools 4, 5) · legacy close-up X (workspace) · decision tree: bootstrap V (restored), hotfix folded, "amend only before the push that triggers the claim" X (R2-08a), em-dash scrub at release X (covered) · lessons: spec source → canonical paragraph, branch size V (restored), allocator numbering X (pool 1), merge dates V in merge-audit 12 but the replay assertion X (R2-08b), pinned SHAs X (R2-08c), "never amends or force-pushes main after the claim" X (R2-08a).

## Commit hygiene (26 commits, VERIFIED)

Titles 8-72 chars (none over 72), tags `[DOCS]` `[REFACTOR]` `[NEW]` `[TEST]`, bodies 1-3 sentences, no em/en dash or `Co-Authored-By`, author and committer `v4rian-waylon (Opus) <v4rian-waylon@users.noreply.github.com>` on all 26, dates 06:23:35 → 06:23:39 monotonic with author == committer (R2-02 on how they got there). Body claims re-checked: 71413a6 "1 passed now, 0 passed with the old file" (mutation a) ✓; d3bba4b "finds only the git-strategy-audit line" ✓ (`skills/git-strategy-audit/SKILL.md:152`; the `git-reconcile-intent:53` "straight to a comment" hit is unrelated); e63888e post-checkout warns / pre-push exit 1 ✓; 68ec79c BSD branch run, GNU unverified, stated ✓. Atomicity: R2-05.

## Verdict

FIX-THEN-MERGE. No gate, hook or data-loss path is touched (docs, template and one test). Two mediums: R2-01 (rule 5/10 still claims a PR shape the validator rewrites: tag prefix, signature trailer, list flattening until pool 5) and R2-02 (the date reset contradicts the branch's own "replay keeps the author date" rule; no ruling for the replay's dates, dev goes backwards after pool 10 under rule 12). Both are one- or two-sentence text fixes plus a ruling; R2-06 needs pool 10 merged first or a "(pool 10)" marker.
