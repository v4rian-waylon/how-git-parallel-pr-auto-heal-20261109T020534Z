# v4rian git RUNBOOK

The one-page operator cheat sheet. Every command assumes you're at the repo root and `core.hooksPath` is set (run any in-repo script once to auto-activate, or `bash .io.v4rian.how-git/scripts/heal.sh`).

## See where you are

```bash
.io.v4rian.how-git/bin/status           # human-readable
.io.v4rian.how-git/bin/status --json    # machine-readable
```

Reports: current branch + sha, current version (`vYEAR.SERIES.DEV` seal), latest tag, ahead/behind vs origin, open-PR count, dev claims this year, current mode (`connected` or `off-grid`).

## Modes (connected vs off-grid)

Every v4rian repo runs in one of two modes, tracked in `.io.v4rian.how-git/MODE`:

```bash
.io.v4rian.how-git/bin/set-mode --get      # print the current mode
.io.v4rian.how-git/bin/set-mode off-grid   # flip to off-grid (local, no GitHub admin needed)
.io.v4rian.how-git/bin/set-mode connected  # flip back (GitHub admin-gated)
```

The flip lands as a normal `[MODE] switch to <new>` commit on the checked-out branch. In connected mode the admin gate runs against the GitHub permission API; in off-grid mode the gate is advisory (the operator is trusted; admins.txt is the only durable allowlist when no remote is authoritative).

Per-mode entry-point matrix:

| Step | Connected | Off-grid |
|---|---|---|
| Allocate pool/safety pair | `bin/create-pool-branch` -> allocator workflow | `bin/create-pool-branch` runs the allocator locally: fetches the tracked remote first, refuses shallow and single-branch clones (see [Off-grid allocation](#off-grid-allocation)) |
| Open pool to dev PR | `bin/init-pool-merge` | refused (no remote PR concept) |
| Pool to dev merge | GitHub UI button | `git merge --no-ff <pool> -m "..."` then `bin/finalize-pool-merge` |
| Pool to dev claim ceremony | `claim-on-merge-dev` workflow runs `claim-dev-merge.sh` in CI | `bin/finalize-pool-merge` runs `claim-dev-merge.sh` locally |
| Open dev to main release PR | `bin/init-release` | refused |
| Dev to main merge | GitHub UI button | `bin/ship` (merges at dev tip's committer date and runs claim locally; --skip-push for LAN/air-gap) |
| Dev to main claim ceremony | `claim-on-merge-main` workflow runs `claim-main-release.sh` in CI | `bin/ship` invokes `claim-main-release.sh` locally |
| Apply Repository Rules | `bin/bootstrap-ci` (delegates to `apply-repo-rules.sh`) | refused (no remote governance) |

Whichever mode is wrong for the step you're attempting refuses with a message that names the correct mode and the `bin/set-mode` command to flip.

## Merge policy and warp mode (pool to dev)

```bash
.io.v4rian.how-git/bin/set-merge-policy                       # print policy + warp state
.io.v4rian.how-git/bin/set-merge-policy dev_merge_who=list dev_merge_list=lead@example.com
.io.v4rian.how-git/bin/set-merge-policy dev_merge_approval=required dev_merge_gates=required.compile
.io.v4rian.how-git/bin/warp on      # prototyping: pool -> dev without PRs (admin-gated)
.io.v4rian.how-git/bin/warp off     # back to MERGE_POLICY
```

Both commands commit a `[MODE]` change on the checked-out branch; push it through your normal flow. With `dev_merge_approval=required` an off-grid merge body carries the trailer before `bin/finalize-pool-merge` runs:

```bash
git merge --no-ff <pool> -m "[MERGE] <pool> into dev" -m "Approved-by: reviewer@example.com"
.io.v4rian.how-git/bin/finalize-pool-merge
```

Warp never lifts `dev_merge_gates` and never touches dev to main. In connected mode a direct push to dev under warp or `dev_merge_pr=optional` also needs the server-side dev ruleset to allow it; approval and who on connected PRs are announced by `bin/init-pool-merge` and enforced nowhere (no hook runs on a GitHub-side merge; dev protection sets `required_pull_request_reviews=null`; warp writes no server rule). A consumer starts with warp off: `bin/attach` resets `WARP`, `bin/sync-framework` never migrates it.

## Get the version of the current commit

```bash
.io.v4rian.how-git/bin/version              # vYEAR.SERIES.DEV-<sha7>.<build>  (with build counter)
.io.v4rian.how-git/bin/version --seal       # vYEAR.SERIES.DEV  (no SHA/build suffix)
.io.v4rian.how-git/bin/version --next-dev   # what the next pool to dev merge would claim
.io.v4rian.how-git/bin/version --build      # same as default, but increment local build counter first
```

The build counter is per-clone (`version.build` file, gitignored). Reset with `--reset`.

## Develop a feature

```bash
# Allocator workflow creates pool/nN + safety/nN pair atomically.
# Dispatch from a local admin shell (calls `gh workflow run` under the hood):
.io.v4rian.how-git/bin/create-pool-branch parser-rewrite --jira PROJ-123 --kind feature \
  --requirement "Rewrite the parser to handle nested blocks per spec section 4.2."
# Branch kinds: feature, fix, r&d, refactor, reconcile, doc (kind classified
# from the JIRA payload when --kind is omitted).
# The --requirement text becomes the body of the initial [REQ] commit
# on the pool branch AND is written to .io.v4rian.how-git/requirements/<pool ref, / as __>
# so auditors (auto-rebase L1-L5 ladder, post-checkout preflight) can fetch
# the branch's canonical intent before invoking claude. Alternatives:
#   --requirement-file ./req.txt   read from a file
#   (JIRA Automation passes it through client_payload.requirement)
git fetch && git checkout pool/n7.feature.PROJ-123-parser-rewrite
# ... edit, commit ...
git push origin pool/n7.feature.PROJ-123-parser-rewrite
.io.v4rian.how-git/bin/init-pool-merge             # opens PR into dev via the template
```

### Off-grid allocation

In off-grid mode `bin/create-pool-branch` runs `scripts/allocate-pool-branch.sh` locally and the pair is created with one `git update-ref --stdin` transaction at local `dev`. The allocator never reissues a number it can see; the next number is 1 + the highest number already spent, read from:

- `pool/`, `safety/` and `vault/` refs, local heads plus the remote tracking refs of the tracked remote. That is `branch.dev.remote`, else `origin`, else the only remote; any fallback other than unset to `origin` (for example `dev` tracking a local branch, which git records as `.`) prints which remote it counts, and several remotes without `origin` print that only local refs count. A second remote (the framework, a fork) is never counted;
- landing subjects `[MERGE] pool/.../nN. ...` in local branches, tags, that remote and HEAD, matched on the branch name only, so a path such as `docs/n9000.md` spends nothing;
- reservations `refs/how-git/allocated/nN`, one per number handed out off-grid.

Before counting, the allocator:

- exits 2 in a shallow or a single branch clone, because either hides spent numbers, and prints every repair in one line (a `--depth 1` clone gets `Run: git remote set-branches origin '*' && git fetch --unshallow origin`);
- fetches the tracked remote with no prune and no prompt, under a watchdog that ends the whole fetch after `ALLOC_FETCH_TIMEOUT` seconds (30 by default). When the fetch fails or times out it still allocates and prints `offline: could not fetch 'origin'; counting refs as of <the last fetch (time) | the clone (time) | an unknown time>`; `--no-fetch` (or `ALLOC_NO_FETCH=1`) skips the attempt on an air gapped clone and prints the same staleness notice.

Reservations: allocations racing in one clone (lanes are worktrees and share refs) never share a number, because the reservation is created in the same transaction as the pair; the loser's transaction fails whole, and it recounts and retries. A reservation points at dev's root commit, so after a dev rewrite it keeps at most that old root (a few objects, never a history) alive until it is pruned. It lives outside `refs/heads`, so a normal push or fetch never carries it, and the pre-push hook refuses any push that would (`git push origin refs/how-git/...`, `git push --mirror`); a delete still passes, to clean a leaked one off a remote. After each allocation the reservations below the highest number the tracked remote (its refs and landing subjects) or a local vault ref records are pruned, except the one that allocation just made.

Two separate clones are serialized only by the fetch: a clone that allocates before fetching what another clone pushed can still pick the same number, so push the pair right after allocating. Connected allocation reads refs through the API and the landing subjects from the workflow's full history checkout (`fetch-depth: 0`).

`bin/init-pool-merge` dispatches `gh pr create` with the PR body skeleton from `.github/PULL_REQUEST_TEMPLATE.md`. After dispatch, the `validate-pr-open.yml` workflow amends the title to `[KIND] vYYYY.X.Y: <short>` derived from `bin/version --next-dev`, runs the shared auto-fix pass over the body, embeds the workflow signature, and posts the required `opened-via-correct-flow` status check. Pass `--edit` to open `$EDITOR` with the template pre-loaded; `--dry-run` shows the dispatch without calling the API.

### File a JIRA ticket from a casual prompt or from explicit fields

`bin/jira-ingress` is the ingress point for tickets entering the lifecycle via JIRA. It is NOT the only path into the lifecycle (the allocator accepts direct admin invocation without any JIRA key per `feedback_jira_is_integration_not_component`); it is the JIRA-integration path. Two operating modes:

```bash
# Manual mode: you compose the fields. The script validates them against
# the same lens git-commit-audit applies to commit titles + bodies before
# filing the ticket, so the ticket text matches the eventual commit message.
.io.v4rian.how-git/bin/jira-ingress \
  --title "[NEW] Add backup verification step to ship workflow" \
  --body "Adds a verification step to bin/ship that confirms the dev-tip backup landed before the main merge." \
  --kind feature \
  --sprint 5                          # omit to land in backlog

# Claude-driven mode: a casual one-liner is enough. claude reads
# git-commit-audit + git-strategy-audit and composes a spec'd title /
# body / kind. If the prompt leaves a gap (the parser is named, the
# subsystem is ambiguous), claude surfaces a QUESTION: line that the
# ingress tool relays to the operator (interactive read when stdin is a
# TTY, batched --answers <file> for non-interactive runs), then re-invokes
# until the payload is complete.
.io.v4rian.how-git/bin/jira-ingress \
  --prompt "fix the off-grid e2e seeding from main instead of dev" \
  --sprint 5

# Preview without filing (no acli or JIRA Automation required):
.io.v4rian.how-git/bin/jira-ingress --prompt "..." --dry-run
.io.v4rian.how-git/bin/jira-ingress --title "..." --body "..." --kind feature --no-submit
```

**Sprint routing.** No `--sprint` lands the ticket in the backlog. An active `--sprint <N>` binds the ticket to that sprint via the JIRA Cloud custom-field path (default `customfield_10020`; override via the `JIRA_SPRINT_FIELD` env var when your instance uses a different id) so the existing JIRA Automation rule that watches in-sprint creates fires `gh workflow run allocate-pool-branch.yml` to spawn the pool + safety pair against the framework repo. The dry-run output names the JIRA Automation expectation so a missing Automation rule surfaces upfront rather than as a silent miss.

**Off-grid awareness.** When `bin/set-mode --get` returns `off-grid`, JIRA is by design unreachable. The ingress tool still renders a spec'd ticket and saves it to `.io.v4rian.how-git/.local/jira-drafts/<UTC stamp>.md` so the operator can paste it into JIRA later; it also suggests a JIRA-less branch name and the `bin/create-pool-branch <slug> --no-jira --kind <K>` recipe so the lifecycle can advance against the rendered ticket without waiting for a real JIRA key.

**acli dependency.** The submit backend is the official Atlassian CLI `acli` (https://developer.atlassian.com/cloud/acli/). Install once on macOS via `brew tap atlassian/homebrew-acli && brew install acli`; authenticate once via `echo <token> | acli jira auth login --site "<site>.atlassian.net" --email "<you>@example.com" --token`. The ingress tool emits a precondition banner with these exact commands when `acli` is not on PATH; it never auto-installs. Render-only paths (`--no-submit`, `--dry-run`, off-grid mode) work without `acli`.

### Active requirement: what claude reads when an auditor invokes it

Every pool branch carries a canonical "active requirement" document - the verbatim text the allocator received from JIRA Automation, the workflow_dispatch UI, the CLI wrapper, or claude itself. The text is stored in two equivalent places that travel with the branch:

- `.io.v4rian.how-git/requirements/<pool ref with / as __>` (tracked file at the branch tip, one per lane so parallel lanes never collide)
- Body of the initial `[REQ] active-requirement: <branch>` commit on the pool branch (rule-scrubbed; the file keeps the verbatim text)

Auditors that spawn claude (the auto-rebase L1-L5 ladder, the post-checkout preflight) fetch the requirement via `.io.v4rian.how-git/scripts/get-active-requirement.sh <branch>` and prepend it to every claude prompt. The script tries the lane's file first (cheap), falls back to the `[REQ]` commit body, then to the legacy shared `.io.v4rian.how-git/active-requirement` older lanes carry, and exits 0 with empty stdout when neither is present (legacy branches that predate this step - claude is invoked without the extra context).

Direct ad-hoc claude conversations that want to fill in the requirement before dispatching the allocator should compose it themselves and pass it via `--requirement` to `bin/create-pool-branch`.

## Land a feature (pool to dev)

**Connected mode** (default; PR merged via GitHub UI):

```bash
# After the PR merges via the GitHub UI, the claim-on-merge-dev workflow
# runs claim-dev-merge.sh on the remote side automatically. It amends
# the merge subject to [MERGE] pool/X into dev: vYYYY.X.Y, force-pushes
# dev, tags, and archives the pool to vault.
```

**Off-grid mode** (admin drives the merge locally):

```bash
git checkout dev
git merge --no-ff pool/n7.feature.PROJ-123-parser-rewrite -m "your body"
.io.v4rian.how-git/bin/finalize-pool-merge        # admin-gated; amends + tags + vaults
```

What happens (either mode): `bin/version --seal` computes the new tag, the merge subject is amended to the spec form, the merge commit is annotated-tagged, the archive script vaults the merged pool branch. The auto-rebase pass then walks every open pool→dev PR: for each, it updates the PR title's aspirational version, cuts a `pool/nN.reconcile.<short>` candidate branch off the new dev tip, cherry-picks the pool's commits onto it (claude L1-L5 ladder on any conflict), and **comments on the existing PR** with the reconcile candidate and a recap. The auto-rebase **never force-pushes** the developer's pool branch and **never closes or opens** any PR - admin is the sole merge decider on dev (see `feedback_how_git_never_rewrites_history`).

**Reconcile-merge dual-vault.** When the merged source ref is a `pool/[<major>/]nN.reconcile.<short>` candidate (rather than the original `pool/[<major>/]nN.<kind>.<short>` itself), the close-up archives BOTH branches in the same pass. The reconcile gets vaulted to `vault/[<major>/]nN.reconcile.<short>` as usual, and the corresponding original `pool/[<major>/]nN.<kind>.<short>` on origin (identified by matching the `nN` counter plus the `<short>` slug, excluding `kind=reconcile`) is also vaulted to `vault/[<major>/]nN.<kind>.<short>` and deleted from the pool namespace. The two vault refs together record both "what the developer originally pushed" and "what the auto-rebase pass reconciled onto the new dev tip that ultimately landed." If the matching original is already vaulted from a prior pass the dual-vault probe logs the absence and continues; if more than one non-reconcile candidate matches the same `nN` + `<short>` (which the allocator's uniqueness invariant should prevent) the probe surfaces a loud stderr error naming every candidate and skips the additional vault so an admin can decide manually.

### Claim safety (what the claim will and will not do)

- **Sync with origin dev.** Without `--skip-pull` the claim fetches origin dev and only fast-forwards. A local merge not pushed yet is kept and published by the claim. The one divergence adopted is the amended twin (same tree, same parents: a CI rerun of a merge already amended on origin); any other divergence is refused with the commits on each side listed, in every environment (no `CI` or `GITHUB_*` variable authorizes dropping a commit). An adoption prints the dropped local author and message and the `git branch` command that keeps the commit. `--dry-run` never fetches or moves anything.
- **Dirty tree.** Untracked files (a local `FEATURE_REQUESTS.md`, notes) are left in place. Staged, modified or conflicted tracked files are refused, because the amend would fold them into the published merge; the refusal prints the exact `git stash push -- <paths>`, rerun and `git stash pop` lines. Any path the sync would overwrite that dev does not track (an untracked or ignored file, or a file where origin adds a directory) is refused by name with a `mv` line. Nothing is ever stashed for you.
- **Publish before tag.** dev is pushed first on every path (pool subject or not), moving origin dev only forward or onto the amended twin of the same merge; another merge already on origin dev stops the claim before any tag. Tags reach origin only once origin dev carries their commits, and every claim pushes each claim tag on dev that origin lacks, so a rejected tag push is repaired by the next claim. A claim tag is an annotated `vN.N.N` tag; lightweight tags never leave the clone. Publishing is add-only: a claim tag deleted on origin while it still seals a merge on dev comes back at the next claim. An unreachable origin fails the claim with no tag; rerun once it is back.
- **Hooks off.** If `core.hooksPath` is unset, git runs the default hooks dir, where a fallback `post-merge` warns, restores `core.hooksPath` and runs the claim. It is installed by `heal.sh`, `bin/set-mode`, `bin/finalize-pool-merge`, `bin/ship`, the claim scripts and every script that activates the hooks; `bin/doctor` reports it missing. A fresh clone has none until one of those runs, so run `heal.sh` once after cloning. A consumer's own `post-merge` there is never overwritten (then run `bin/finalize-pool-merge` by hand). Known gap, owned by its own pool: in a linked worktree (`git worktree add`) git hands hooks a `GIT_DIR` that makes the hook-driven claim see the whole tree as modified and refuse; run `bin/finalize-pool-merge` from that worktree by hand.
- **Tag holes.** Every dev merge spends a version number, pool or not: counting merges is the primitive that keeps numbering from silently reshuffling, and a merge cannot be refused once it has landed. So a non-pool merge, or one whose claim never ran, is not made impossible; it is healed. Each claim walks dev's merges (across releases, continuing at the dev tip each release shipped) and seals every untagged one newer than the first claim tag with the number it spent, in its own year and cycle (`bin/version --seal --at <merge>`), before any tag push. Before judging holes the claim fetches origin's claim tags it lacks (the dev fetch never follows tags), creates them only where no local tag exists, refuses when a same-named local tag differs or the fetch fails, and never mints a name origin already holds. Tags are only added, never moved; merges older than the first claim tag (history from before the framework) are left alone. A hole whose committer year is not today's is sealed in the year it counted in, with a notice. The first claim on a repo with past holes seals all of them at once, so expect several new tags in that run. A merge into main that dev never took is outside the model (main only receives dev) and makes the live seal and `--seal --at` disagree.

## Rebase local pool branches onto dev

```bash
.io.v4rian.how-git/bin/sync-pools --dry-run   # list unpushed pools behind dev
.io.v4rian.how-git/bin/sync-pools             # snapshot each tip, rebase onto dev
```

Only pools without `origin/<branch>` are touched; the old tip stays at
`safety/<branch>-<YYYYMMDD-HHMMSS>`. On a conflict the rebase is left in
progress and the tool prints the finish, abort (`git rebase --abort &&
git checkout <start>`) and restore (`git branch -f <branch> <snapshot>`)
commands; re-run it afterwards for the remaining branches.

## Collect released safety snapshots

```bash
.io.v4rian.how-git/bin/gc-safety              # dry run: what would go
.io.v4rian.how-git/bin/gc-safety --apply      # bundle to ~/.Trash/git-branch-trash, verify, delete
```

Collected: Pattern-2 `safety/<branch>-<timestamp>` refs whose tip is in
dev and whose pool has a `vault/` ref. Kept: every Pattern-1 allocator
anchor and anything unmerged or unvaulted. Restore with the printed
`git fetch '<bundle>' 'refs/heads/safety/*:refs/heads/safety/*'`.

## Install the agent hooks (Claude Code, Codex)

```bash
.io.v4rian.how-git/bin/install-agent-hooks --dry-run              # what would change
.io.v4rian.how-git/bin/install-agent-hooks [--claude] [--codex]   # neither flag = both
.io.v4rian.how-git/bin/install-agent-hooks --uninstall            # remove exactly what was added
.io.v4rian.how-git/bin/install-agent-hooks --prefix "$TMPDIR/home" # fake home for a trial
```

Codex: open `/hooks` and trust the two how-git hooks; until then only
`rules/how-git.rules` and the `AGENTS.md` block apply. Before a
destructive git op an agent runs
`<agent home>/hooks/how-git/git-preflight.sh <repo> "<reason>"` (or
chains it with `&&`); the deny reason names the exact command. Zips go
to `$HOW_GIT_BAKS_DIR` (default `~/.how-git/baks`).

## Ship a release (dev to main)

**Connected mode** (admin merges manually after status checks pass):
```bash
git checkout dev && git pull
.io.v4rian.how-git/bin/init-release          # opens the release PR with body pre-filled from CHANGELOG Unreleased
# admin reviews + merges via the GitHub UI once every required check is green
# claim-on-merge-main workflow runs claim-main-release.sh on the remote side automatically
```

`bin/init-release` extracts the `## Unreleased` section from `docs/CHANGELOG.md` and pre-fills the PR body so the release report carries the curated narrative that landed cycle by cycle on dev. The `validate-pr-open.yml` workflow runs body shielding and posts the `opened-via-correct-flow` status check; the canonical merge subject `[MERGE] dev into main: vYYYY.X` is derived at claim time from `bin/version --release-tag`.

**Off-grid mode** (admin drives the full release locally):
```bash
.io.v4rian.how-git/bin/ship                  # admin-gated; refuses in connected mode
# --skip-push lets it run with no remote (LAN/air-gap):
.io.v4rian.how-git/bin/ship --skip-push
```

Equivalent to:
```bash
git checkout main && git pull --ff-only origin main      # skipped with --skip-push
git merge --no-ff dev -m "[MERGE] dev into main: $(bin/version --release-tag)"
git push origin main                                      # skipped with --skip-push
bash .io.v4rian.how-git/scripts/claim-main-release.sh --skip-pull
```

What happens (either mode): the release REUSES the existing dev tag (same code = same version). A GitHub Release object is attached via `gh release create` in connected mode (skipped in off-grid `--skip-push`). The tag build (`ci-dispatch.yml` tag trigger, admin rebuild via `build-on-tag.yml`) builds the artifact once (at dev-tag time) and uploads it under `build/artifacts/`; the later distribution step attaches the same bytes to the Release on main promotion without rebuilding. Safety anchors are never touched: under the stay-forever rule every `safety/` ref persists for the life of the repo regardless of whether the paired pool branch was released, is in flight, or was abandoned.

### Open work pool branches at release

Every dev to main merge commit closes its body on an `## Open work pool branches at release` section listing the pool branches that were still in flight at the moment of the release cut. The section is appended by `claim-main-release.sh` after the PR backreference and the PR-body recap, so the reader scans subject downward through narrative and ends on the in-flight roster.

Each row is one open pool branch, ref name column-aligned, with the first commit date and the last commit date separated by a hyphen:

```
## Open work pool branches at release

pool/v2026.0/n2.feature.alpha       2026-01-15 - 2026-01-15
pool/v2026.0/n3.fix.bravo           2026-02-20 - 2026-03-04
pool/v2026.0/n4.refactor.charlie    2026-03-05 - 2026-03-05
```

The dates use ISO 8601 short form (`YYYY-MM-DD`) via `git log --format='%cs'`. Rows are sorted ascending by first-commit-date so the oldest open branch is at the top and the most recently allocated is at the bottom.

Sourcing rules (handled by `list_open_pool_branches` in `scripts/_lib.sh`):

- **Source ref space.** Connected mode reads from `refs/remotes/origin/pool/*` so the view matches what the remote considers open at release time. Off-grid mode reads from `refs/heads/pool/*`.
- **Exclusions.** Reconcile sub-branches (`pool/v*/n*.reconcile.*`) are dropped; they are transient rolling pointers produced by the auto-rebase ladder, not developer-authored open work (see `feedback_how_git_never_rewrites_history`). Branches whose tip is already reachable from main are dropped; the release merge may have brought them in, so they are no longer open.
- **First-commit-date.** The date of the first commit on the pool branch that the paired `safety/` anchor does not contain. When the allocation carries zero commits beyond the anchor, the safety anchor's own committer date is used so empty allocations stay honest. When no safety pair exists (rare; branches that bypassed the allocator), the fallback is the first commit reachable from the pool ref not reachable from main.
- **Last-commit-date.** The pool tip's committer date.
- **Empty case.** When no pool branches are open at release, the section still renders, followed by the literal line `(no open work pool branches at release)`, so the section's existence is verifiable on every release regardless of in-flight count.

## Find which release contains a commit

```bash
.io.v4rian.how-git/bin/release-of <commit-sha>
.io.v4rian.how-git/bin/release-of HEAD
```

Returns the earliest release tag whose ancestor set includes the commit, or `unreleased (...)` if the commit isn't on main yet.

## Heal drift

```bash
bash .io.v4rian.how-git/scripts/heal.sh           # re-set hooks path, chmod, warn on stray VERSION
bash .io.v4rian.how-git/scripts/heal.sh --dry-run # preview
```

Idempotent. Run when state has drifted (overwritten hooks config, stripped exec bits, etc.). NOT a first-time-install: the template auto-activates on first script call.

## Build a tag's artifact (workflow or local)

```bash
# Workflow path (every v* tag push builds through ci-dispatch.yml automatically):
gh workflow run build-on-tag.yml -f tag=v2026.0.7   # admin manual re-build

# Off-grid CI path (same checks as the workflow, on the checked out tag):
git checkout v2026.0.7 && .io.v4rian.how-git/bin/ci-local --workflow build-on-tag

# Local path (useful for verifying build.sh changes before pushing):
git checkout v2026.0.7
TAG=v2026.0.7 bash .io.v4rian.how-git/scripts/build.sh
ls build/artifacts/                                  # output contract path

# Idempotency probe (returns 0 if output already present, 1 otherwise):
TAG=v2026.0.7 BUILD_IDEMPOTENCY_CHECK=1 bash .io.v4rian.how-git/scripts/build.sh
```

## Manual CI entries and their off-grid twins

`audit-pushed-branch.yml`, `dev-merge.yml`, `main-merge.yml` and `build-on-tag.yml` are admin-only `workflow_dispatch` callers of `ci-dispatch.yml`; `bin/ci-local --workflow <name>` runs the same trigger locally. Both are re-runs for reading and repair: a manual run's checks report as `<job> / <check>` on the dispatch ref's SHA and `ci-local` results never reach GitHub, so neither satisfies a PR required check; only the push run of the head SHA does (re-run that `ci-dispatch.yml` run to re-green one).

The claim twins are live operations, not dry runs, so ci-local runs a claim only with `--allow-claim`: without it every `required.claim` (or consumer `claim.sh`) is listed as SKIP and `--only` on one is refused, so a pre-merge `ci-local --trigger pr-merge-dev` never claims. `bin/ci-local --workflow dev-merge --allow-claim` (or `main-merge`) runs `required.claim.sh`, which tags HEAD and force-pushes dev (or main) with a lease when an origin exists; HEAD must be on that branch. On the framework source repo the usr and sys layers both list `required.claim`, so the claim runs twice; the second pass resumes the sealed claim and changes nothing.

`build.sh` is the single source of truth for the build. The template
ships a project-type dispatcher (Node, Qt/CMake, template-self);
consumer projects override it in their fork with their real recipe.
Output ALWAYS lands under `build/artifacts/` so the distribution
bundle (separate from build) can find it. The workflow retries up to
eight times with exponential backoff capped at five minutes, and
skips the build entirely when the idempotency probe says output is
already present for the target tag.

## Verify the template is intact

```bash
bash .io.v4rian.how-git/scripts/verify-template.sh
```

Runs the static + behavioral invariants. Pass means the template is functional.

## Run the full offline test suite

```bash
bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh           # ~30s, all simulators
bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh --verbose
bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh --filter M3   # one test
bash .io.v4rian.how-git/framework-tests/test-hooks.sh               # regex + version-bin structural checks
bash .io.v4rian.how-git/framework-tests/test-agent-hooks.sh         # agent guards + install-agent-hooks (fake HOME)
```

280+ tests cover: branch-name regex, hooks wiring, all 4 ops bins, version bin math, claim scripts, archive flow, auto-rebase + reconcile, build-on-tag workflow shape + canonical build.sh dispatch + idempotency probe, gh API mock, year rollover, full consumer scaffold simulation, RC stabilization sprint coverage matrix (every landed pool/nN's normal + edge cases plus scaffolded assertions for in-flight pool/nN branches that fire when their code lands).

### Scaffold mode (pool/n93)

Tasks whose code is still in flight or queued ship their assertions as SKIP'd tests today, which lets the suite stay green while the in-flight branches mature and gives a clear roster of what is parked. Once a task's pool branch lands on dev, the post-merge claim flow re-runs the suite under `LIFECYCLE_TEST_SCAFFOLD_MODE=1` so the scaffolded assertions fire as real tests:

```bash
# Default lifecycle run: scaffolded tests register as SKIP, default lifecycle stays green
LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh

# Scaffold mode: scaffolded tests fire as real assertions, fail until the code lands
LIFECYCLE_TEST_MODE=1 LIFECYCLE_TEST_SCAFFOLD_MODE=1 \
  bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh
```

The summary block reports `<P> passed, <F> failed, <S> skipped` and prints the parked roster after the gate decision. A scaffolded assertion that fires green in scaffold mode is the signal that the in-flight branch landed and its contract is satisfied; that assertion can then be promoted from `run_test_skip` to `run_test` in the same merge that lands the underlying code.

### Coverage matrix by sprint task

Each landed pool/nN's assertions group under the `n93 coverage matrix: edge cases per landed sprint task` section in the runner. Each scaffolded pool/nN groups under the `n93 coverage matrix: scaffolds for in-flight + queued sprint tasks` section. To re-run only the n93 coverage block during local diagnosis:

```bash
LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh --filter "n93 coverage matrix"
LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh --filter n70   # one sprint task
LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh --filter n90   # one in-flight task's scaffolds
```

## Exercise the off-grid lifecycle against a real throwaway repo

```bash
.io.v4rian.how-git/bin/test-off-grid-e2e --help
.io.v4rian.how-git/bin/test-off-grid-e2e --dry-run --token <token> --account <owner>
.io.v4rian.how-git/bin/test-off-grid-e2e --token <token> --account <owner>
.io.v4rian.how-git/bin/test-off-grid-e2e --token <token> --account <owner> --keep
```

Operator-run end-to-end exercise of the off-grid lifecycle. The CLI creates a brand-new throwaway repo under `<owner>` via the GitHub "Use this template" API, bootstraps it from this framework's current origin (override with `--template OWNER/REPO`; the default is derived from `git config --get remote.origin.url` so there is no hardcoded owner/repo anywhere in the framework), flips it to off-grid mode, allocates `pool/n1.feature.offgrid-probe` locally, makes two commits, merges `--no-ff` into `dev` and pushes, runs `bin/finalize-pool-merge` for the local pool→dev close-up, then runs `bin/ship` for the local dev→main release. After each ceremony the script verifies the resulting subject is in the `[MERGE]` spec form, the expected tag landed, the pool was archived to `vault/`, and that no GitHub workflow fired against the post-ceremony SHA (the whole point of off-grid). Throwaway is deleted on success unless `--keep` is set.

This is the operator's escape hatch for proving the off-grid claim ceremonies work against a real GitHub repo where no workflow fires - distinct from the offline lifecycle suite which exercises mode flips and the off-grid refusal/acceptance matrix against scratch repos with no network. Manual operator dispatch is always available; pool/n87 also wires this CLI into `canaries.yml` for the nightly cron and the pre-release main-PR sweep (see the canary CI wiring section below).

Token + account are NEVER implicit - both must be passed explicitly even though the token would otherwise identify the actor. This is the belt-and-suspenders guard against cross-account PAT mistakes deleting the wrong repo. `--dry-run` prints every planned API call and shell command in order without executing any of them, useful for previewing a run before parting with the API budget.

## Exercise the parallel-PR auto-heal scenario against a real throwaway repo

```bash
.io.v4rian.how-git/bin/test-parallel-pr-auto-heal-canary --help
.io.v4rian.how-git/bin/test-parallel-pr-auto-heal-canary --dry-run --token <token> --account <owner>
.io.v4rian.how-git/bin/test-parallel-pr-auto-heal-canary --token <token> --account <owner>
.io.v4rian.how-git/bin/test-parallel-pr-auto-heal-canary --token <token> --account <owner> --keep
.io.v4rian.how-git/bin/test-parallel-pr-auto-heal-canary --token <token> --account <owner> --positive-only
.io.v4rian.how-git/bin/test-parallel-pr-auto-heal-canary --token <token> --account <owner> --negative-only
.io.v4rian.how-git/bin/test-parallel-pr-auto-heal-canary --token <token> --account <owner> --public --claude-token <oauth token>
```

Operator-run end-to-end exercise of the parallel-PR auto-heal feature. The CLI spawns a brand-new throwaway repo under `<owner>` from this framework's current origin via the GitHub "Use this template" API, runs `bin/bootstrap-ci` on it so branch protection plus the required status checks plus the merge-commit defaults plus the claim wiring are in place, allocates two parallel pool branches via the canonical `bin/create-pool-branch` allocator, makes commits on each that modify the same file at the same hunk so a cherry-pick from one onto a dev tip carrying the other guarantees a conflict, opens one PR per pool branch into `dev`, waits until GitHub reports each PR mergeable (every required check green, the framework suites included), merges the first PR via the API, then verifies that the `pr-merge-dev` claim run of `ci-dispatch.yml` completes green, fires `auto-rebase-pools-after-dev-merge.sh` plus cuts a fresh `pool/v<MAJOR>/n<N>.reconcile.<short>` branch for the still-open second PR plus cherry-picks the pool's commits onto the new dev tip resolving the hunk-level conflict via the L1 to L5 ladder plus pushes the reconcile branch plus comments on the original still-open PR with the reconcile candidate. Two scenarios run in sequence by default - the positive scenario asserts the reconcile branch carries the second pool branch's intent, and the negative L5 scenario synthesizes a deeper conflict so the L1 to L5 ladder plausibly exhausts strategies and the canary accepts either a clean reconcile branch or a partial reconcile branch plus a comment naming the unresolved hunks. Throwaway is deleted on success unless `--keep` is set.

The L1 to L5 ladder resolves conflicts with Claude, so the reconcile checks need `--claude-token <token>` (minted once with `claude setup-token`), which bootstrap-ci stores as the throwaway's `CLAUDE_CODE_OAUTH_TOKEN` secret. Without it each scenario checks the degraded contract instead: no reconcile branch is pushed, the second PR stays open and carries the EMPTY reconcile comment. Branch protection, rulesets and Actions are unavailable on private repos of a free plan, so pass `--public` there; the throwaway then is a public repo until you delete it.

This is the operator's escape hatch for proving the live parallel-PR auto-heal wiring against a real GitHub repo where workflows actually fire - distinct from the offline lifecycle suite which exercises the cherry-pick math and the reconcile naming chain against scratch repos with no network. Manual operator dispatch is always available; pool/n87 also wires this CLI into `canaries.yml` for the nightly cron and the pre-release main-PR sweep (see the canary CI wiring section below).

The same no-implicit-default refusal posture as `test-off-grid-e2e` applies: token and account are NEVER implicit, both must be passed explicitly even though the token would otherwise identify the actor. `--dry-run` prints every planned API call and shell command across both scenarios without executing any of them. `--positive-only` and `--negative-only` scope a re-run to a single scenario after diagnosing one. The shared throwaway plumbing (token resolution, seed, clone retry, delete) lives in `scripts/_throwaway_lib.sh` and is reused by the off-grid e2e canary and the verify-template canary so the three operator-run canaries stay behaviorally consistent.

## Canary CI wiring (operator-run plus automated sweeps)

The three operator-run throwaway canaries (`verify-template.sh`, `bin/test-off-grid-e2e`, `bin/test-parallel-pr-auto-heal-canary`) are wired into a single orchestrator workflow at `.github/workflows/canaries.yml`. The workflow keeps the historic operator-run posture (manual dispatch always works) and layers two scheduled fires on top.

| Trigger | Fires on | Cost per fire |
|---|---|---|
| `workflow_dispatch` | Manual dispatch from the GitHub UI or `gh workflow run canaries.yml`. The `canary` input selects one canary (or `all`). | Up to three real repo creations + three real repo deletions per `all` dispatch. |
| `schedule` | Nightly cron at 08:17 UTC. Off-the-hour to avoid org-level cron collisions. | Three real repo creations + three real repo deletions per night. |
| `pull_request` opened, synchronize, reopened against `main` | Every pre-release PR commit (the dev to main release ceremony). | Three real repo creations + three real repo deletions per PR commit. |

Push triggers on every dev advance are intentionally NOT wired. Each canary creates and deletes a real GitHub repo per invocation; wiring `push` against `dev` would burn three real repo creations every claim cycle.

Required configuration on the framework repo (or its owning org):

- **`secrets.CANARY_TOKEN`**. A GitHub PAT or App-installation token with `repo + delete_repo` scope on the destination account. The canaries refuse to fall back to `GITHUB_TOKEN` because `GITHUB_TOKEN` cannot create or delete repos in another owner and the canaries are designed to NEVER touch the framework's own repos.
- **`vars.CANARY_ACCOUNT`**. Owner under which throwaways are created. The canaries refuse to guess this even when the token implicitly identifies an actor; this is the belt-and-suspenders guard against cross-account PAT mistakes deleting the wrong repo.
- **`vars.CANARY_VISIBILITY`** (optional). `public` passes `--public` to every canary, which a free plan needs for the connected canary; anything else keeps the throwaways private.

When either is missing the job posts a `SKIPPED` summary on the run and exits 0; the canary stays advisory until the operator wires both. Missing credentials never red the workflow per the "CI never crashes - completes or skips" discipline.

The orchestrator's resolve step filters the matrix by bin-on-disk presence so adding a fourth canary script in a follow-on PR lands without a flaky window.

## Apply branch protection rules to a new repo (one-time)

```bash
# Canonical one-shot CI setup; idempotent; safe to re-run.
.io.v4rian.how-git/bin/bootstrap-ci
.io.v4rian.how-git/bin/bootstrap-ci --check     # read-only audit
.io.v4rian.how-git/bin/bootstrap-ci --dry-run   # print every API call
```

`bootstrap-ci` runs every repo-level setup that the `Use this template` button does NOT copy. It is also the **canonical path that primes `dev` on a freshly templated consumer** (Step 2 below): GitHub does not emit a `create` event for refs that exist at the moment of repo birth, so the `seed-dev-on-main-create` workflow never actually fires on the template-generate path. `bootstrap-ci` is what makes `dev` appear on origin.

1. Verifies Actions is enabled.
2. Verifies dev exists on origin; seeds at main's SHA if missing. (Canonical dev-seeding path on a freshly templated consumer.)
3. Applies branch protection on main + dev via `apply-repo-rules.sh`.
4. Applies Repository Rules (`pool-creations`, `safety-lockdown`, `vault-readonly`) via the same script.
5. Binds required status checks: `offline test suites` on PRs to dev and main, plus `compile`, `coverage`, `runtime`, and `opened-via-correct-flow` on PRs to dev.
6. Sets merge-commit defaults so the merge subject inherits the PR title (carries the `vYYYY.X.Y` stamp) and the merge body inherits the PR body (the macro-tone TLDR).
7. Locks merge mode to `--no-ff` merge commits only (disables squash + rebase).
8. Disables "auto-delete merged branches" so the claim flow can archive every merged pool branch to its paired `vault/` ref.
9. Sets repo topics `v4rian` and `how-git` for discoverability.
9b. Consumer cleanup: on a consumer repo, prunes framework-internal artifacts that arrived via `Use this template`. Framework-source detection combines two signals: the `.io.v4rian.how-git/FRAMEWORK_REPO` marker file AND the GitHub API `is_template` flag on the repo. Cleanup is skipped only when BOTH are true. Marker-present-without-`is_template`-true falls through to consumer cleanup, so a consumer that inherited the marker through a seed-from-dev throwaway path still gets cleaned. `.io.v4rian.how-git/framework-tests/` STAYS on the consumer because `bin/doctor --deep` uses it as an on-demand diagnostic (pool/n47); `.github/workflows/framework-self-tests.yml` (the auto-run dispatcher) IS removed because consumer CI should not fire framework-internal tests on every push; the consumer gets a starter project-stub `README.md` when the repo root has no `README.md` (the framework ships no root README; the canonical framework README lives at `.io.v4rian.how-git/README.md`, so a freshly generated consumer arrives without one). If the consumer already has a root README it is left untouched.

**Chicken-and-egg note for the framework's own first release.** Until the framework lands its first `dev` to `main` release, the framework files live on `dev` and the default `main` branch carries only the intro commit (`.gitignore` and `README.md` per the v4rian intro-commit shape). Consumers who click `Use this template` before that first release receive a near-empty repo because GitHub's template-generate API seeds from the source's default branch only. Until then, exercise the deliverable from `dev` via `bash .io.v4rian.how-git/scripts/verify-template.sh --from-branch dev`. Once the first `dev` to `main` release lands, the chicken-and-egg resolves and `Use this template` becomes the canonical adoption path.

Each step probes current state via GET and only mutates when drift is detected, so the whole run is safe to re-invoke. `apply-repo-rules.sh` auto-installs missing CLI deps (`gh`, `python3`) on macOS via Homebrew, surfaces install hints to the operator on Linux, and routes every precondition failure through a visible STDOUT banner. Reconcile candidate publication already runs with the plain workflow token: the auto-rebase rolls the canonical `pool/*.reconcile.*` name forward by force-pushing it in place (a non-fast-forward update is permitted for the plain token - pool-deletions only gates deletes, never updates, and the no-force rule binds only the developer's branch). The privileged transitions that still need a bypass are vault renames and pool deletions at archive; they automate fully once the CI bot App is enrolled: create the App once on the org and run `bin/bootstrap-ci --ci-app-pem <downloaded .pem>` - the enrollment writes the secret and App id variable from the operator shell, and the ruleset appliers inject the App's Integration bypass automatically. Until then the merge triggered claim amends the merge and places the tag, and the admin completes those protected transitions locally with `.io.v4rian.how-git/bin/post-merge-lifecycle` (admin verified, pushes under the operator's own gh session).

```bash
# Self-contained default: no env vars required when origin is configured
# and gh has admin scope.
.io.v4rian.how-git/bin/bootstrap-ci
```

To apply only the branch protection + ruleset half (legacy, the bootstrap-ci script delegates to this), `bash .io.v4rian.how-git/scripts/apply-repo-rules.sh` remains usable on its own. Repository Rules support is detected up-front by probing repo visibility plus the owning account's plan, so public repos on any plan and private repos on Teams / Business / Enterprise (orgs) or Pro / Business / Enterprise (users) all proceed; other tiers receive a clear banner naming the detected plan and the supported tiers.

## Branch shape cheat sheet

| Pattern | Created by | Touchable? |
|---|---|---|
| `main` | admin merges only | no direct commits; via PR from dev only (--no-ff) |
| `dev` | admin merges only | no direct commits; via PR from pool/* (--no-ff) |
| `pool/nN.kind.short-name` | allocator endpoint (or admin) | yes by dev who owns it; merge via PR into dev |
| `safety/nN.kind.short-name` (or prefixed `safety/vYYYY.MAIN/nN.kind.short-name`) | allocator (same SHA as pool at creation) | read-only; immutable for the life of the branch. Stays forever under the stay-forever rule, released or abandoned, so every working branch's allocation point is preserved as institutional record. Both flat and prefixed layouts are covered by the safety-lockdown ruleset. |
| `vault/vYYYY.MAIN/nN.kind.short-name` | archive flow (post-merge) | **read-only frozen**: repository rule blocks all writes. Major prefix groups every vault from the same release cycle so `refs/heads/vault/v2026.0/` reveals "what landed in cycle 0 of 2026" at a glance. Legacy flat `vault/nN.kind.short-name` from pre-pool/n44 repos still works; both layouts are matched by the vault-readonly ruleset. |

`kind` values: feature, fix, r&d, refactor, reconcile, doc. The one regex for these shapes is `HG_BRANCH_RE` in `scripts/_lib.sh`, sourced by every hook and script.

Short-name rule: `[a-z0-9][a-z0-9-]*` (hyphens only, no underscores).

## When things go wrong

- **Rebase conflicts on auto-rebase pass:** the reconcile flow cuts `pool/nN.reconcile.<short>` off the new dev tip + claude attempts L1-L5 strategies on each conflicting cherry-pick. On any outcome it **comments on the existing PR** with the recap and leaves both the original pool branch and the original PR untouched. Admin reviews and decides: merge the reconcile candidate locally (`git checkout dev && git merge --no-ff pool/nN.reconcile.<short> -m "[MERGE] ... into dev: <version>"` then push), tag the developer for changes, or close the PR to reject. If conflicts remained unresolved after L5, the partial reconcile branch is pushed for review and the comment lists every attempted strategy. Dev may also push their own resolution to the pool branch at any time before admin review. The cherry-pick range covers the FULL pool delta since the pool diverged from dev (the merge-base of pool tip and dev tip), so multi-commit pool branches reach the reconcile candidate intact instead of dropping every commit except the top. If every commit aborts under L5 surface so the reconcile branch would carry zero new content past dev tip, the script refuses the push entirely and the PR comment names the empty-reconcile state explicitly so the admin reads "no candidate to merge, hand-rebase required" rather than mistaking an absent branch for a missed run.
- **Pool ids jumped out of sequence (neo-git, 2026-10-29):** after n166 the allocator handed out n1001-n1007, because the v2026.120.0 tag, a live-proof fixture inherited from how-git, carries the landing subject `[MERGE] pool/v2026.0/n1000.fix.vault-proof-a into dev: v2026.120.0`, and the counter read every tag's subjects. The spec wants contiguous ids within the active claim series, so the counter now ignores subjects sealed in another series and the `preflight-bak*` backup branches. The seven landed pools were renumbered n167-n173 under the owner's explicit grant: a preflight ref and bak zip first, then the dev merges and their pool commits were replayed with identical trees and author data (committer date = replay time), tags v2026.0.138-.144 re-pointed with their messages and tagger dates, dev force-pushed with a lease on the old tip, and the safety and vault refs pushed under the new names before the old names were deleted. If a jump recurs, find the subject with `git log --all --format='%h %D %s' | grep '/n<N>\.'` before allocating again.
- **Off-grid allocation refused a shallow or single-branch clone:** run the command the refusal prints (`git fetch --unshallow origin`, or `git remote set-branches origin '*' && git fetch origin`) and allocate again; the counter cannot be trusted from a clone that hides refs or history.
- **Stray VERSION file at repo root** (from a pre-redesign checkout): heal warns, you delete (`rm VERSION`). Tags are the seal now.
- **Tag conflict** (claim-dev-merge says "tag exists"): a previous claim partial-failed. Drop the local tag (`git tag -d vYEAR.SERIES.DEV`) and re-run.
- **Dev rewritten under you:** auto-rebase detects orphan base via `git merge-base --is-ancestor` and switches to `git rebase --onto origin/dev <old-base> <pool>` automatically.
- **Push-triggered claim run never completed:** connected, the claim runs in `ci-dispatch.yml` on the push to dev or main. If that run fails, an admin re-fires the same claim with `gh workflow run dev-merge.yml` (or `main-merge.yml`); both thin entries refuse a non-admin actor, and off-grid `bin/ci-local --workflow dev-merge --allow-claim` (or `main-merge`) runs the same steps locally. The claim scripts are idempotent (tag-exists check on dev, no new tag on main), so re-runs never double-tag.

## File map

```
.io.v4rian.how-git/
├── MODE                  current mode (`connected` or `off-grid`); committed to the repo
├── MERGE_POLICY          pool to dev merge policy (who, PR, approval, gates, commit cap); committed
├── WARP                  warp flag (`on`/`off`, absent = off); committed
├── bin/
│   ├── version           canonical version utility (3-segment, merge-count math)
│   ├── status            current-state snapshot (includes mode)
│   ├── doctor            template health verification (includes MODE value sanity)
│   ├── set-mode          flip between connected and off-grid (to connected is admin-gated)
│   ├── set-merge-policy  read or change the pool to dev MERGE_POLICY (admin-gated)
│   ├── warp              warp on|off|status: pool to dev without PRs while prototyping (admin-gated)
│   ├── ship              off-grid dev to main release (refuses in connected mode)
│   ├── finalize-pool-merge  off-grid pool to dev close-up (refuses in connected mode)
│   ├── push-pool         push a pool and its safety anchor atomically with an explicit lease (works through token URLs)
│   ├── bootstrap-offgrid seed a new repo's empty origin with main and dev, off-grid, in one atomic push
│   ├── release-of        commit to release-tag lookup
│   ├── bootstrap-ci      connected-mode repo-level CI setup; idempotent; --check / --dry-run modes
│   ├── create-pool-branch  local CLI wrapper: dispatches the allocator workflow (connected) or runs the allocator locally (off-grid)
│   ├── init-pool-merge   connected-mode CLI for opening a pool/* to dev PR
│   ├── init-release      connected-mode CLI for opening a dev to main release PR (body from CHANGELOG)
│   ├── test-off-grid-e2e operator-run e2e: real throwaway repo + full off-grid lifecycle (also wired into canaries.yml)
│   ├── test-parallel-pr-auto-heal-canary operator-run e2e: real throwaway repo + parallel-PR auto-heal scenarios (also wired into canaries.yml)
│   └── reconstruct       git-reconstruct mechanics (multi-source consolidation); preflight, relocate and fast-forward guard every destructive step; --help is the reference
├── scripts/
│   ├── claim-dev-merge.sh           post-merge dev claim (tag + archive + auto-rebase)
│   ├── claim-main-release.sh        post-merge main release (Release object; safety anchors are left untouched)
│   ├── archive-pool-branch.sh       rename pool/X to vault/X on origin
│   ├── auto-rebase-pools-after-dev-merge.sh   produce pool/nN.reconcile.<short> candidate + comment on existing PR (never force-pushes, never closes/opens PRs)
│   ├── build.sh                     canonical project-type-dispatching build script (Node / Qt-CMake / template-self); consumers override with real recipes
│   ├── distribute-internal.sh       PLACEHOLDER, project fills in
│   ├── distribute-public.sh         default = gh release upload; extras placeholder
│   ├── open-pr.sh                   opens/updates PR with auto-derived title + body
│   ├── validate-pr-open.sh          canonical PR-open validator (called by validate-pr-open.yml)
│   ├── apply-repo-rules.sh          one-time branch protection setup
│   ├── verify-template.sh           invariant checks (also wired into canaries.yml)
│   ├── test-off-grid-e2e.sh         operator-run off-grid lifecycle e2e against a real throwaway repo
│   ├── test-parallel-pr-auto-heal-canary.sh  operator-run parallel-PR auto-heal scenario canary against a real throwaway repo
│   ├── _throwaway_lib.sh            shared helpers for the throwaway-creation canaries (sourced; never executed)
│   ├── heal.sh                      drift repair
│   └── reconstruct.sh               library behind bin/reconstruct (sourced, never executed)
├── githooks/                         active hooks (core.hooksPath)
│   ├── pre-commit                   scrubs em/en-dashes from staged files
│   ├── prepare-commit-msg           smart auto-fix layer (dash scrub + tag derivation + bullet rewrite)
│   ├── commit-msg                   subject length guardrail (8-100 chars; [MERGE]+[REQ] exempted to 140) + mapped identity + merge message shape gate
│   ├── pre-push                     mapped identity + rewrite-author gate, merge message shape gate on pushed merges, then branch-name regex guardrail
│   ├── post-checkout                branch-name warning + snapshot-preflight audit
│   └── post-merge                   auto-claim on dev/main
└── .github/workflows/                CI (consumer can add their own)
    ├── allocate-pool-branch.yml     admin-only allocator that atomically creates pool/X + safety/X
    ├── ci-dispatch.yml              layered CI dispatcher; fans out one check per script under ci/{tests,audits}/<trigger>/ (push, dev/main claims, v* tag build); callable via workflow_call
    ├── audit-pushed-branch.yml      admin on-demand push-tree audit of a branch or tag of this repo; thin caller of ci-dispatch; for reading only, never satisfies a PR required check (off grid: bin/ci-local --workflow audit-pushed-branch)
    ├── dev-merge.yml                admin re-run of the dev claim; thin caller of ci-dispatch (off grid: bin/ci-local --workflow dev-merge --allow-claim)
    ├── main-merge.yml               admin re-run of the main release claim; thin caller of ci-dispatch (off grid: bin/ci-local --workflow main-merge --allow-claim)
    ├── validate-pr-open.yml         on pull_request to dev/main: shield, amend, post opened-via-correct-flow check
    ├── seed-dev-on-main-create.yml  seed dev branch at repo birth from template
    ├── canaries.yml                 orchestrates the three throwaway canaries on workflow_dispatch, nightly cron, and PRs against main; skips cleanly without CANARY_TOKEN + CANARY_ACCOUNT
    └── build-on-tag.yml             admin rebuild of one v* tag; thin caller of ci-dispatch's tag check (every tag push builds through ci-dispatch itself); off grid: bin/ci-local --workflow build-on-tag
```

## Em-dash policy: local scrub plus push gate

The framework bans em-dash (U+2014) and en-dash (U+2013) bytes in repo content because they confuse code review tooling and the auto-fix pipeline already rewrites prose around them. Enforcement is two-layered:

- **The rule is for prose.** `hg_dash_rule_applies` in `scripts/_lib.sh` decides by file type, and both layers below use it: markdown, text, reStructuredText, AsciiDoc, Org, and extensionless README-style docs are in scope; code and data are not, because a dash inside a string literal, a regex, or quoted requirement text is semantics. Markup that embeds code (`.html`, `.tex`) is out of scope, and so are fenced code blocks inside markdown (CommonMark fences: the same character, at least as long, closes them) (the CI gate maps added lines through `-U0` hunks and skips fenced ones). In a consumer repo (no `FRAMEWORK_REPO` marker) the vendored `.io.v4rian.how-git/` is out of scope too, so it stays byte-identical to the framework source.
- **Local auto-scrub** runs in `pre-commit`. For each staged prose file (binary detection via `file -b --mime-encoding`; extensions matched in any case, LICENSE included), the hook replaces U+2014 and U+2013 with ascii hyphens outside markdown fenced code blocks, re-stages the file, and prints a one-line note per rewrite; a code file that carries a dash gets a note and keeps its bytes. The hook never blocks the commit; the author can `git reset HEAD` if they want the original. Files that legitimately carry em-dash bytes as data (the `auto-fix-commit-message.sh` library, the pre-commit hook itself, the `framework-tests/test-{hooks,lifecycle}.sh` fixtures, and the `scripts/audits/commit-audit.sh` worker) sit on the `_skip_path` allowlist so the scrub leaves them alone.
- **Push gate** runs in `required.commit-audit`. The worker at `scripts/audits/commit-audit.sh` walks every commit in the resolved push range (`GITHUB_EVENT_BEFORE..GITHUB_EVENT_AFTER` under the workflow, or the closest sensible fallback in `origin/dev > dev > origin/main > main`), parses each `git show` for `+++ b/<path>` markers, and inspects every added line for U+2014 or U+2013 bytes. Hits surface the SHA, the file path, and the offending line, and the gate exits non-zero. The opt-out allowlist mirrors the pre-commit `_skip_path` set and the file-type rule is shared, so both layers agree on which paths are in scope. The gate runs regardless of `LIFECYCLE_TEST_MODE` because the byte check costs nothing and is the only defence against a missed local scrub (broken hook, `--no-verify`, web-UI commit).

In short: the hook keeps em-dashes out of normal local workflow, the gate catches the ones that slip past the hook, and the bootstrap state (no `dev`, no `main`) resolves to an empty range so a fresh template clone never trips the gate on its own template content.

Residual risk, accepted: on a first push to a destination that advertises nothing this repo has, pre-push bounds the message re-check by the lane's local safety anchor and newest claim tag, both local refs a pusher could forge, so the server-side rulesets (which pin safety/* and tags to the allocator and claim identities) and the CI commit-audit over the push range remain the final authority.

## Layered CI hooks (consumer-extendable)

Two directories feed the `ci-dispatch.yml` workflow:

- **usr layer**, `ci/` at the repo root, is consumer-owned. Drop any `.sh` under `ci/tests/<trigger>/` or `ci/audits/<trigger>/` and it runs as a separate status check on the named trigger.
- **sys layer**, `.io.v4rian.how-git/ci/`, ships with the framework and runs ONLY when the FRAMEWORK_REPO marker is present.

| Trigger dir | Fires on |
|---|---|
| `push` | every push to any branch |
| `pr-open` | `pull_request` opened, synchronize, or reopened, targeting dev or main |
| `pr-merge-dev` | `pull_request` closed-merged into dev |
| `pr-merge-main` | `pull_request` closed-merged into main |
| `tag` | tag push matching `v*` |

The script's basename minus the `.sh` extension is the GitHub check context name. Any file named `required.*` is bound as a required status check on PRs to dev by `bin/bootstrap-ci` (added to branch protection automatically). Anything else is advisory.

The framework's own audit + test gates live under `.io.v4rian.how-git/ci/` as `required.commit-audit.sh`, `required.compile.sh`, `required.coverage.sh`, `required.runtime.sh`, and `required.offline-test-suites.sh` so the dispatcher posts them under the names `required.commit-audit`, `required.compile`, `required.coverage`, `required.runtime`, and `required.offline-test-suites`. Branch protection on dev binds these five names plus `opened-via-correct-flow` (posted by `validate-pr-open.yml`). The `required.commit-audit` gate applies the `git-commit-audit` lens (atomicity, title format, body shape, bullet style, fabrication detection, file hygiene, branching, merge format) to every commit in the push range.

### Claude judgment layer on commit-audit

The structural surface of the lens (title regex, body shape, bullet hygiene, file blacklist) runs as deterministic shell checks in the local hooks and in the offline audit suites. The push-trigger `required.commit-audit` gate adds a per-commit semantic judgment layer on top by delegating to the shared `claude_judge_commit` helper at `scripts/_lib.sh`. The helper invokes `claude -p` with the `git-commit-audit/SKILL.md` body as the system context and the commit's subject, full message, and diff as the audit subject, then parses `AUDIT_PASS` or `AUDIT_FAIL` from the reply. This is the axis the structural shell checks cannot cover: tag fit (e.g. an `[NEW]` title on a commit that only adds a helper method inside an existing class is an `[NEW]` vs `[REFACTOR]` boundary violation per `feedback_tag_new_for_genuine_new_features`), fabrication of method or symbol names that do not exist in the committed tree, non atomic mixing of ≥2 unrelated concepts in one commit, and body-versus-diff contradiction where the description or bullets claim behavior the diff does not implement.

Credential resolution: the helper accepts two credential paths, with `CLAUDE_CODE_OAUTH_TOKEN` preferred (the Max-plan OAuth token from `claude setup-token` - usage draws from the operator's subscription quota rather than billed API spend) and `ANTHROPIC_API_KEY` as the fallback (direct API key). When both are bound on the runner, the helper invokes `claude` with `ANTHROPIC_API_KEY` unset in a subshell so the OAuth path wins deterministically. Wire either or both as repository secrets named `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY`; the `ci-dispatch` and `allocate-pool-branch` workflows pass them through to the audit jobs.

Credential fallback: the helper returns `0` with a visible `WARN` banner on stderr when the `claude` CLI is unavailable on PATH, when neither `CLAUDE_CODE_OAUTH_TOKEN` nor `ANTHROPIC_API_KEY` is set, or when the SKILL.md file is missing. A credential gap therefore never red-checks a push; the deterministic structural lens that runs alongside this gate stays the hard gate, and the `WARN` banner surfaces in the CI log so the operator can spot a missing secret without the push being blocked. Under `LIFECYCLE_TEST_MODE=1` the helper short-circuits to a canned outcome (PASS by default, FAIL when `CLAUDE_JUDGE_TEST_OUTCOME=FAIL` is set) so the offline lifecycle suite exercises the wiring without a network round-trip or API spend. Local previews can set `COMMIT_AUDIT_DRY_RUN=1` to print the planned invocation without spending API budget.

## abandoned-pool-branches

List pool branches that look abandoned without deleting any ref. Read-only enumeration only; safety and vault refs are excluded by design.

```bash
.io.v4rian.how-git/bin/abandoned-pool-branches             # human-readable
.io.v4rian.how-git/bin/abandoned-pool-branches --json      # machine-readable
.io.v4rian.how-git/bin/abandoned-pool-branches --days 60   # custom staleness threshold
```

### Renumber of n191 and n192 (2026-10-30 12:15)

The identity gate fix was allocated as n191 while the merge policy pair n190 sat unmerged, and the landing tool then allocated merge policy again as n192, leaving n190 spent but unmerged. Joel granted the rename: n191 became n190 and n192 became n191 with the preflight renumber procedure (same trees, authors and dates; tags v2026.0.161 and .162 re-pointed; pushed with lease), and the unmerged n190 pair was dropped.

### Renumber of n166 to n197 (2026-10-30)

The September allocator pool already held n165 when its content landed under a fresh allocation, so dev went n164 to n166. Pools n166 to n197 were renamed n165 to n196 with the preflight renumber procedure (same trees, authors and dates; tags v2026.0.137 to .168 re-pointed; pushed with lease). Requirement files and commit messages inside those pools still name the old numbers; the merge subjects, refs and tags carry the new ones. The push needed this pool's fix (several originals sharing one patch-id) and was made with the claim push mode for merges that predate the merge shape and pool size gates.

### CHANGELOG sections

Each pool writes the CHANGELOG section for the tag its merge title names (the claim stamps exactly that version), so the file never trails the tag chain.
