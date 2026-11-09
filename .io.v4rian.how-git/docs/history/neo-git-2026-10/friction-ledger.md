# how-git friction ledger

Generated 2026-10-29 by the `friction` skill, scoped to how-git. This is a read-only audit: nothing was changed in any repo, hook or memory. Root-cause paths are in neo-git `dev` 5028b58 (NS = `.io.v4rian.how-git/`) unless they start with `~/.claude/`. Cost figures are estimates from logged usage and counts, not measured spend.

## Sources and coverage
- The freeze named in the brief: `shuttle.i/history/` holds only the RESTORE.md, the MANIFEST and the `-agi-calls` supplement (57 KB). The 2.0 GB `claude-env-freeze-2026-10-26.zip` listed in the MANIFEST (sha `b704cac2…`) is **not in that folder**. The only freeze zip on disk is `shuttle.o/artifacts/claude-env-freeze-2026-10-26.zip`: 23 MB, sha `951986f2…`, which matches no MANIFEST line. It is the "pre ai-reaudit" freeze and holds 25 transcripts (5 sessions, Oct 26-27). It was extracted read-only to `$TMPDIR/freeze-Jyq8/` and both originals are unchanged. **The orchestrator should confirm where the 2.0 GB zip went before deleting `shuttle.i/history`.** The supplement holds ag.i voice calls from May 2026, which have no how-git content.
- Live transcripts: `~/.claude/projects/*/` covers 429 files, 839 MB, 169 sessions and 30,505 tool calls (Oct 26-29 2026; older transcripts were already pruned by the CLI).
- Tools used: `friction-extract.mjs run all --include-throwaway --no-ledger-filter` (591 live candidates, 17 freeze candidates), plus a how-git marker scan (`scratchpad/scripts/hg_scan.py`, 30 markers over tool results and Bash commands). Test-suite output, reads and greps were filtered out, then the hits were judged by hand. This audit's own subagent transcript is excluded.
- Fix status was checked against the `local/*` branches in `<workspace>/neo-git` and against ROADMAP.md, how-git-requests-ledger.md (R ids) and audit-*.md.

## Counts
- 22 friction points: **9 unfixed** (none of them on any branch), 7 fixed on an unmerged `local/*` branch, 6 partial.
- 7 of the 22 have their root cause outside neo-git, in `~/.claude/hooks/` or in skills. neo-git cannot fix those alone.
- Raw volumes:
  - 54 distinct preflight-guard denials (88 hits).
  - 151 spawned `claude -p` preflight audits.
  - 1,040 Bash calls re-exporting the git identity.
  - 129 false post-checkout warnings.
  - 27 conflicts on `active-requirement`.
  - 3 repos that halted on the set-mode admin gate.
  - 33 full how-git loader injections (342 KB).

## Ranked by cost

### FP-01 A full pool landed as one 189-commit branch, and atomicity was reported as broken
- Evidence:
  - `f9e94080…jsonl:11374` (2026-10-28T04:56) Joel: "i was clear about atomicity, ofc 1 commit of 200 files is not atomic fix!"
  - `:12515` (06:11) "ensure that how-git latest dev spec is respected fully and rebuild WHATEVER…"
  - `:13438` (10:10) "i hope 200 commits do not end up in 1 fucking branch no matter how atomic the commits are".
- Frequency: 1 incident, 3 corrections from Joel.
- Cost: about $292 rejected work plus $83 redo, about 12 h of machine time and about 4 h waiting for Joel (extractor `cb617af623`, `4957daeee4`).
- Root cause:
  - No tool refuses an oversize pool. `NS/githooks/pre-push:24-38` checks only the branch name.
  - The atomicity smell test is a prepare-commit-msg heuristic (`NS/scripts/lib/auto-fix-commit-message.sh:397-398`, 5 or more top-level dirs). A multi-paragraph body that names each dir bypasses it (`:400-417`).
  - The pool-size rule lives only in memory (`feedback_pool_branch_size.md`).
- Fixed? **No.** No `local/*` branch adds a pool-size gate. ROADMAP has no pool for it; the earlier friction report (H4) proposed one.
- Repro: off-grid sandbox, allocate a pool, make 30 commits, `git push origin pool/...`. Expect the push to be refused at more than 25 commits (or a configured cap). Today it exits 0. Second case: commit 200 files across 6 dirs with a 2-paragraph body naming all 6. Expect a refusal; today it bypasses.

### FP-02 The preflight guard blocks routine how-git close-up and scratch-clone work
- Evidence: 54 distinct denials in 8 sessions. By operation: 21 `branch -D`, 11 rebase, 10 `reset --hard`, 3 `checkout -f`, 3 `update-ref -d`, 3 force push, 2 stash drop, 1 clean. By shape:
  - 16 in throwaway clones under `/private/tmp` or the scratchpad, e.g. `8a4f5276/agent-a6c711e2…:57` `scratchpad/wt-n100 … git branch -D`.
  - 14 where a variable path did not resolve: "`$W is not inside a git repo`" at `8a4f5276/agent-a4a17fd3…:3009`, and `source env.sh; git reset` at `f9e94080/agent-a60217d0…:275`.
  - 8 in sibling worktrees of an already preflighted repo (`helpen-v3/merge-ms`, `ms-disc`, `wa-disc`).
  - 3 where the preflight was chained in the same call and still denied, because the hook evaluates before the command runs: `f9e94080:7123`, `8a4f5276/agent-a6e5f11a…:438`.
  - The usual cleanup step after vaulting a merged pool (dropping the local pool/safety pair) is a `branch -D`, so every close-up pays a preflight.
- Cost: each denial costs a retry (≈$0.02-0.2) plus a full preflight (push and zip). About 54 extra round trips, about 40 min of machine time.
- Root cause:
  - `~/.claude/hooks/guard-destructive.sh:137-153` has no temp-root exemption for local-only git.
  - The zip lookup is keyed on the worktree basename (`:143,150`), not the main repo.
  - A command string containing `git-preflight.sh` before the destructive op is not honoured.
  - neo-git has no counterpart, and the vault step's local `branch -D` is not exempted.
- Fixed? **No.** No neo-git branch touches it (the rule lives in `~/.claude/hooks`). `local/reconstruct` only calls the machine hook from `bin/reconstruct`.
- Repro (hook unit test, stdin JSON):
  1. `{"tool_input":{"command":"cd /private/tmp/x && git branch -D foo"}}` on a temp git repo. Expect allow; today deny.
  2. `~/.claude/hooks/git-preflight.sh /repo r && git -C /repo reset --hard HEAD`. Expect allow; today deny.
  3. A linked worktree of a repo with a fresh preflight. Expect allow; today deny.

### FP-03 Preflight zips flood the disk (217 backups, ENOSPC mid rewrite)
- Evidence:
  - `f9e94080…jsonl:12836` (2026-10-28T07:08), subagent: "Disk on / is at 0 bytes again … I am mid history rewrite (rebase stopped …)".
  - `:16223` Joel: "prune YOUR preflight zips and ask working agents to acknoledge theirs".
  - `:16324`: "keeps none of the 217 backups". `baks/` is 3.3 GB today.
- Frequency: 2 disk-full stalls, plus 1 cross-session prune ceremony.
- Cost: hours of stalled agents and a manual prune round. Not quantified in USD.
- Root cause:
  - `~/.claude/hooks/git-preflight.sh:33-36` zips the full working tree on every call, plus a mirror copy, with no dedupe, no GC and no exemption for temp clones.
  - Together with FP-02 this forces a zip per worktree and per throwaway clone.
- Fixed? **No.** ROADMAP pool 16 (`local/robustness` `bin/gc-safety`) collects safety refs, not bak zips.
- Repro: run `git-preflight.sh` 3 times in 1 min on an unchanged repo. Expect 1 zip (content-hash dedupe) and 0 for a repo under `$TMPDIR`. Today it makes 3 zips and 3 mirror copies.

### FP-04 The framework-repo post-checkout hook spawns a `claude -p` session on every checkout, and it fails open
- Evidence:
  - 151 headless sessions on 2026-10-29 (11:22 to 20:47). All have the prompt "Audit the current git state against the rules in …/git-snapshot-preflight/SKILL.md. Context: post-checkout firing on branch=…".
  - 105 ran in `$TMPDIR/aud-*` audit clones and 46 in `.neo-git-work/wt-*`.
  - Every one answered "Not logged in · Please run /login" (e.g. `~/.claude/projects/<workspace-slug>--neo-git-work-wt-lazy-loader/*.jsonl`), and the hook printed "✓ git-snapshot-preflight passed".
- Cost:
  - Today: 151 CLI cold starts (about 1-3 s each) and 151 junk project dirs.
  - Once logged in, about 151 full sessions carrying CLAUDE.md context, roughly $50-100 a day at this rate.
  - The audit result is meaningless either way.
- Root cause:
  - `NS/githooks/post-checkout:40-64` runs `claude_skill_run` whenever `FRAMEWORK_REPO` exists.
  - `NS/scripts/_lib.sh:198-206` treats any output without `^AUDIT_FAIL` as a pass, so a login error passes.
- Fixed? **Partial.** `local/hook-correctness` exits on detached HEAD, which covers the 124 `branch=HEAD` runs. Named-branch checkouts still spawn, and the fail-open parse is not fixed anywhere.
- Repro: in a FRAMEWORK_REPO clone with a stub `claude` on PATH that prints "Not logged in", run `git checkout -b local/x`. Expect "skipped / FAIL: claude unavailable" and no pass line. Today it prints "✓ … passed". Second case: assert that the stub was not invoked on `git worktree add`.

### FP-05 The identity ceremony is re-typed on every git command (1,040 times)
- Evidence: 1,040 Bash calls in 94 transcripts carry `export GIT_AUTHOR_NAME="v4rian-waylon (Opus)" GIT_AUTHOR_EMAIL=… GIT_COMMITTER_NAME=… GIT_COMMITTER_EMAIL=…`, e.g. `8a4f5276/agent-a98751ce…:159`. That is about 205k chars of emitted command text, re-read in context afterwards. Earlier misses: 13 preflight commits made with the wrong identity (friction report F-22).
- Cost: about 50k output tokens of boilerplate, plus context re-reads, roughly $5-15. A wrong-identity commit cannot be repaired without a rewrite (rule 11).
- Root cause:
  - how-dev (`~/.claude/skills/how-dev/SKILL.md:34`) requires per-commit env stamping.
  - Nothing in NS derives the identity, and the hooks do not refuse a wrong one.
  - `~/.claude/hooks/git-preflight.sh:26` runs `commit-tree` with the global identity.
- Fixed? **Partial.** `local/identity-time` adds `bin/identity`, exports the identity in scripts that source `_lib.sh`, and refuses wrong-identity commits and pushes. Agents still have to export the variables for plain `git commit`, and git-preflight.sh is untouched.
- Repro: a repo with origin `github.com/v4rian-io/x`, global user `waylon-sp`, and a plain `git commit -m "[FIX] x"` with no env. Expect either an auto-applied `v4rian-waylon` identity or a refusal naming the fix. Run `git-preflight.sh` there and expect the preflight commit author to be v4rian-waylon.

### FP-06 set-mode needs a GitHub admin, which halts every new repo's off-grid flip
- Evidence:
  - `f9e94080…jsonl:298` (2026-10-27T11:46) "X set-mode: actor 'v4rian-waylon' has permission 'write' on v4rian-io/staqs but admin is required". The agent asked Joel (`:458`), who answered: "the repo is not even initialized you dont need to set up anything remotely read the spec there are ways and dont ask me anything again".
  - Freeze `b726fa34…jsonl:1603`: the same halt on fractaris ("is maintain enough").
  - `.neo-git-work/STATE.md`: neo-git itself is still connected for the same reason.
- Frequency: 3 repos, 2 questions to Joel, 1 angry correction.
- Cost: 2 halts, each a context switch for Joel. neo-git is still not off-grid.
- Root cause:
  - The template ships `NS/MODE` = `connected`.
  - `NS/bin/set-mode:66-83` requires admin whenever an origin exists, even for a repo with no pushed history or no remote rules.
- Fixed? **No.** `local/merge-policy` only moves the gate into `_lib.sh`.
- Repro: create a repo from the template, add origin, use a gh stub that reports permission `write`, and run `bin/set-mode off-grid`. Expect success, or a documented `--bootstrap` path when origin has no dev/main yet. Today it exits non-zero.

### FP-07 Every parallel lane conflicts on `active-requirement`
- Evidence: 27 real conflicts in 3 sessions, e.g.:
  - `8a4f5276/agent-a98751ce…:198`: "CONFLICT (content): Merge conflict in .io.v4rian.how-git/active-requirement … could not apply ea633ca... [REQ]".
  - `8a4f5276/agent-a457231a…:1236`: n94 and n95 merges.
- Cost: about 27 manual resolutions and rebase restarts, roughly 30-60 min of agent time.
- Root cause: `NS/scripts/allocate-pool-branch.sh:531-613` writes one shared file per pool (R13).
- Fixed? **Yes, on branch.** `local/hook-correctness` uses per-lane requirement files (6a71a49).
- Repro: allocate 2 pools with `--requirement`, merge the first to dev, then merge or rebase the second. Expect no conflict.

### FP-08 post-checkout warns on every valid allocator branch
- Evidence: 129 real occurrences in 8 sessions of "doesn't match the v4rian format … the remote will reject it on push" on `pool/v2026.0/nN…` names, e.g. `8a4f5276/agent-a7b76748…:453`.
- Cost: noise in 129 tool outputs (about 3k tokens). Agents learn to filter it with `grep -v "doesn't match\|Expected\|OK for"` (`8a4f5276/agent-a4a17fd3…:3009`), which also hides real warnings.
- Root cause: `NS/githooks/post-checkout:25` has no `(v[0-9]{4}\.[0-9]+/)?` (R09).
- Fixed? **Yes, on branch.** `local/hook-correctness` (7cab2e8) uses the shared `HG_BRANCH_RE`.
- Repro: `git checkout -b pool/v2026.0/n3.fix.x`. Expect no warning.

### FP-09 Merge commits hit the atomicity gate and leave the claim with a dirty tree
- Evidence:
  - 8 real refusals in 2 sessions, e.g. `8a4f5276/agent-a073d74a…:1911`: "atomicity gate: multi-paragraph bypass declined … X commit-msg auto-fix cannot reconcile this commit. | [MERGE] pool/v2026.0/n109… into dev | ✗ working tree dirty - commit or stash before claiming".
  - Also `:1809`, `agent-a7b76748…:2115`, `agent-a7ca390d…:1101`.
- Cost: about 8 aborted merges, each re-run with a rewritten body (about $1-3 each).
- Root cause: `git merge --no-ff -F file` reaches `prepare-commit-msg` with source `message`, not `merge` (`NS/githooks/prepare-commit-msg:32-37`), so `audit_message` applies the 5-dir gate (`auto-fix-commit-message.sh:397-424`) to `[MERGE]` subjects.
- Fixed? **Yes, on branch.** `local/hook-correctness` sends `[MERGE]` subjects through the dash scrub only (R08 79f881e). It still needs a regression test for this exact `-F` merge plus 5-dir case.
- Repro: on dev, `git merge --no-ff pool/x -F msg` where pool/x touches 5 top-level dirs and msg is `[MERGE] pool/x into dev: v…` with a one-paragraph body. Expect the merge to commit.

### FP-10 finalize-pool-merge "fails harmlessly", and memories now teach agents to ignore it
- Evidence:
  - FR:218-262 and FR:431-441 ("line 169: ARGS[@]: unbound variable").
  - The workaround is now standing doctrine: freeze `b726fa34/agent-a944ffcc…:107` memory "finalize-pool-merge then fails harmlessly", and helpen DEV-MANUAL lines read at `8a4f5276/agent-a457231a…:35` and `agent-a98751ce…:42`.
- Frequency: 5 real failures, plus every agent reading the workaround.
- Cost: a red exit after a successful claim. Agents are trained to ignore real failures.
- Root cause: `NS/bin/finalize-pool-merge:141-144,164-169` (R05, R06).
- Fixed? **Yes, on branch.** `local/claim-data-safety` (f237f64, f88129c). The memory and DEV-MANUAL text must be deleted when it merges, or the doctrine outlives the bug.
- Repro: run `/bin/bash` 3.2 `bin/finalize-pool-merge` with no flags after an off-grid merge (the test already exists on the branch). Add a lint that greps memories and DEV-MANUALs for "fails harmlessly".

### FP-11 The off-grid allocator reissued spent numbers (misnumbered pairs had to be dropped)
- Evidence:
  - `8a4f5276/agent-a6e5f11a…:438` (2026-10-28T06:19): "drop misnumbered local pool pair" `update-ref -d refs/heads/pool/v2026.0/n1.fix.payout-disconnect`, which was also denied by FP-02.
  - FR:461-463 (n1 again, n61 duplicated).
- Frequency: at least 2 repos.
- Cost: a rename or rewrite of each misnumbered lane, plus a preflight.
- Root cause: `NS/scripts/allocate-pool-branch.sh:230-243,371-385` (R02).
- Fixed? **Yes, on branch.** `local/n165-fixes` (reservations, fetch watchdog).
- Repro: a fresh clone with remote-tracking `pool/v2026.0/n5…` only. `create-pool-branch` must hand out n6, not n1. Two concurrent allocations must give distinct numbers.

### FP-12 The claim cannot run while dev is checked out in another worktree
- Evidence:
  - `8a4f5276/agent-a4a17fd3…:3397`: "fatal: 'dev' is already used by worktree at …/helpen.wa-n97".
  - `0d08187b…jsonl:657`, the same on helpen.ms.
  - `.neo-git-work/ROADMAP.md` backlog: "hook-driven claim refuses inside a linked worktree … 15 scripts share the pattern".
- Frequency: 2 or more sessions; it is the standard setup for parallel lanes.
- Cost: agents create extra merge clones (`merge-ms`, `merge-wa2`, …), and each one needs its own preflight (FP-02, FP-03).
- Root cause:
  - `NS/scripts/claim-dev-merge.sh:107` (`git checkout -q -B dev FETCH_HEAD`).
  - Scripts resolve the root with `git -C "$SCRIPT_DIR"`.
- Fixed? **Partial.** `local/robustness` resolves the repo root from the caller's linked worktree. Nothing lets a claim run while dev is checked out in another worktree.
- Repro: main checkout on dev, plus `git worktree add ../wt pool/x`. Merge pool/x to dev from a second linked worktree created with `--detach` and claim it. Expect success.

### FP-13 Merging and claiming the protocol takes too many judgment steps (benchmark)
- Evidence: ROADMAP backlog, baseline benchmark on how-git 5028b58 (36 runs, $63.76):
  - Fable re-stamped the author on a rewrite in 3 of 3 runs.
  - The merge-body nested list failed in 5 of 6 merge runs on both models.
  - Opus missed `--no-ff` or the title spec in 1 of 3 runs.
- Cost: $63.76 benchmark; the failures recur in every real merge.
- Root cause:
  - The rules are prose: R14a (`NS/skills/git-merge-audit/SKILL.md:28,140` vs `:29-43`).
  - Rewrite author rules conflict: how-dev:34 vs git-history-rewrite.
  - No merge-message gate (R3-09).
- Fixed? **Partial.**
  - Done on branches: the `local/spec-contradictions` docs, `local/identity-time` (refuses a moved rewrite author), and `local/merge-body` (tests only).
  - Not done: the merge-message gate in a hook (pool 8). The benchmark has not been rerun on the fixes.
- Repro: the benchmark tasks c-merge-dev, e-rewrite and d-ship (`local/bench-harness`) must pass 3 of 3 on both models.

### FP-14 The how-git loader is heavy and loaded in full each time
- Evidence: 33 Skill(how-git) injections, 342 KB in total (about 85k tokens), plus follow-on reads of RUNBOOK and skills. The loader is 11.5 KB (`~/.claude/skills/how-git/SKILL.md`).
- Cost: about 85k input tokens per batch of 33, plus re-reads, roughly $5-10.
- Root cause: global loader `~/.claude/skills/how-git/SKILL.md` and git-commit-audit (12.7 KB) / git-shuttle (42 KB).
- Fixed? **Partial.** `local/lean-skills` and `local/lazy-loader` trim them and add a 6.4 KB in-repo loader. The global loader is untouched until promotion (ROADMAP 13).
- Repro: a test that asserts the global loader is no larger than 6.5 KB and that every skill it names exists (the lint on `local/lint` covers only the in-repo copy).

### FP-15 git add -A is used by tools and tried by agents
- Evidence: 10 hook denials, e.g. `f9e94080…jsonl:1537` "git add -A --dry-run ." (a read-only dry run, still denied). `~/.claude/hooks/git-preflight.sh:23` itself uses `git add -A` under a temp index.
- Cost: about 10 retries, a few cents each.
- Root cause: the `~/.claude/hooks/guard-destructive.sh:114` regex catches `--dry-run` and `-N` forms, and no tool exists for "stage the intended set".
- Fixed? **No** (the hook is outside neo-git). `bin/smart-commit` stages by name, but agents do not use it (29 calls against 1,040 manual commits).
- Repro: guard stdin `git add -A --dry-run .`. Expect allow.

### FP-16 Direct push to main tried on a fresh repo bootstrap
- Evidence: `36408b6e…jsonl:328` (2026-10-29T09:26) govee-syncbox-switch: "Push to main blocked … Offending: git push -q origin main".
- Frequency: 2 denials (plus fixture runs).
- Root cause: the template and how-new bootstrap has no tool that seeds main and dev on a new origin. The agent hand-rolls it. Only the guard (`~/.claude/hooks/guard-destructive.sh:121`) catches it.
- Fixed? **No.** `bin/bootstrap-offgrid` is missing (P3).
- Repro: an empty bare origin plus a template copy. `bin/bootstrap-offgrid` (to be added) must publish main and dev without a raw `git push origin main`.

### FP-17 Lease pushes bounce with "stale info" when pushing through a one-off auth URL
- Evidence: `f9e94080/agent-a14ff7be…:766` (2026-10-29T03:07): "! [rejected] pool/v2026.0/n126… (stale info)" for both pool and safety. The agents' memory (`feedback_force_with_lease…`) now documents the workaround.
- Frequency: 7 real rejections in 2 sessions.
- Root cause: GCM tokens are injected by URL (`git push https://…@github.com/…`), so remote-tracking refs never update. No NS tool pushes with an explicit `--force-with-lease=<ref>:<sha>` from `ls-remote`.
- Fixed? **No.**
- Repro: push with a URL instead of a remote name after a remote update, using `--force-with-lease`. A `bin/push-pool` tool (to be added) must fetch the lease SHA and succeed.

### FP-18 The lifecycle suite is flaky and not parallel-safe
- Evidence: the "version math across release cycles" test failed 3 of 5 runs on dev. Concurrent runs gave 2-4 unrelated failures (ROADMAP backlog). 47 marker hits during the neo-git sprint (`e38c8e77` subagents).
- Cost: re-runs and false reds in every pool gate, roughly 30+ min.
- Root cause:
  - `NS/bin/version` fallback ordering (claim-data-safety F0).
  - Shared temp paths in `NS/framework-tests/test-lifecycle.sh`.
- Fixed? **Yes, on branch.** `local/claim-data-safety` F0 and `local/test-isolation`.
- Repro: run `test-lifecycle.sh` 3 times concurrently. Expect 0 failures.

### FP-19 A dry-run claim and a plain claim reset local dev (data loss)
- Evidence: FR:266-353, HP pitfalls 5 and 21 (R01). Same class of loss as the `v2026.0.0` mis-tag.
- Root cause: `NS/scripts/claim-dev-merge.sh:99-108` comes before `:192`.
- Fixed? **Yes, on branch.** `local/claim-data-safety` (7e6c4bb).
- Repro: an unpushed off-grid merge, then `claim-dev-merge.sh --dry-run`. Local dev must keep the merge.

### FP-20 Tokenized remote URL stamped into SPEC
- Evidence: FR:115-131 (R04).
- Root cause: `NS/scripts/attach.sh:142-143,264-265`.
- Fixed? **Yes, on branch.** `local/hook-correctness` (d521cd6).
- Repro: attach from a source with origin `https://u:tok@github.com/o/r`. SPEC must not contain `tok`.

### FP-21 The prepare-commit-msg auto-fix rewrites content with no opt-out
- Evidence:
  - 6 real dash-scrub rewrites in 2 sessions.
  - HP pitfalls 9, 10 and 25 ("plus" becomes "and", `npm run test:unit` becomes `test: unit`).
  - It runs on rebase replays and on the allocator `[REQ]` body.
- Root cause: `NS/scripts/lib/auto-fix-commit-message.sh:143,278-342`, `NS/githooks/pre-commit:87-98` (R17, R18).
- Fixed? **Partial.** `local/hook-correctness` adds the `HOW_GIT_AUTOFIX=0` opt-out, skips replays and scrubs text only. Body rewrites still apply when the opt-out is not set.
- Repro: commit with the body `` `npm run test:unit` plus `a-b` `` inside a code span. Expect it byte-identical.

### FP-22 Spec contradictions force agents to guess (merge body shape, title length, version source, single-commit flow)
- Evidence: R14a-g, R15, R16. The benchmark failures in FP-13 trace to R14a.
- Root cause: the `NS/skills/git-*-audit/SKILL.md` lines cited in how-git-requests-ledger.md.
- Fixed? **Partial.** `local/spec-contradictions` (docs). Still open: the consistency lint `local/lint` covers only in-repo copies, and the vendored consumer copies drift (`diff -rq` at `f9e94080…:12556`).
- Repro: run the lint over canonical, fractaris and helpen-admin-native copies. Expect 0 contradictions and 0 drift.

## Top 5 unfixed (no branch has any fix)
1. FP-01: no pool-size gate, and the atomicity gate can be bypassed (about $375, 12 h).
2. FP-02 and FP-03: the preflight guard and zip flood. It denies temp clones, worktrees and chained preflights, and caused 217 zips and 2 disk-full stalls. The root cause is in `~/.claude/hooks/`.
3. FP-04: the post-checkout `claude -p` audit fails open ("Not logged in" counts as a pass; 151 spawns in a day). It is only partly fixed for detached HEAD.
4. FP-06: the set-mode admin gate halted 3 repos and drew Joel's "dont ask me anything again".
5. FP-17 and FP-16: lease pushes through URL tokens and the hand-rolled main bootstrap. There is no `bin/push-pool` and no `bin/bootstrap-offgrid`.

## Working files (scratchpad, not deliverables)
- `<scratchpad>/hg_live.json`, `hg_freeze.json`: marker hits with file:line.
- `…/scratchpad/live/`, `…/scratchpad/freeze/`: extractor `candidates.json` and `digest.md`.
- `…/scratchpad/scripts/hg_scan.py`, `hg_real.py`, `hg_audit_sessions.py`.
- Freeze extraction: `$TMPDIR/freeze-Jyq8/` (safe to trash).
