---
name: git-snapshots
description: Reconstruct clean atomic git history from a chain of bak zip snapshots in any workspace. Walks zips chronologically; per zip builds preflight backups, applies content as atomic feature-branch commits, verifies via coverage + compile + runtime, merges to dev → main. Project-agnostic - infers scope from conversation or asks once upfront, never prompts again mid-flow. All actions are fully reversible via safety snapshots; rejection rolls back cleanly. Orchestrates 10 sub-skills.
---

# git-snapshots - chain-of-zip rebuild orchestrator (project-agnostic)

You reconstruct atomic git history from a chain of bak zip snapshots into a real repo on a git host. The output git log must read like normal disciplined development - no reference to zips, no rebuild language, no fabrication.

## Scope determination (FIRST step, every invocation)

Before any work, determine the scope. Infer when possible; ask once when not.

### What scope means

- **Workspace root**: the directory containing the repos (e.g. `<workspace>`).
- **Bak dir**: where the zip chain lives (e.g. `<workspace>/baks/`).
- **Mirror dir**: where the auto-synced shuttle lives (e.g. `<workspace>/shuttle.o/`); optional.
- **In-scope repos**: the subset of subdirs under workspace that are real git repos to operate on. Some workspaces may exclude specific repos.
- **Identity**: per `docs/Git_Strategy.md` "Commit identity follows the origin's org": the account of the GitHub org in `remote.origin.url`, or the user for rebuilds of the user's own snapshots, exported as `GIT_AUTHOR_*`/`GIT_COMMITTER_*`; never `git config user.*` or the machine's global identity.

### Inference rules (try in order)

1. If the user named a workspace path in conversation, use it.
2. If the current working directory contains multiple `.git/` subdirs at one level deep, that directory is the workspace.
3. If the workspace contains a `baks/`, `bak/`, or `BAK*/` subdir with `*.zip` files inside, that is the bak dir.
4. Look for project-level guidance: `<workspace>/CLAUDE.md` often lists in-scope repos and exceptions.

### Explicit ask (only if inference fails)

If any of the four scope items can't be inferred, ask ONCE upfront via `AskUserQuestion`:

```
"Confirm zip rebuild scope:
  - Workspace root: <inferred or empty>
  - Bak dir: <inferred or empty>
  - Repos in scope (comma list): <inferred or empty>
  - Repos to exclude (comma list): <empty>"
```

After this single ask, **never prompt the user again** during the rebuild. All subsequent actions execute under the established scope.

## Reversibility - no permission prompts mid-flow

The user does not get interrupted with permission asks during execution. Instead, every destructive action is preceded by a safety snapshot so any rejection rolls back cleanly.

### Safety snapshot pattern

Before any of: `git push --force[-with-lease]`, `git push origin --delete`, `git reset --hard`, `git filter-branch`, `git rebase`:

1. Tag the current state of each affected branch as a local safety branch:
   ```bash
   TS=$(date +%Y-%m-%d-%H%M%S)
   for branch in main dev <working branches>; do
     git branch "safety/${branch//\//_}-$TS" "$branch" 2>/dev/null
   done
   ```
2. Push every safety branch to origin BEFORE the destructive operation:
   ```bash
   git push origin "safety/...-$TS"
   ```
3. Execute the destructive operation.

If the user signals rejection (`stop`, `revert`, `undo`, `roll back`), restore from the latest safety branches:

```bash
TS=<the last safety timestamp>
git push --force origin "safety/main-$TS:refs/heads/main"
git push --force origin "safety/dev-$TS:refs/heads/dev"
# etc per affected branch
```

### Safety branch cleanup

After the user explicitly confirms the rebuild result is acceptable (or after a configurable retention window), safety branches can be deleted:

```bash
git push origin --delete safety/...-$TS
git branch -D safety/...-$TS
```

Until that confirmation, safety branches are preserved on origin AND locally.

### Operations that are NOT reversible

A few operations can't be undone - these are the only cases where the skill explicitly asks before proceeding (and the ask is genuine, not effort-saving):

- Deleting a remote repository entirely via API (`DELETE /repos/...`). No git-level recovery.
- Force-pushing a branch the user wants kept that has no safety snapshot (only on operator error).

When such an irreversible operation is needed, surface a `Confirm IRREVERSIBLE: ...` ask via `AskUserQuestion`. Otherwise, proceed.

## Canonical per-zip sequence

For each zip N in chronological order (oldest first):

### Step 0 - Read inputs
- Make the run's scratch root once, `ZIPS=$(mktemp -d "${TMPDIR:-/tmp}/snapshots.XXXXXX")`, and extract the zip to `$ZIPS/zip<N>/` preserving mtimes (`unzip` does this by default); `git-coverage-audit` diffs against that extract.
- Identify which in-scope repos the zip touches (top-level dir or nested wrapper).
- Compute the zip's date for naming: `date -r <zip_path> +%Y-%m-%d`, with a two-digit `/NN` sequence (`/01`, `/02`, ...) for same-date collisions (`preflight-bak-YYYY-MM-DD/NN`).

### Step 1 - Safety snapshot + preflight
- Tag current `main` + `dev` of every affected repo as safety branches and push.
- Invoke `git-snapshot-preflight` per affected repo (one preflight per zip × repo).
- Preflight pushes to origin BEFORE any rebuild commit.

### Step 2 - Plan strategy
- Invoke `git-strategy-audit` - map the diff (zip N vs zip N-1) into atomic feature topics; give every topic its own working branch, a single commit included; plan README touches.

### Step 3 - Apply commits atomically
- For each commit, invoke `git-commit-audit` (sections A-J) before composing the message.
- Date rule: both `GIT_AUTHOR_DATE` + `GIT_COMMITTER_DATE` = latest mtime of staged subset.
- Description paragraph (1-3 sentences) opens body.
- `[NEW]` reserved for genuinely new files / classes / subsystems.

### Step 4 - Verify after every feature merge into dev
- `git-merge-audit` for the merge.
- `git-coverage-audit` (binary diff vs zip extract).
- `git-compile-audit` (compile pass).
- `git-runtime-audit` (boot/launch pass).
- Any failure → reset to safety branch + investigate.

### Step 5 - Close the zip with dev → main
- `git-merge-audit` for `[MERGE] dev into main`.
- Run all three audits again against the post-merge main.

### Step 6 - Push (force-with-lease only)
- `git push --force-with-lease origin main dev <working branches>`.
- Never `--force` without `--with-lease`; never include `preflight-bak-*` in the push set after initial preflight push.

### Step 7 - Move to zip N+1
- Archive the zip from canonical bak dir to `<mirror>/baks/archived/` only after every check passes.
- Do not delete the most recent zip in the chain - it is the rollback.
- Safety branches from this zip remain available until the user confirms acceptance of the next zip's outcome.

## Blank repo state

For repos that are intentionally empty (new or wiped), force-push an orphan commit with an empty tree and an empty commit message to `main`. No tombstone wording, no `Initial` title, no descriptive subject. The user does not get prompted; the rewrite executes against the safety-snapshot pattern so it remains reversible.

See `git-history-rewrite` Mechanic 3 for the exact commands.

## Cross-cutting governance (read first, every invocation)

1. **Saved memory and skills are binding.** Read `MEMORY.md` and every skill linked from `CLAUDE.md` before composing any commit or dispatching any sub-agent.
2. **Apply every learned rule on the FIRST pass.** Sub-agents get every applicable rule inline or a skill pointer.
3. **Active-monitor background agents.** Never sit idle while agents run; watch their git refs and intervene before push if violations surface.
4. **Never ask effort-saving questions.** The user's instruction is the thorough path.
5. **Never touch user-authored commits without authorization.** See `git-history-preservation`.

## Sub-skill index

- [`git-commit-audit`](../git-commit-audit/SKILL.md) - per-commit pre-write lens.
- [`git-snapshot-preflight`](../git-snapshot-preflight/SKILL.md) - offsite security backups.
- [`git-merge-audit`](../git-merge-audit/SKILL.md) - merge commit rules.
- [`git-runtime-audit`](../git-runtime-audit/SKILL.md) - boot/launch verification.
- [`git-coverage-audit`](../git-coverage-audit/SKILL.md) - binary diff coverage.
- [`git-compile-audit`](../git-compile-audit/SKILL.md) - compile-only verification.
- [`git-strategy-audit`](../git-strategy-audit/SKILL.md) - branching + strategy enforcement.
- [`git-history-preservation`](../git-history-preservation/SKILL.md) - user-authored commits are read-only.
- [`git-history-rewrite`](../git-history-rewrite/SKILL.md) - date-preserving rewrites; force-with-lease; blank-main mechanic.
- [`git-token-discovery`](../git-token-discovery/SKILL.md) - credential discovery for API operations.

Project-specific scope (in-scope repos, exceptions, build commands, init markers) belongs in the workspace's own `CLAUDE.md`, not in this skill.
