---
name: git-merge-audit
description: Apply the merge commit discipline to every merge commit (pool→dev and dev→main). Title format [MERGE] source into target, body is a macro paragraph then a nested list with a period on every line, no rebuild/snapshot/recovered language, --no-ff always, date = source branch's latest content commit. Invoke from git-snapshots step 4 (feature merge) and step 5 (zip close).
---

# git-merge-audit - merge commit discipline

Every merge commit follows this exact discipline. Violations are visible at a glance and surface immediately in `git log --merges`.

## Title

1. **Format**: `[MERGE] <source> into <target>: <version>`. Examples:
   - `[MERGE] pool/v2026.0/n7.feature.parser-rewrite into dev: v2026.0.164`
   - `[MERGE] dev into main: v2026.0.164`
   - Legacy repos: see Legacy model below.
2. **No redundant "Merge" word**. The tag `[MERGE]` and the literal word "Merge" together is the smell:
   - Wrong: `[MERGE] Merge pool/n7.feature.parser-rewrite into dev`
   - Right: `[MERGE] pool/n7.feature.parser-rewrite into dev: v2026.0.164`
3. Length is enforced by the `commit-msg` hook: 8-140 chars for `[MERGE]` subjects, which carry the full pool ref and version.
4. No hyphens in prose, no em dashes, no "plus" word (identifier hyphens in branch names like `pool/n3.feature.foo-bar` are fine).
4a. **Version is mandatory.** Source of the version:
    - Tags are the seal, there is no VERSION file. A pool into dev takes `bin/version --next-dev`; dev into main reuses the existing dev tag (`bin/version --release-tag`, same code, same version). `claim-dev-merge.sh` and `claim-main-release.sh` stamp it into the subject, so a hand-typed version is overwritten.

## Body

5. **The rule, one line, every merge (pool into dev, dev into main) and its PR body:** a 1-3 sentence macro paragraph, one blank line, then a nested list of `- <Topic>.` bullets each holding indented `    - <label>: <one-line summary>.` leaves, every list line ending with a period, no `Changes:` header.

   ```
   Lands the parser rewrite with error recovery for malformed input.

   - Parser.
       - Block grammar: parses nested blocks and recovers at the next block.
   ```

6. Paragraph only, bullets only, flat bullets, a missing period, a `Changes:` header, method names or a comma-separated inline enumeration each fail the rule. `prepare-commit-msg` skips merges, so no hook reshapes the body for you; reverts within the branch get their own `- Reverts within the branch.` topic.
7. **Altitude differs by situation, the shape does not.** Pool into dev: the topics group the commits inside the branch (`git log --first-parent dev..<pool>`). Dev into main: the topics group the pool merges of the release (`git log --first-parent main..dev`) one altitude higher, what shipped from the user's perspective rather than what merged.
8. **The list is a literal recap of what merged, not an invented story.**

   Pre-write check: read it aloud. If it sounds like a method signature pulled into prose OR like marketing copy, rewrite.

   Forbidden in merge bodies (pseudo-code pole):
   - File or directory names (`intake-context.md`, `task-statement.md`, `.ag-sym9/runs/`)
   - Byte counts, packet sizes, timeout values (`7-byte tag`, `8 s race`, `1500-byte prefix`)
   - Protocol or RFC references (`RFC 3261`, `stream-json`, `HTTP/2`, `WebSocket /audio`)
   - Code-construct names (class names, exported functions, struct keys, JSON frame types)
   - Implementation verbs aimed at a code reviewer (`detached-spawn`, `token-overlap lookup`, `filter-branch`)
   - Token literals (`[END_CALL]`, `[VOICE]`)

   Forbidden in merge bodies (user-manual pole):
   - Outcome-pitch phrases (`actually works`, `reliable enough to`, `just works`, `becomes usable`)
   - Anthropomorphized assistant verbs (`the assistant remembers`, `narrates itself`, `picks up on`)
   - Benefit framing aimed at an end user (`so the call stays light`, `so you can`, `lets you`)
   - Conversational filler (`finally`, `actually`, `now`)

9. **THIS MERGE ONLY.** The body describes the diff of THIS merge. Never references prior merges' scope ("on top of the v0.2.0 voice-note ingest"), sibling feature branches, or future planned work. Absolute terms, not relative.

## Forbidden in title or body

8. `BAK`, `bak import`, `historical import`, `pre ATM role`, `captured in`, `from the zip`, `recovered from`, `reconstructed`, `WIP snapshot`, `in this zip`, `preflight`.
9. `rebuild` as a noun ("Closes the rebuild..."). Use feature-led framing.
10. `Co-Authored-By: Claude` trailer.

## Mechanics

11. **`--no-ff` always**. Preserves the merge commit even when fast-forward is possible. Without `--no-ff`, the working branch's atomic commits become indistinguishable from direct-on-dev commits.
12. **Date**: the source tip's committer date (`%cI`), so dev's first parent never goes backwards after a replay (`git-history-rewrite`, Dates of rewritten commits):
    ```bash
    DATE_ISO=$(git log -1 --format=%cI pool/<nN.kind.short_name>)
    GIT_AUTHOR_DATE="$DATE_ISO" GIT_COMMITTER_DATE="$DATE_ISO" \
      git merge --no-ff pool/<nN.kind.short_name> -m "[MERGE] pool/<nN.kind.short_name> into dev: <version>
    
    <description paragraph>"

    ```
13. **For `[MERGE] dev into main`**: date is `dev` tip's committer date:
    ```bash
    DATE_ISO=$(git log -1 --format=%cI dev)
    git checkout main
    GIT_AUTHOR_DATE="$DATE_ISO" GIT_COMMITTER_DATE="$DATE_ISO" \
      git merge --no-ff dev -m "[MERGE] dev into main: <version>
    
    <description paragraph>"
    ```

## Strategy

14. Working branches merge into `dev`, not `main`: `pool/nN.*` only; never push direct merges to dev under any other naming.
15. `dev` merges into `main` at every zip close / release, not just at the end of the chain.
16. One tagged `[MERGE]` per working branch; never leave parallel untagged `Merge ... into dev` duplicates in history.
17. The claim tags the merge commit: the claim (`claim-dev-merge.sh` / `claim-main-release.sh`, run by the post-merge hook or `bin/ship` off-grid and by `ci-dispatch.yml`'s pr-merge `required.claim.sh` when connected, with `dev-merge.yml` / `main-merge.yml` as manual re-runs, `bin/ci-local --workflow dev-merge --allow-claim` / `main-merge` off grid; without `--allow-claim` ci-local skips every claim). Do NOT tag manually; it would race the claim, which also stamps the version into the subject. Amend a merge only before the push that triggers the claim; never amend or force-push `main` after the claim has tagged.

## PR body parity

10. **Parity, exactly as the claim writes it.** In connected mode `claim-dev-merge.sh` builds the merge body as one `PR #N <url>` reference paragraph (bare `PR #N` when the repo slug does not resolve; no paragraph at all when the PR number does not), a blank line, then the PR body as stored on GitHub. So the merge body minus that first paragraph MUST equal the PR body character for character; when either is rewritten, PATCH the other via the GitHub API in the same operation. A release merge (dev into main) carries one more claim-added part: a final `- Open work pool branches at release.` topic listing the pools still open, which the PR body does not hold. Check: `scripts/check-merge-parity.sh <merge> --pr <N>` exits 0; for a release merge add `--strip-topic 'Open work pool branches at release.'` so the roster is dropped before comparing. Off-grid there is no PR and the body you wrote stays.

    Connected mode today does not yet deliver the rule 5 shape for PR bodies: `validate-pr-open.sh` runs the commit auto-fix over the PR body (it prefixes a derived `[TAG]` to the first line and appends an `opened-via-correct-flow` comment), the claim copies that text as is, and `bin/init-release` still seeds the dev into main PR with a `## Summary` header. Write the body in the rule 5 shape anyway and fix what the validator changed before merging; normalising PR bodies to that shape is enforced from pool 8 (merge-body-in-hook) on.

## Pre-push lens

Before pushing a merge commit:

- Title scans `[MERGE]` then space then source then ` into ` then target then `: <version>` (version mandatory).
- For dev → main: version is `bin/version --release-tag` (the reused dev tag, `vYEAR.SERIES.DEV`).
- For pool → dev: version is `bin/version --next-dev`.
- Body (after the claim's `PR #N <url>` paragraph in connected mode) is a 1-3 sentence paragraph, a blank line, then the nested list; every list line ends with a period; no `Changes:` header.
- **Macro tone check** (rule 8): grep the body for any of: file names with extensions (`.md`, `.mjs`, `.json`, `.sh`), directory paths (`/`, `<`), byte counts (`\d+\s*(b|byte|bytes|ms|s)`), RFC references (`RFC\s*\d`), token literals in brackets (`\[[A-Z_]+\]`), known implementation verbs (`detached-spawn`, `filter-branch`, `token-overlap`, `stream-json`, `dispatchChain`). Any hit → rewrite the offending clause in plain English.
- **This-merge-only check** (rule 9): grep the body for `on top of`, `extending`, `building on`, mentions of any version OTHER than this merge's own version, references to other branches. Any hit → rewrite to describe only the current merge's diff.
- `git show --stat` confirms the merge brought in the expected feature scope.
- The merge date equals the source tip's committer date.
- `--first-parent main` log line for this merge shows the right summary.

## Legacy model (pre-v4rian repos only)

Repos still on the legacy model (`git-strategy-audit` picks the model) differ in three places; everything else above applies unchanged.

- Branches: `feature/v{X}/{Y}/{Z}-name` or `feature/<kebab-case-name>`, also `hotfix/*`.
- Title examples: `[MERGE] feature/v0/3/3-embed-on-device-audio into dev: v0.3.3`, `[MERGE] dev into main: v0.3.9`.
- Version: from the branch name (`feature/v0/3/3-name` → `v0.3.3`); dev → main takes the dev tip's highest minor that landed, never Z reset to 0. No claim script exists, so the merge is tagged by hand after every audit passes.

## Retroactive cleanup

If old history carries untagged `Merge <branch> into dev` commits or `[MERGE] Merge X into Y` redundancy:

- `git filter-branch --msg-filter` with a `case` statement targeting the exact problem titles, or
- Interactive rebase with `exec` per-commit `git commit --amend -m "..."` (preserves dates via `--no-edit` plus env vars set).

See `git-history-rewrite` for date-preserving rewrite mechanics. Never rewrite history that contains user-authored commits without explicit authorization (`git-history-preservation`).

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) - orchestrator; invokes merge-audit in steps 4 and 5.
- [`git-commit-audit`](../git-commit-audit/SKILL.md) - Section H is the merge slice of the full audit.
- [`git-strategy-audit`](../git-strategy-audit/SKILL.md) - branching strategy enforcement (v4rian vs legacy model selection).
- [`git-history-rewrite`](../git-history-rewrite/SKILL.md) - date-preserving rewrites for retroactive merge cleanup.
- [`git-coverage-audit`](../git-coverage-audit/SKILL.md) - coverage diff after dev → main merge.
- `bin/version --help` - version source of truth (derived from git merge counts; no VERSION file); dev tags are internal, only a main release gets a GitHub Release.
- `docs/Git_Strategy.md` - branch format and release flow.
