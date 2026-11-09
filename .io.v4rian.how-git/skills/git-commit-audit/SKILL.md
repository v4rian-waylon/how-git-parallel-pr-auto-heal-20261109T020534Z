---
name: git-commit-audit
description: Pre-write lens for every commit message: atomicity, title and tag fit, body, bullets, fabrication, file hygiene, dates, branching, merges, receipts. Run sections A-J against the staged diff; on a failure restage, resplit or rewrite.
---

# git-commit-audit - pre-write commit lens

Hook-enforced rules are one "enforced by" line; the rest is judged by the author before committing and by the CI judge (`ci/audits/push/required.commit-audit.sh` → `claude_judge_commit`, run by `ci-dispatch.yml` on every push and on demand by `.github/workflows/audit-pushed-branch.yml`).

## A. Atomicity

1. One concept per commit; ≥2 concepts, or unrelated subsystems with no connecting concept, split (`git reset HEAD`, restage).
2. A natural title needing `+`, `,`, `and`, `with` or `plus` is a split smell.
3. Soft cap ~800 lines per commit.
4. Plan the split before staging, not after.
5. Every change rides a working branch, a single commit included (section G).

## B. Title

6. `[TAG] Title in sentence case` (Jira code optional, never invented). Approved: `[FIX]`, `[NEW]`, `[REFACTOR]`, `[DOCS]`, `[TEST]`, `[REVERT]`, `[HOTFIX]`, `[MERGE]`; tools alone write `[REQ]` (allocator) and `[MODE]` (`bin/set-mode`). Cleanup is `[REFACTOR]`; there is no `[CLEANUP]`.
7. `[NEW]` only for a new file, integration, subsystem, operator workflow or build dependency; helpers, tokens and adapters inside existing code are `[REFACTOR]`. Test: reverting it removes a feature → `[NEW]`; it only removes structure → `[REFACTOR]`.
8. Aim for ≤72 chars. Hard limit enforced by `githooks/commit-msg`: 8-100, 140 for `[MERGE]` and `[REQ]`.
9. No hyphens in English compounds in title or body prose; identifier hyphens (`pool/n3.feature.booking-pipeline`, `Objective-C++`) stay.
10. Em/en dashes, the word "plus" and a `Co-Authored-By: Claude` trailer: enforced by `githooks/prepare-commit-msg` (`auto_fix_message` steps 1-3 rewrite them away); that hook skips merges, squashes, amends and conventional-commit subjects, where the rule still binds you.

## C. Body

11. Opens with a 1-3 sentence description paragraph at subsystem or class altitude: title says WHAT, description says WHY and at WHAT SCOPE, bullets say HOW. Never restates the title.
12. `[FIX]`/`[HOTFIX]`: after the description, `Cause:` then `Fix:` then bullets.
13. Other tags: bullets follow the description directly. No `Changes:` header.
14. `[MERGE]`: the `git-merge-audit` Body shape (paragraph, then nested list, a period on every line).
15. Forbidden mechanism words anywhere: `BAK`, `bak import`, `historical import`, `pre ATM role`, `captured in`, `from the zip`, `recovered from`, `reconstructed`, `WIP snapshot`, `in this zip`.

## D. Bullets

16. **V.1** Top-level bullet leads with the class or module name, not a path (unless the path is the story: a move, a contract config file).
17. **V.2** Methods nest under their class; the class name never repeats per line.
18. **V.3** Bullets name classes, functions or methods only: no fields, properties, constants, handlerless signals.
19. **V.4** No constructor bullets.
20. **V.5** One short verb-led sentence per symbol; no parameter lists, return shapes or step walks.
21. **V.6** Reuse the docstring's verb and noun when there is one.
22. **V.7** Third person present (`Normalizes`, not `Normalize` or "New function that").
23. **V.8** Software-standard verbs (`Creates`, `Deletes`, `Updates`, `Reads`, `Writes`, `Schedules`, `Dispatches`, `Returns`, `Throws`, `Adds`, `Exposes`, `Drops`). Banned: "Stands up", "Tears down", "Spins up", "Lights up", "Stitches together", "Kicks off", "Gains".
24. **V.9** New symbol: declarative present. Modified symbol: uses `now`.
25. **V.10** Never fabricate a symbol: every name in a bullet exists in the committed tree (`git show <sha>:<path> | grep`): JS method definitions, C++ `.h` declarations and `Class::method`, QML `function name(` / `signal name(`, Objective-C `- (type)selector:`.

## E. File hygiene

26. `git diff --cached --name-only` shows none of: `.DS_Store`, `.auth/`, `keys/`, `*.p8 *.p12 *.cer *.pem *.provisionprofile *.mobileprovision`, `build/`, `build-*/`, `node_modules/`, `.env`, `exports/`, `*.zip`, `aqtinstall.log`, `runtime-smoke-notes.md`, `*.bak`, `*_old.qml`; the repo `.gitignore` blocks them on first touch.
27. Stage by name, never `git add -A` or `git add .`.
28. `node --check` passes for staged JS.
29. Em/en dashes in staged files: enforced by `githooks/pre-commit` (rewrites them to hyphens and re-stages, code included). A regex or fixture that needs one writes the `\u2013` / `\u2014` escape with a comment saying why.

## F. Dates (rebuild commits)

30. Real-time commits set no date variables. Rebuild commits set **both** `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` to the staged subset's latest mtime with the source's real offset (`date -r "$EPOCH" +%Y-%m-%dT%H:%M:%S%z`, GNU `date -d "@$EPOCH" ...`; mtimes via `stat -f %m`, GNU `stat -c %Y`); a replayed commit keeps its own `%aI`; never `stat -f '%Sm' -t '...Z'`. Ref and zip names use UTC `Z`. Derived, never asked.
31. Author date == committer date, explicit offset, monotonic on the branch, ≤ now. Copy sources with `cp -p` / `rsync -a`.
32. A merge takes the source tip's committer date (`git-merge-audit` 12); a closing `[DOCS]` commit takes the branch's latest content commit date.

## G. Branching

33. Every change, a single commit included, rides a working branch; `dev` and `main` take no direct commits. Only the root commit of a brand new repo lands without one.
34. `pool/[vYYYY.MAIN/]nN.kind.[sprintX-][JIRA-]short_name` (one regex, `HG_BRANCH_RE` in `scripts/_lib.sh`) from the allocator (`bin/create-pool-branch --help`); never pick `nN`, never push a self-made `pool/*` or `safety/*` ref, never touch the paired `safety/` anchor; no `zipN`, `bak`, `wip`, `snapshot` or `historical` in any branch name. One pool is one feature area of about 20 commits at most; larger work is a sequence of pools. Legacy-model repos: `git-strategy-audit` Legacy model.
35. `--no-ff` merge into `dev`. A meaningful branch (subsystem, integration, operator workflow, architecture) carries a `[DOCS]` commit touching README.

## H. Merges

36. Title `[MERGE] <source> into <target>: <version>`, no extra "Merge" word; the claim scripts stamp the version (`bin/version`) and tag, never by hand. Working branches into dev, dev into main at a release, no jumps. Body shape, mechanics, legacy repos: `git-merge-audit`.
37. Merge bodies never mention `rebuild`, `import`, `snapshot`, `recovered`, `reconstructed`, `WIP`.

## I. Retroactive review

The lens applies to commits already in `git log`. Walk every commit, catalog every offense, plan the corrective rewrite of your own commits only (`git-history-preservation`); sibling commits from the same session usually carry the same defect. A rewrite keeps each commit's original author name, email and date; only the committer may name the rewriting model, and the committer date is the replay time (`git-history-rewrite`, Authorship and Dates of rewritten commits).

## J. Receipts (behavioral claims need verification evidence)

A body asserting OBSERVED behavior (measured, verified, reproduces, confirmed, a `Cause:` narrative, a `Fix:` outcome, a quoted number) carries a `Receipts:` section after the bullets: per claim, the command and its result, a log path, a green test or a benchmark id that existed before the message was written.

- A clean-looking UNTESTED fix fails: sound reasoning plus a clean compile is not a receipt.
- No behavioral claim (docs, pure refactors, renames) needs no section.
- Verdict: `AUDIT_FAIL: receipts - <the claim> asserted with no named verification evidence`.

Before `git commit`: re-read A-J against the staged diff, run the V.10 greps, `node --check` staged JS, confirm rebuild date variables. See also `git-strategy-audit`, `git-merge-audit`, `git-history-preservation`, `git-snapshots`.
