---
name: git-strategy-audit
description: Enforce the branching + workflow strategy on every commit cluster. Two models - v4rian (pool/[vYYYY.MAIN/]nN.kind.[sprintX-][JIRA-]short_name with paired safety/nN.* anchor created by the allocator) and legacy (feature/*, in its own marked section). Every change rides a working branch, single commits included (no direct commits to dev); --no-ff merges; dev merges into main at every release; README touched per meaningful branch; no zip-mechanism words in branch names. Invoke from git-snapshots step 2 BEFORE composing commits.
---

# git-strategy-audit - branching + workflow strategy enforcement

**Enforced by:** `githooks/pre-push` (branch-name regex, refuses a misnamed push), the allocator (`bin/create-pool-branch`, `scripts/allocate-pool-branch.sh`) and, when connected, `rulesets/pool-creations.json`. No hook judges the plan below (one working branch per change, commit split, merge order); you do, before the first commit.

Strategy is decided BEFORE the first commit, not after. This skill answers: what branches do I need, how many commits per branch, what names, and what merge shape.

## Branching model - pick the model first

There are TWO models in play. Identify the repo's model BEFORE any branch design:

| Marker | Model |
|---|---|
| `.io.v4rian.how-git/githooks/pre-push` enforces `^(pool\|safety)/n[0-9]+\.…` regex | **v4rian** |
| `.io.v4rian.how-git/bin/version` present (tags are the seal; no VERSION file) | **v4rian** |
| `feature/v{X}/{Y}/{Z}-name` branches in `git branch -a` | **legacy** |
| Brand-new repo with neither marker | **v4rian** (bootstrap from `how-git` template) |

If unclear, ask. Do not mix models within a repo. Full model: `docs/Git_Strategy.md`.

### Canonical model - v4rian (new repos, from the how-git template)

```
main ← dev ← pool/[vYYYY.MAIN/]nN.(feature|fix|r&d|refactor|reconcile|doc).[sprintX-][JIRA-]short_name
                                                           ↑
                            paired safety/nN.SAME (atomic anchor) created
                            by the branch-creation endpoint at the same SHA
```

- `main` carries released state. Protected. Only merges from `dev` via PR. Release on every merge, attached to the reused dev tag by the claim.
- `dev` carries integration state. Protected. Only merges from `pool/nN.*` via PR. Internal version tag on every merge, written by the claim.
- `pool/nN.kind.short-name` is short-lived per feature. Allocated by the branch-creation endpoint (`bin/create-pool-branch`, Git_Strategy "Branch Creation") - **developers DO NOT create remote pool/* branches**.
- `safety/nN.kind.short-name` is the paired immutable anchor. Created atomically with the pool/* branch. Read-only. Stays forever, released or abandoned (Git_Strategy "Safety Branches").
- `kind ∈ {feature, fix, r&d, refactor, reconcile, doc}`. The optional `vYYYY.MAIN/` prefix is the release series the allocator adds. `sprintX-` and `JIRA-` segments optional. `short_name` lowercase, `[a-z0-9][a-z0-9-]*`.

Versioning: `vYYYY.main_counter.dev_counter` (`bin/version --help`). Three segments; `main_counter` resets on year rollover; `dev_counter` resets on main merge or year rollover. Hotfixes follow the standard `dev → main` pipeline, never a bypass.

### Legacy model (pre-v4rian repos only; the only place `feature/*` naming applies)

```
main ← dev ← feature/v{X}/{Y}/{Z}-name
```

- `feature/v{X}/{Y}/{Z}-name` / `feature/v0/0/N-name` for the first pack / `feature/<kebab-case-short-name>` in early repos.
- Branch creation is by-developer.
- Versioning is semver `vX.Y.Z`; Z inherits dev tip's highest minor verbatim.

For zip rebuilds (either model): at every zip close, `dev` merges into `main`.

## Every change rides a working branch (model-agnostic)

Every change rides a working branch, a single atomic commit included: cut it off `dev`, commit there, merge `--no-ff` into `dev` at the end. `dev` and `main` take no direct commits (`docs/Git_Strategy.md`, Branch Structure). The only exception is the root commit of a brand new repo, which has no `dev` to branch from.

Lay out the atomic commits before starting work and name the working branch FIRST.

Atomicity heuristics:
- One new file = one commit.
- One refactor pass = one commit.
- One bug fix = one commit.
- A tooling change adjacent to a feature = its own commit.

When in doubt about whether two changes should be one commit, **split them**. Combining is cheap (squash on merge); splitting after the fact is expensive.

## Working-branch naming

5. **Format**: `pool/[vYYYY.MAIN/]nN.(feature|fix|r&d|refactor|reconcile|doc).[sprintX-][JIRA-]short_name` (lowercase short name, `[a-z0-9][a-z0-9-]*`); enforced by `HG_BRANCH_RE` in `scripts/_lib.sh`, which `githooks/pre-push` sources.
6. **`nN` is allocated by the branch-creation endpoint** (`bin/create-pool-branch`). Never pick `nN` yourself. Local spike branches with the right shape are fine (`post-checkout` warns on a misnamed branch, `pre-push` refuses to push one); the remote rejects developer-created `pool/*` pushes per Repository Rules (`rulesets/pool-creations.json`).
7. **Paired safety branch** is created atomically by the endpoint at `safety/nN.kind.short_name`. Do not create safety branches manually; do not touch them after creation (Pattern 1).

Examples:
- `pool/v2026.0/n3.feature.parser-rewrite`
- `pool/n3.feature.sprint4-parser-rewrite`
- `pool/n7.fix.PROJ-123-token-leak`
- `pool/n12.r&d.sprint5-PROJ-456-embedding-cache`
- `pool/v2026.0/n22.doc.runbook-rewrite`

8. **Forbidden in branch names (both models)**:
   - `zip1`, `zip2`, `zipN`, any literal zip reference (`pool/n3.feature.zip1-definitions` is wrong).
   - `bak`, `wip`, `snapshot`, `historical`, `preflight` (other than the literal `preflight-bak-YYYY-MM-DD` security backup branches).
   - `recovered`, `reconstructed`, `from-zip`, `captured-in`.
   - Uppercase in the short-name segment (v4rian requires lowercase; legacy used kebab-case which is also lowercase).

9. **Branch names describe the FEATURE / fix / refactor**, not the mechanism. Multiple working branches per zip is normal.

## Merge shape (both models)

8. `--no-ff` always. Preserves the merge commit even when fast-forward is possible.
9. One tagged `[MERGE] <branch> into dev: <version>` per working branch merge. Never leave parallel untagged `Merge ... into dev` duplicates.
10. `[MERGE] dev into main: <version>` per release (or per zip close during rebuilds).

See [`git-merge-audit`](../git-merge-audit/SKILL.md) for the merge commit's title + body + date discipline.

## README discipline per working branch

11. Every meaningful working branch (new subsystem, new integration, new operator workflow, architecture change) must touch `README.md` at least once. Two paths:
    - **Preferred**: add a `[DOCS] Document X in README` commit ON the working branch (typically the last commit, or a dedicated commit alongside the new code).
    - **Acceptable**: include a one-line README delta in the merge commit's body if the change is tiny.
12. Internal refactors that don't change behavior or surface do NOT require README updates.

## Strategy planning per zip / per release (Step 2 of git-snapshots)

For zip N (or release N), before composing any commits:

1. `diff -r --brief` zip N vs zip N-1 to produce the change list per repo.
2. Group changes into atomic topics (one topic = one working branch).
3. For each topic: design the working branch.
   - **v4rian:** plan the kind + sprint/jira + short-name; the allocator will assign `nN` at request time.
   - **Legacy:** branch name kebab-case feature-led.
   - Commit list: each is a single concern with a [TAG] in mind.
   - README touch: which commit on the branch does it?
4. A topic with 1 atomic commit still gets its own working branch.
5. Confirm the merge order: working branches merge into dev in the order their content layers (deps first).
6. Plan the `[MERGE] dev into main` at zip close / release boundary.

## Strategy audit lens

Before merging or pushing, walk this lens:

| Item | Question |
|---|---|
| 1 | Did every change land through a working branch (no direct commit on `dev` or `main`)? |
| 2 | Does every meaningful working branch carry a `[DOCS]` README commit? |
| 3 | **v4rian:** Does every `pool/nN.*` branch have a paired `safety/nN.*` anchor (Invariants I2 + I7)? Did the allocator create both, never a dev? |
| 4 | **v4rian:** Is every working branch name matching the regex? Lowercase short-name, valid kind, optional sprint/jira correctly formatted? |
| 5 | **Legacy:** Are all feature branch names kebab-case + feature-led (no `zipN`, `bak`, `wip`)? |
| 6 | Did every working branch merge into dev with `--no-ff`? |
| 7 | Is there exactly ONE `[MERGE] <branch> into dev: <version>` per working branch (no parallel untagged dupes)? |
| 8 | Is `dev` merged into `main` at this release / zip close? |
| 9 | Does the order of working-branch merges into dev respect dependency layering? |
| 10 | **v4rian:** Will the claim tag and Release the merge (no manual tagging)? |

If any item fails, fix before pushing.

## Blank `main` exception (legacy mechanic; rarely needed under v4rian)

For repos that should be empty (created by mistake, or wiped per user direction):

- `main` is an orphan commit with empty tree (`git mktree` with no input).
- Commit message: `Initial`.
- No `dev` branch.
- No working branches.
- See `git-history-rewrite` for the mechanic.

The strategy still applies the moment the repo gets real content - the very first work cuts a working branch off the empty `main`. Under v4rian, that work goes through the allocator.

## Banned shortcuts

- Committing straight to `dev` or `main`, even a single commit.
- Branching off `main` directly for features - always off `dev`.
- Squash-merging on `dev` (defeats atomicity).
- Naming `pool/n3.feature.temp` - every branch carries a real feature short name.
- **v4rian:** Developer-created `pool/*` or `safety/*` branches on the remote (allocator-only).
- **v4rian:** Picking `nN` yourself (race condition with allocator).
- **v4rian:** Tagging dev or main manually (the claim's job).

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) - strategy planning is Step 2.
- [`git-commit-audit`](../git-commit-audit/SKILL.md) - Section G is the branching slice of the full audit.
- [`git-merge-audit`](../git-merge-audit/SKILL.md) - merge commit shape after strategy is decided.
- [`git-snapshot-preflight`](../git-snapshot-preflight/SKILL.md) - `preflight-bak-*` branches are NOT working branches; different rules.
- `docs/Git_Strategy.md` - v4rian model, Branch Creation (allocator contract), Safety Branches (atomic pair invariant).
