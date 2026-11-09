# neo-git roadmap (pools in merge order; ≤20 commits each)

Inputs: DECISIONS.md (Joel's rulings), how-git-requests-ledger.md (R/P/C ids), audit-pending-branches.md (Fable findings on the September work), audit PDF shuttle.o/artifacts/how-git/how-git-token-audit-2026-10-29.pdf.

Every pool: allocator-created pool/safety pair, ≥2 atomic commits + closing [DOCS] commit, failing test first where a defect is fixed, framework-tests green, Fable diff-only adversarial audit clean, benchmark no regression, then --no-ff merge to dev with the off-grid claim (grant: feedback_neo_git_merge_dev_preauthorized).

| # | Pool | Content |
|---|---|---|
| 1 | n165.fix.off-grid-allocator-ignores-clone-refs (exists) | September allocator fix + every Fable finding on it (R02). |
| 2 | feature.reconstruct-tool | bin/reconstruct + git-reconstruct skill (983ca80) + every Fable finding on it. |
| 3 | feature.benchmark-harness | Headless Opus 5.5 / Fable 5.1 task suite, how-git 5028b58 baseline vs neo-git HEAD; tokens, turns, gate violations, data-loss checks, readability review. Runs again after every later pool. |
| 4 | fix.claim-data-safety | R01 dry-run/plain claim resets dev, R03 tag without dev push, R05 bash 3.2 empty ARGS, R06 sort-order exit, R20 hooks-off warning, R21 mktemp traps, dirty-tree claim (audit change 10), R19 tag holes. |
| 5 | fix.hook-correctness | R09 shared branch regex in _lib.sh, R08 list body flattening, R12 detached HEAD, R13 active-requirement collisions, R17 opt-out, R18 dash scrub in code, R10 attach/sync through consumer hooks, R07 FRAMEWORK_REPO marker, R04 tokenized URL in SPEC, R11 SPEC ref stamp + doctor check. |
| 6 | feature.identity-and-time-from-source | Ruling 6 identity from origin org (hooks refuse wrong identity, Joel identity for his snapshot rebuilds); ruling 8 source offset kept, UTC Z names. |
| 7 | feature.merge-policy-and-warp-mode | Per-project merge policy (stricter or looser: who/when may merge to dev, PR or not, approval required) + warp-mode flip that allows direct merges to dev without PRs while on. |
| 8 | feature.merge-body-in-hook | Ruling 4 (after confirming real contradiction vs per-situation shapes), commit-msg audit enforces it; R23 PR/merge body parity; R22 bin/reject-pr. |
| 9 | feature.self-documenting-tools | bin/* --help as the agent-facing reference (replaces RUNBOOK/strategy reads); compile/runtime recipes into required.* gate help. |
| 10 | feature.ghost-tools-and-workflows | Rulings 9-10: tools/content-match.sh, tools/integration-check.sh, audit-pushed-branch.yml, dev-merge.yml, main-merge.yml, build-on-tag.yml (working, tested). |
| 11 | refactor.resolve-spec-contradictions | Rulings 1-8 text across skills/docs, R14a-g, R15, R16, ruling 7 CI-watch binding only when a CI (local or remote) is connected. |
| 12 | refactor.lean-skills | Trim git-commit-audit (12.7→~6 KB) and git-shuttle (42→~12 KB), prune 41 dead memory links and STATUS paragraphs, drop prose a hook enforces. |
| 13 | feature.lazy-loader | In-repo lean loader (~5.5 KB) loading only the decision-tree row's skills; global ~/.claude loader untouched until promotion. |
| 14 | feature.consistency-lint | Lint over skills, docs, loader and every copy (fractaris, vendored): contradictions, dead links, missing tools/workflows, drift vs canonical; wired into pre-commit/CI. Ruling 1 fractaris 97-line review. |
| 15 | feature.deterministic-replacements | Every remaining AI-judged step that a script can do at the same quality (inventory from the benchmark + audit), replaced and proven equal. |
| 16 | feature.safety-gc-and-pool-sync | R24 scheduled GC of released safety anchors (bundle to trash, never hard delete), R25 rebase sweep for unpushed pools. |
| 17 | r&d.jev-evaluation | At the very end: identify "jev" (or the closest free open-source equivalent), benchmark it against neo-git for speed and tokens, accounts via kai with waylon / v4rian identities. |
| 18 | fix.friction-points (one or more pools) | Final step (Joel, 2026-10-29): run the `friction` skill (~/.claude/skills/friction, being built; not ready while SKILL.md is absent) over shuttle.i/history (2.0 GB, claude-env-freeze-2026-10-26 zip) to find every how-git friction point; attest each, reproduce it in the test suite, fix it for good. If the skill is not ready when pools 1-17 are done, monitor until it is. After every friction point is fully identified and attested (ledger written), permanently delete <workspace>/shuttle.i/history (no trash; Joel's explicit instruction 2026-10-29, overriding the never-delete-under-shuttle rule for this exact path only). |

P1-P3 (docs|test kinds, JIRA/API integration, bootstrap-offgrid) and C1-C2 are triaged inside pools 5, 9 and 11 once their status is confirmed.

## Backlog found during implementation (folded into the named pool)
- Allocator kind lists still hardcoded; move to the shared regex in _lib.sh (pool 14 consistency-lint, after n165 and hook-correctness land).
- scripts/workflows/doc-freshness-check.sh bash 3.2 empty-array crash (pool 10 ghost-tools-and-workflows).
- Flaky lifecycle test "version math across release cycles" fails 3/5 on dev 5028b58 (root cause from the claim-data-safety audit; fix in that pool before merge).
- R13 merge driver ignored by GitHub server-side merges; pre-push re-checks messages only on working-branch pushes; [REQ] bodies exempt from message rules (judge in pool 8 merge-body-in-hook).
- Baseline benchmark (how-git 5028b58, 36 runs, $63.76): Fable e-rewrite "authors-kept" fails 3/3 - when fixing a message it re-stamps the author as "v4rian-waylon (Fable 5.1)": how-dev's author-name-stamps-the-model rule vs git-history-rewrite's preserve-author rule are ambiguous for a rewrite of an existing commit. Resolve in pool 11 (rule: a rewrite preserves the original author; the committer carries the rewriting model) and enforce in a tool/hook (pool 6). merge-body-nested-list fails on both models (5/6 merge runs): the rule is unclear in the skills (pool 8/11). Opus c-merge-dev and d-ship miss --no-ff/title spec 1/3 each.
- Lifecycle suite is not parallel-safe: three concurrent runs gave 2-4 failures per run in unrelated tests (claim CLIs, version math, audit-retry), all green alone. Shared temp/state path collision; fix in pool 15 (or earlier) so suites can run concurrently.
- bench arm neo-git.conf points at a nonexistent loader path and silently falls back to baseline: make the harness refuse a missing loader; neo arm = .io.v4rian.how-git/skills/how-git/SKILL.md (bench pool fix before its merge).
- Stale text: bin/ship mentions the claim-on-merge-main workflow; README skills tree lists a nonexistent how-push skill; bin/create-pool-branch --help fails without --no-jira (pool 9).
- ~/.claude/hooks/skill-lint.sh points FW at fractaris (pool 14).
- bash 3.2 empty-array expansions: ~30 sites outside the claim pool still crash under set -u with an empty array (sweep with a lint rule + tests; own pool fix.bash32-empty-array-sweep, after test-isolation).
- bin/init-release still writes "## Summary" into the dev->main PR body (pool 8); gh-mock test of the claim's PR-reference amend step (pool 8).
- Lean loader is 6,452 B against a 6,500 B test cap: any new loader rule must replace one (pool 13 follow-ups).
- Linked worktrees: hook-driven claim refuses inside a linked worktree (git exports GIT_DIR; `git -C "$SCRIPT_DIR" rev-parse --show-toplevel` resolves to the scripts dir); 15 scripts share the pattern (own pool fix.linked-worktree-support; audit-claim-data-safety-r2.md G2).
- No gate on merge-commit messages (hook-correctness r3 R3-09): pool 8 adds the merge-message gate.
- validate-pr-open auto_fix mangles connected-mode PR bodies (prepends tag, flattens list, appends signature) so merge bodies trip the shape lens: pool 8.
- Skill instructions use fixed /tmp paths (/tmp/zip<N>, /tmp/compile, /tmp/pf-check in git-snapshots, git-compile-audit, git-coverage-audit): switch to mktemp under TMPDIR after the docs lanes land (pool 14 lint rule forbids fixed /tmp in skills).
- Prior fix rounds ended by Joel (2026-10-30, "use what we have"); tips final: claim 67718fd, hook 8017883, reconstruct eb05224, lazy-loader 5045cdf. Unverified at end: claim and hook final suites (agents stopped mid-run), test-isolation Fable audit unfinished, reconstruct round-3 lows status, docs round-2 author-date restore status. Integration branch suites are the check.
- Test flake: `echo ... | grep -q` under pipefail gets SIGPIPE under load and fails tests (robustness agent); sweep the suites to capture-then-grep (follow-up after landing).
- identity-time leftovers: R14g skills text (git-history-rewrite, git-snapshot-preflight still say git config); git-preflight.sh zip names lack Z (outside repo); _lib.sh org identity overrides the CI bot identity in connected CI (verify/guard); identity gate checks email only.
- Flake: "e2e: inherit + PR-open is idempotent" log file vanished mid-run under concurrency (test-isolation incomplete for that test).
- jev evaluation: commit-msg hooks caught 15/61 seeded message violations vs commitlint/gitlint 61/61 → port gitlint-equivalent deterministic rules into commit-msg (adopt); use `git rebase --update-refs` for stack rebases (adopt); pilot git-absorb for fixup folding.
- merge-policy leftovers: connected-mode PR merges only announce who-may-merge/approval (not enforced server-side); warp not written into the server dev ruleset; attach does not reset WARP when vendoring.
- Pool numbers jumped n166 → n1001 on landing: inherited live-proof fixture tag v2026.120.0 ("[MERGE] pool/v2026.0/n1000.fix.vault-proof-a") counts as a spent n1000 under the n165 rule (count landings reachable from every tag). Spec-correct but surprising; decide whether fixture tags outside the current claim series (v2026.120.x-v2026.122.x) should be excluded from the counter, without rewriting published tags.
- bench finding (Opus neo-git d-ship): bin/ship stamps the release merge with the run time, not dev tip committer date as the merge-date rule requires; fix in a pool with a failing test.
- bench finding (both arms, e-rewrite): required.coverage.sh exits 2 on a repo with no recognised project type (should report N/A, not fail).
- bench finding (Opus neo-git f-snapshots): pre-push rejects preflight-bak-* branch names, so the git-shuttle preflight backups cannot reach origin without --no-verify; allow the preflight-bak-YYYY-MM-DD/NN shape (and the date-only form the skill wrote) in the branch-name gate, or align the skill with the hook.
- bench finding (Opus neo-git c-merge-dev): `bin/ci-local --trigger pr-merge-dev` runs the claim script as a "pre-merge check"; it should be dry-run by default or its --help/loader must say it claims.
- bench finding (Fable how-git e-rewrite): ~/.claude/hooks/git-preflight.sh stamps its backup commit with the ambient identity, ignoring the exported GIT_AUTHOR_*/COMMITTER_* (outside repo; fix in the hook).
