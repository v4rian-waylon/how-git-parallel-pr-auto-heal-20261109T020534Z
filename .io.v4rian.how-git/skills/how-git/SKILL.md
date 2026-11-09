---
name: how-git
description: Lean loader for git work in a repo carrying .io.v4rian.how-git/. Invoke before any commit, branch, merge, release, tag, rewrite or rebuild; it reads only what the task's decision-tree row names.
---

# how-git (in-repo lean loader)

Canonical source: the framework repo's `.io.v4rian.how-git/` on `dev` (README "Canonical source"); a vendored or workspace copy is never edited. Skills: `.io.v4rian.how-git/skills/<name>/SKILL.md`, overridden by name from `~/.config/how-git/skills/` (`resolve_skill`, `scripts/_lib.sh`); read one copy per skill. No confirmation line; the invocation is the receipt.

## On invoke

1. Pick the ONE row below that matches the task; read only its skills and run `--help` only for its tools. Nothing else: no other skill, no full `docs/RUNBOOK.md` or `docs/Git_Strategy.md` (one section for a named question).
2. Model: v4rian when `.io.v4rian.how-git/` exists; legacy when the repo uses `feature/*` branches (`git-strategy-audit` Legacy model).
3. Before any git write, export `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` for the account of the origin's GitHub org (Git_Strategy "Commit identity follows the origin's org"); the user's own identity for rebuilds of the user's own snapshots.

## Decision tree

| Task | Read | Tools (`--help`) |
|---|---|---|
| Compose a commit | `git-commit-audit` | `bin/smart-commit` |
| Create a working branch or hotfix | `git-strategy-audit` | `bin/create-pool-branch --no-jira --help`, `bin/status` |
| Merge a pool into dev | `git-merge-audit` | `bin/init-pool-merge` (connected), `bin/finalize-pool-merge` (off-grid), `bin/version` |
| Release dev to main | `git-merge-audit`, `git-runtime-audit` | `bin/init-release` (connected), `bin/ship` (off-grid) |
| Rewrite my own history | `git-history-preservation`, `git-history-rewrite` | a preflight ref and bak zip first (workspace `how-preflight` where installed) |
| Rebuild from bak zips | `git-snapshots`, then each sub-skill (`git-snapshot-preflight` first) only at the step that names it | |
| Rebuild from working-tree folders | `git-shuttle`, then each sub-skill only at its step | `skills/git-shuttle/tools/*.sh` |
| Replay or rebase across diverged history | `git-reconcile-intent` | |
| Verify compile, coverage or runtime | the matching `git-*-audit` | `bin/ci-local` |
| After a push | `how-dev` only when a CI (remote workflows or `bin/ci-local`) is connected | `bin/ci-local` |
| GitHub API call needing credentials | `git-token-discovery` | |
| Bootstrap a new repo | `git-strategy-audit`, `git-commit-audit` | clone the how-git template; `bin/doctor` |
| Adopt or migrate the framework | none | `bin/attach`, `bin/sync-framework`, `bin/doctor` |

A plan spanning several rows (rebuild, release, migration) names every inventory skill with where it applies or why it is N/A, reading only those that apply.

## Inventory (names only; read on demand)

`git-commit-audit`, `git-merge-audit`, `git-strategy-audit`, `git-history-preservation`, `git-history-rewrite`, `git-snapshots`, `git-snapshot-preflight`, `git-shuttle`, `git-coverage-audit`, `git-compile-audit`, `git-runtime-audit`, `git-reconcile-intent`, `git-token-discovery`, `how-dev` (each frontmatter `description` says its scope).

## Rules at a glance (no hook enforces these)

- The `required.*` checks (`bin/ci-local` off-grid) are green before a merge; if the budget does not fit, the work does not ship.
- Every claim in a commit (cause, fix, number) has a receipt gathered first; a clean compile is not one; unverified changes wait uncommitted.
- Every change rides a pool, a single commit included; `dev` and `main` take no direct commits. One defect, one pool: retries land on the same branch.
- Merge a pool only after the user ran the artifact and said it works or a per-repo grant allows it; no PR unless asked; the merge body is the claim's `PR #N <url>` paragraph, the PR body verbatim and, into main, the release roster (`git-merge-audit` rule 10). Main moves only on the user's explicit instruction; automation never writes `dev` or `main` without a verbatim grant.
- Push right after each commit and push every ref you create (pool, safety, preflight) plus tags; verify each push with `git ls-remote`; write refspecs as `"${P}:refs/heads/${P}"` (zsh).
- Never pick `nN` and never push a self-made `pool/*` or `safety/*` ref; the allocator creates pairs. One pool is one feature area of about 20 commits at most; bigger work is a sequence of pools. Allocator safety anchors stay forever; manual `safety/<branch>-<timestamp>` snapshots and bak zips go to the trash only on the user's direction, never hard-deleted.
- No empty commits; a fresh repo fast-forwards `main` to `dev`. Intro commit: bare repo name as title, body = README body, only `.gitignore` and `README.md`, source date when replanting.
- Never invent a JIRA code. Never touch user-authored commits without explicit authorization. Rewriting your own commits keeps each original author; only the committer names your model.
- After a cherry-pick, replay or re-applied patch, diff against the baseline and grep every symbol the body claims; "applied cleanly" is not verification. Compare files by hash.
- Commit dates keep the source's real offset, ref and zip names use UTC `Z`, never asked. A replay keeps author dates byte for byte, the committer date is the replay time, a merge takes its source tip's committer date; after a replay `git log --reverse --format=%ct <base>..<tip> | sort -c -n` passes and no commit is empty.
- Merge body (and PR body): a 1-3 sentence macro paragraph, a blank line, then `- <Topic>.` bullets holding indented `    - <label>: <summary>.` leaves, every list line ending with a period, this merge's diff only (`git-merge-audit` rule 5):
  ```
  Lands the parser rewrite with error recovery for malformed input.

  - Parser.
      - Block grammar: parses nested blocks and recovers at the next block.
  ```
- Amend a merge only before the push that triggers the claim; never amend or force-push `main` after the claim has tagged.

Hook-enforced, so not repeated here: dash scrub (`pre-commit`, code included: a regex or fixture needing a dash writes the `\u2013` / `\u2014` escape with a comment saying why), message auto-fix and `Co-Authored-By` removal (`prepare-commit-msg`), subject length (`commit-msg`), branch names (`pre-push`), version tags (claim scripts), safety and pool rulesets (`rulesets/*.json` when connected).
