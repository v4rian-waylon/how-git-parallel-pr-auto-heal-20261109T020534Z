# Contributing

This repository is the v4rian git framework that downstream projects
install from. Most contributions take one of two forms.

## What "commit" means here

A commit is a commitment. The word literally is "commit" - when you
push, you stake your name on the change. Local working trees exist
precisely so you can iterate freely without that weight; the moment
you push, the bar is the bar.

- **Every test must exercise behavior end-to-end.** Spin up a scratch
  repo, run the actual script, observe the actual output, assert the
  actual post-conditions. Structural tests (grep file contents for key
  strings) are acceptable as additional regression guards layered on
  top of behavioral tests - never as a substitute. "Faster" is not a
  justification for losing rigor.
- **Claude-driven judgment steps stay claude-driven.** Where the
  framework calls `claude_skill_run` for AI judgment (auto-rebase
  L1-L5 reconcile, snapshot preflight audits, strategy audits), that
  judgment is the differentiator. Never replace it with a deterministic
  shortcut. If you must refactor, surface the AI touchpoint in the PR
  body so reviewers see exactly what is being preserved or removed.
- **Polish locally; push only what holds.** The ability to work
  locally without pushing makes the act of pushing all the more
  deliberate. Don't push code you'd be embarrassed to review.

Subpar code on this repository is not acceptable. CI gates exist to
catch regressions, not to be the bar.

## Reporting a bug or proposing an improvement

Open an issue describing what you saw vs what you expected. If the bug
is in a shipped script or hook, include the script name, the command
you ran, and the output. If the proposal is a new operator binary or
script, describe the maintainer workflow that motivates it.

## Sending a change

Branches follow the v4rian model:

- `pool/nN.<kind>.<short-name>` for working branches, optionally under a
  `pool/vYYYY.MAIN/` series prefix (`kind` is one of `feature`, `fix`,
  `r&d`, `refactor`, `reconcile`, `doc`).
- Paired `safety/nN.<kind>.<short-name>` anchor branches.
- The branch allocator (`bin/create-pool-branch`, which dispatches the
  `allocate-pool-branch` GitHub Actions workflow) is the canonical way
  to create both, but during early bootstrap of this very template you
  may cut them manually.

Each PR targets `dev`. Every commit:

- Uses one of the canonical tag prefixes: `[NEW]`, `[FIX]`, `[REFACTOR]`,
  `[DOCS]`, `[TEST]`, `[REVERT]`, `[HOTFIX]`, `[MERGE]` (tools alone write
  `[REQ]` and `[MODE]`; cleanup is `[REFACTOR]`, there is no `[CLEANUP]`).
- Has no `Changes:` header; bullets follow the description directly.
- Carries a sentence-case title, aiming for 72 characters; the
  `commit-msg` hook hard-limits it to 8-100 (140 for `[MERGE]` and `[REQ]`).
- Contains a one-to-three sentence description paragraph followed by
  bullets that name the actual symbols changed.
- Skips placeholder or speculative content; only the diff is the diff.

The Step 2 commit stage splits enforcement across two layers. Locally,
the `pre-commit` hook scrubs em-dashes and en-dashes from staged
files, the `prepare-commit-msg` hook runs the deterministic auto-fix
library that rewrites the message in place (dash scrub, banned-word
replacement, tag derivation, sentence cap, third-person bullets), and
the `commit-msg` hook keeps only the cheap 8-100 char subject-length
guardrail. The `pre-push` hook is the branch-name regex guardrail and
nothing more. Asynchronously, `.github/workflows/ci-dispatch.yml`
fans out every `ci/{tests,audits}/<trigger>/*.sh` script as a
separate status check on the matching trigger; the framework's own
pr-open audits ship under the sys layer as `required.commit-audit.sh`,
`required.compile.sh`, `required.coverage.sh`, `required.runtime.sh`,
and `required.offline-test-suites.sh` so the dispatcher posts them as
`required.commit-audit`, `required.compile`, `required.coverage`,
`required.runtime`, and `required.offline-test-suites`, and the dev
branch ruleset binds those plus `reconcile` (posted by
validate-pr-open / auto-rebase) - six contexts total - as required
status checks on PR merge. bootstrap-ci-steps branch protection
additionally binds `opened-via-correct-flow` (posted by
validate-pr-open). No `claude` CLI
is required at commit or push time.

The Step 3 PR-open stage shields the PR shape at open time. Use
`bin/init-pool-merge` (for `pool/*` to `dev`) or `bin/init-release`
(for `dev` to `main`) to open PRs from your shell; both wrappers
dispatch `gh pr create` with the `.github/PULL_REQUEST_TEMPLATE.md`
skeleton (or the CHANGELOG `## Unreleased` section, in the release
case). Either path triggers `validate-pr-open.yml` server side, which
auto-amends the title to the canonical version-aware form, runs the
shared auto-fix pass over the body, embeds the `opened-via-correct-flow`
signature, and posts the matching status check. Opening through
GitHub's native "Compare and pull request" button works identically;
the workflow does not care which entry point you used.

When a gate goes red on your PR (a required check, the commit audit,
a test suite), the fix continues ON THE SAME pool branch: push further
commits and the PR re-runs its gates on the new head. A rejected
commit MESSAGE in pushed history is amended in place and pushed with
`--force-with-lease` to the same branch (your unmerged sandbox is
yours to correct). Do not request a new branch allocation for a retry
of the same work, and do not close the PR to supersede it with a
sibling branch; one unit of work lives on one pool branch until the
admin merges or rejects it. You never delete branches - yours or
anyone else's; your branch is a sandboxed dropbox the workshop retests
and archives on its own authority. The server rejects developer
deletions of pool refs.

## Running the test suite

Before pushing:

```
LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh
LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/framework-tests/test-hooks.sh
```

GitHub Actions reruns both suites on every PR via the `offline-test`
workflow; a red check there blocks merge.

## After your PR lands

The dev claim flow tags the merge commit with the current dev version,
then auto-rebases the remaining open pool branches against the new dev
tip. Conflicts trigger the reconcile flow (L1 through L5 retry
ladder). No manual rebase is required on your end unless the reconcile
flow opens a follow-up PR.
