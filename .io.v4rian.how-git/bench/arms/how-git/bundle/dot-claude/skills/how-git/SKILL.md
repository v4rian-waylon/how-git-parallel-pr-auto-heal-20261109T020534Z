---
name: how-git
description: Context loader for git work. Invoke before any commit, merge, PR, force-push, tag, history rewrite or release close-up so every git rule and git-* lens is loaded; then invoke the git-* skills the task demands.
---

# how-git

Loads context only. Invoke first, then act per the rules on the first pass.

## On invoke

1. Read the git memories the task touches: `feedback_github_creds_via_gcm_plaintext` (tokens and identities), `feedback_user_authors_when_rebuilding_history` (author for snapshot rebuilds), `reference_v4r_repo_meta` (the NAS-hosted V4R library), `feedback_helpen_merge_deploy_preauthorized` (per-repo merge grant).
2. Locate the git-* skills. Inside a v4rian repo (`git rev-parse --show-toplevel` has `.io.v4rian.how-git/skills/`), read every `<repo>/.io.v4rian.how-git/skills/git-*/SKILL.md`; those are authoritative for that repo. Outside a v4rian repo, or for a skill missing in-repo, read the canonical copy at `/Users/waylon/local_stage/fractaris/.io.v4rian.how-git/skills/`. Never read both copies of one skill; in-repo wins. The branching, versioning, safety-anchor and merge spec is `.io.v4rian.how-git/docs/Git_Strategy.md` with the ceremonies in `docs/RUNBOOK.md`; read them directly, never answer from a paraphrase, and never edit the canonical or a vendored copy.
3. Detect the branching model: v4rian when `.io.v4rian.how-git/` exists, the pre-push hook enforces `^(pool|safety)/nN\.`, or tags have the `vYYYY.SERIES.DEV` shape; legacy when `git branch -a` shows `feature/v{X}/{Y}/{Z}-name`.
4. Confirm in one line: `git rules loaded (<N> memories + <M> skills <in-repo|canonical>, repo on <v4rian|legacy> model); ready for <task>.` Then proceed.

## Rules at a glance

- Every audit on every commit, push, PR and branch, compile and runtime audits included, and every audit runs before the push; if the budget does not fit, the work does not ship.
- Every claim in a commit (cause, fix, measured number) is backed by evidence gathered before composing it; a green run of the affected surface is the receipt, a clean compile is not; unverified changes wait uncommitted.
- Any git plan (rebuild, release, migration) names every git-* skill with where it applies or why it is N/A; none is skipped silently.
- Working branches merge `--no-ff` straight into dev and push; no PR unless Joel asks for one, and a requested PR's body is character-identical to the merge commit body. The merge happens only after Joel has run the shipped artifact and said it works, unless a per-repo memory grants it (`feedback_helpen_merge_deploy_preauthorized`); until then deliver the atomic commits, the pushed branch and the artifact, then keep working other branches.
- Push to the tracking remote right after each commit, and push every ref you create (pool, safety, preflight) with `git push --all` plus tags. Merging or pushing main happens only on Joel's explicit per-instance instruction.
- One defect, one pool branch: retries of the same fix land on the same branch; allocation is for new units of work only.
- No empty commits, ever, not as an init root and not as a tombstone; a fresh repo fast-forwards main to dev instead of forcing a `--no-ff` merge.
- Intro commit of a new repo: title is the bare repo name with no tag, body is one macro paragraph identical to the README body, files are `.gitignore` and `README.md` only, date is the original source date when replanting an older repo.
- Never invent a JIRA code; omit the segment when none was given.
- Before pushing a cherry-pick, inherited orphan or re-applied patch, diff the result against the baseline ref and grep for every symbol the body claims removed; "applied cleanly" is not verification.
- Merge body: nested list, one-line summary per leaf, period on every line, engineering macro tone, this merge's diff only (`git-merge-audit`).
- Compare files across snapshots, copies and commits by md5 or git hash, never by name.
- Never hard-delete Pattern-2 safety branches or bak zips; bundle to `~/.Trash/git-branch-trash/` first and only on Joel's explicit direction. Pattern-1 v4rian anchors stay forever by spec.
- sym9 never commits, merges, tags or force-pushes dev or main without a verbatim grant in the launching conversation.
- v4rian: devs never push new `pool/*` or `safety/*` refs, the allocator creates branches, except `safety/<branch>-<timestamp>` snapshots. Off-grid `bin/create-pool-branch` numbers nN from local pool refs only, so compare with `git ls-remote origin 'refs/heads/pool/*' 'refs/heads/safety/*' 'refs/heads/vault/*'` and recreate the pair at the next free number before the first push. Write refspecs as `"${P}:refs/heads/${P}"` (zsh reads `$P:r` as a history modifier) and verify every push with `git ls-remote`.
- The v4rian pre-commit hook scrubs em and en dashes from staged code too; regexes and fixtures that need one write the `\u2013` or `\u2014` escape with a comment saying why.
- Off-grid close-up: `git merge --no-ff <pool> -F <file>` on dev (`-F -` does not read stdin); the post-merge hook claims the tag and pushes, so a following `bin/finalize-pool-merge` that reports "second parent does not match any pool/* branch tip" is harmless once `git ls-remote origin` shows dev and the tag; then push the pool and safety pair and run `.io.v4rian.how-git/scripts/archive-pool-branch.sh <pool>` to vault it.
- Ceremony identity: allocator `[REQ]` commits, merges and the claim's tag take the machine's global identity unless `GIT_AUTHOR_NAME`/`GIT_COMMITTER_NAME` (`v4rian-waylon (<Model>)`) and both emails (`v4rian-waylon@users.noreply.github.com`) are exported first; verify with `git log --format='%an|%cn' -1` and `git cat-file -p <tag> | grep tagger` before pushing.
- The post-merge claim refuses any dirty tree, untracked files included (an uncommitted FEATURE_REQUESTS.md blocks it): move such files aside, merge, re-run `.io.v4rian.how-git/githooks/post-merge 0` if needed, restore them. A conflicted merge (two `[REQ]` commits touching `active-requirement`) commits without the hook: resolve, `git commit -F`, then run the hook by hand.
- Legacy close-up after a dev to main merge, on Joel's instruction only: safety snapshot, amend title and body, push with `--force-with-lease`, trash the snapshot, restart the daemon. v4rian never amends or force-pushes main after the claim has tagged.

## Skill inventory

In-repo path: `<repo>/.io.v4rian.how-git/skills/<name>/SKILL.md`; canonical fallback as in step 2.

| Skill | Lens |
|---|---|
| `git-commit-audit` | Pre-write commit audit, sections A-I (atomicity, title, body, bullets, fabrication, hygiene, branching, merge format, date); both models. |
| `git-merge-audit` | Merge commit discipline: version in title, body shape, macro tone, this-merge-only, `--no-ff`, date inheritance, PR body parity. |
| `git-strategy-audit` | Branching enforcement with model selector: v4rian `pool/nN.*` + `safety/nN.*` pairs, legacy `feature/v{X}/{Y}/{Z}-name`. |
| `git-history-preservation` | Gate: user-authored commits are read-only; heuristics for mine vs user's. |
| `git-history-rewrite` | Date-preserving rewrite mechanics. |
| `git-token-discovery` | Find the GitHub credential available to the session. |
| `git-snapshots` | Orchestrator for rebuilding atomic history from bak zip chains. |
| `git-snapshot-preflight` | Offsite backup of each zip before any rebuild: `preflight-bak-YYYY-MM-DD[a-z]/NN`. |
| `git-coverage-audit` | Binary content coverage: byte-identical excluding sensitive files, README, gitignore. |
| `git-compile-audit` | Compile verification per (zip x repo). |
| `git-runtime-audit` | Boot/launch verification after every merge per repo. |
| `git-shuttle` | Rebuild atomic history from working-tree folder snapshots in `shuttle.i/`. |
| `git-reconcile-intent` | Diff-layer reasoning and semantic hunk allocation for the auto-rebase L1-L5 ladder and replays across diverged history. |
| `how-dev` | Requirements-first, surgical-minimal developer discipline (`~/.claude/skills/how-dev/SKILL.md` outside v4rian repos). |
| `how-push` | Applies only to maintenance-mode repos where Joel asked for remote CI (local gates first, watch triggered runs); elsewhere done means local gates, no CI proposed (`~/.claude/skills/how-push/SKILL.md`). |
| `how-preflight` | Preflight ref plus bak zip before any destructive repo operation (`~/.claude/skills/how-preflight/SKILL.md`). |

## Workflow decision tree

| Task | Invoke first | Model notes |
|---|---|---|
| Bootstrap a new repo | `how-new`, `git-strategy-audit`, `git-commit-audit` | v4rian: clone the `how-git` template, intro commit shape above, no manual tag, no VERSION file. Legacy: dev, FF main, tag v0.1.0. |
| Compose a commit | `git-commit-audit` | Same for both. |
| Create a working branch | `git-strategy-audit` | v4rian: allocator (`bin/create-pool-branch`), never push pool/* directly. Legacy: cut `feature/...` manually. |
| Merge working branch to dev | `git-merge-audit` | Only after Joel confirms the artifact works (or a per-repo memory grant); no PR. v4rian: amend only before the push that triggers the claim. |
| Merge dev to main | `git-merge-audit`, `git-runtime-audit`, em-dash scrub on full `main..dev` | Only on Joel's explicit instruction. v4rian: CI (or `bin/ship` off-grid) tags, Releases, archives; never tag or amend main by hand. Legacy: manual amend, tag, restart. |
| Hotfix | `git-strategy-audit` | v4rian: `pool/nN.fix.JIRA-X-name` through dev to main, never a bypass. Legacy: `hotfix/v{X}/{Y}/{Z}-name`. |
| Rewrite history (mine only) | `how-preflight`, `git-history-preservation`, `git-history-rewrite` | Same for both. |
| Rebuild history from zips | `git-snapshots` plus every sub-skill, `feedback_user_authors_when_rebuilding_history` | Target repo's model dictates branch and tag mechanics. |
| Rebuild history from working-tree folders | `git-shuttle`, `feedback_user_authors_when_rebuilding_history` | Same for both. |
| GitHub API operation needing creds | `feedback_github_creds_via_gcm_plaintext`, `git-token-discovery` | Same for both. |
| Trash Pattern-2 safety branches or bak zips | Rule above, on Joel's direction only | Pattern-1 v4rian anchors: never trash by hand. |

## Lessons from the 2026-10-28 rebuilds (V4Rlib, staqs, Helpën admin)

- **Spec source:** the latest spec is the local canonical `local_stage/how-git` dev, not GitHub (its dev lags its tags). how-git's own commit audit needs a Claude token in the environment and otherwise passes everything, so audit with an agent reading the canonical skills.
- **Branch size:** one pool is one feature area of about 20 commits (memory `feedback_pool_branch_size`). Splitting a finished branch: plan contiguous ranges, allocate each pool when dev sits at the previous merge, gate, merge, repeat; assert each pool tip's tree against the source commit's tree.
- **Allocator numbering:** `create-pool-branch` counts local branches only; after pruning merged pool refs it restarts at n1. Keep the local `safety/...` ref with the highest number, and check the remote before the first push.
- **Merge dates:** a merge is dated at its source tip (`GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE` = the tip's date); after any plumbing replay, assert that dates never go backwards and that no commit is empty.
- **Pinned SHAs across repos:** rewriting a library rewrites every consumer pin (pubspec `ref:`/`resolved-ref:`, Cargo.lock `#sha`). Map the pins by tag content, apply the map in the consumer's own rebuild, and check that no old SHA prefix survives.
