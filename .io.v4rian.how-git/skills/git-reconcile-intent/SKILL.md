---
name: git-reconcile-intent
description: Apply a commit / patch / refactor to a diverged target by reasoning at the diff layer (what's added/changed/removed and the semantic intent behind each hunk), allocating each hunk atomically, and reporting back when allocation requires interpretation. Invoke when replaying commits between repos, cherry-picking across diverged history, applying upstream patches to a local fork, when the auto-rebase L1-L5 reconcile ladder needs to land a pool branch's commits onto a moved dev tip, or any "make this change land cleanly somewhere it doesn't natively apply" task.
---

# git-reconcile-intent - diff-based reasoning + atomic semantic allocation

When a change (commit, patch, refactor) needs to land on a target whose history has diverged from the source's history, reason at the **diff layer**, not the end-state layer. Each change is a set of hunks: what is being **added**, what is being **changed**, what is being **removed**, and what is the **semantic intent** behind each. Allocate each hunk atomically to the target context; if allocation requires interpretation, **surface and ask** rather than guess.

## The rule

1. **Diff-based, not end-state.** Don't think "what should the final file look like after this commit?" Think "what does this commit's diff atomically add / change / remove, and where does each hunk go?" The end-state is what falls out of the allocation, not the input to it.

2. **Hunk-level granularity.** A commit modifying file F is not one decision - it's N hunks each with their own target context, intent, and outcome. Some hunks may apply cleanly, others may need interpretation; don't aggregate the decision.

3. **Atomic semantic allocation.** For each hunk:
   - **Target context exists in our state** → apply the hunk verbatim. Clean.
   - **Target context does not exist** → it's either NEW (concept never landed in our chain) or DROPPED (concept landed and was later removed). Check history (`git log -S '<unique-phrase>'` across all refs) to distinguish.
     - Never landed → the hunk INTRODUCES the concept; apply at the semantically-natural insertion point, but flag the placement choice as interpretation.
     - Later removed → respect the removal; skip the hunk.
   - **Target context exists but with evolved surrounding text** → surface the divergence. Don't reshape the hunk to fit; don't reshape the file to fit the hunk.

4. **Report-back when allocation fails.** Failure surfaces with: which hunk, what it adds/changes/removes, why the target doesn't fit, and the available paths (apply at inferred location, skip, manual resolve, etc.). Never silently drop a hunk or silently reshape it.

5. **Precise sanity checks, not greedy ones.** Use canonical detection mechanisms (`git diff --diff-filter=U` for unmerged paths, `git ls-files -u` for index conflicts, `git status --porcelain`) - never ad-hoc grep for marker strings that legitimate content may contain. A script that documents `<<<<<<<` as a conflict marker will trip a greedy grep every time and mask real signals.

6. **Doc claims must match code reality.** When adapting docs that describe runtime behavior of code that was just added/changed, verify the code matches the asserted behavior BEFORE asserting it in docs. If a source repo's doc claim is wrong or concerning (e.g. describes silent-fail-as-feature), rewrite the doc to the correct behavior AND surface that the code may need verification/fix. Don't propagate prose verbatim across repos without verifying its assertions hold.

7. **Don't aggregate failure modes.** "Cherry-pick failed" can mean: invalid refspec, content conflict, hook rejection, network timeout, identity mismatch, locked ref, half-applied prior state. Always isolate the exact mode before retrying - retrying a network failure with the same code that masked an identity issue burns cycles without progress.

## Operational recipe

When invoked, for each commit being reconciled:

1. **Inspect the diff** via `git diff --stat <commit>^..<commit>` and per-file `git diff <commit>^..<commit> -- <file>`.
2. **Try the mechanical apply** via `git cherry-pick --no-commit <commit>`.
3. **For each file in conflict** (canonical check: `git diff --name-only --diff-filter=U`):
   - Reset our copy of that file (`git checkout HEAD -- <file>`) to discard the conflict-markered version.
   - Inspect each hunk the commit wanted to land in that file (`git diff <commit>^..<commit> -- <file>`).
   - For each hunk, locate its target context in our current file:
     - **Found verbatim:** apply the hunk textually.
     - **Not found:** check history (`git log --all -S '<anchor-phrase>'`) - is the concept dropped or never landed?
       - Never landed → place at semantically-natural slot, flag as interpretation.
       - Dropped → skip hunk.
       - Evolved context → STOP and report back to the user with the specific hunk + the current text + the options.
   - Stage the file when all hunks resolved.
4. **Other files** (auto-merged by cherry-pick) - let them go through as-is.
5. **Sanity gate:** `git diff --name-only --diff-filter=U` must be empty before commit. No greedy grep.
6. **Commit** via `git commit-tree` preserving original author/date/message (if doing a replay with metadata preservation) OR via `git commit` if doing a regular cherry-pick.

## Use in the v4rian auto-rebase ladder

The auto-rebase pass that fires after every dev advance cuts a fresh `pool/nN.reconcile.<short>` candidate off the new dev tip and cherry-picks the original pool's commits onto it. On a clean apply the candidate goes straight to a comment on the existing PR. On a conflict the L1-L5 ladder invokes this skill per-hunk: L1 = mechanical cherry-pick, L2 = file-scope reset + per-hunk allocation per the recipe above, L3 = whole-file rewrite with hunk-context preserved, L4 = three-way merge with a chosen ancestor, L5 = surface to the admin with the unresolved hunks named explicitly. The reconcile branch is pushed as a CREATE (CI fires on the new ref) and a comment lands on the existing PR - the original pool branch and PR are never rewritten.

## Reference incident (origin)

During an early how-git replay session, a docs-catch-up bak commit had two README hunks. The target README had evolved past the bak's parent state through five intermediate pool merges, which reshaped the same paragraphs. Hunk 1's target context paragraph existed but with different surrounding text; hunk 2's target context matched exactly.

First attempt aggregated the decision ("README conflicts; abort"). Second attempt over-extended a greedy grep sanity check that matched legitimate `<<<<<<<` literals in a test-suite script and aborted falsely. Third attempt isolated each hunk's allocation, checked history with `git log -S` to confirm the concept was never landed in the chain (so it was a NEW introduction, not a re-add of dropped content), placed the new sentence at the inferred slot matching the original commit's section ordering, and surfaced the interpretation explicitly for user confirmation.

The doc claim in the new sentence was additionally rewritten to surface persistent failures because the original claim documented silent-fail-as-feature - a violation of rule 6.

## Cross-references

- [[git-snapshots]], [[git-shuttle]] - orchestrators that may invoke this skill on a per-commit basis during a replay
- [[git-history-preservation]] - the gate; never reconcile across user-authored commits without explicit authorization
- [[git-commit-audit]] - apply the commit-audit lens to the resulting commit after the reconciliation lands
- [[git-merge-audit]] - apply the merge-audit lens to any merge commit the reconciliation produces
