# how-git - Requirements

> Single-doc requirements register (project-reqs skill, 1-doc version).
> Lifecycle: intent → in-progress → done   (off-ramps: blocked, scrapped)
> Protection: every Hard Requirement is protected until explicitly scrapped.
> JIRA: a ticket is a Unit of Intent until its sprint is active, then it promotes.
> Storage: Markdown. (A GravityDB-backed register may supersede the storage layer without changing the model - tracked as HG-I09, not scheduled.)
>
> **Register basis** - `dev` @ `0b65c67` (`v2026.0.102`, PRs #129/#105/#130 merged), 2026-05-29.
> Sourced from a full inventory: 174 requirement statements extracted from the docs,
> 46 bin/script files, 7 workflows, 6 hooks, 4 rulesets, 14 skills, and the test surface
> (381 active automated tests - 321 lifecycle e2e + 60 hooks - all green, + 21 parked).
> `Source` is `internal` for every row: how-git carries no active JIRA sprint, so all
> requirements are **locked internal invariants**. Original capability-area IDs (e.g.
> `BOOTSTRAP-05`) are preserved in `Trace` for lineage.
>
> **Tests legend** - `✅ lifecycle`/`✅ hooks` = covered by an offline suite that runs in the
> push-trigger CI gate · `⚠️ needs units` = tracked test gap (not run by CI per-push) · the
> `⚠️` rows ARE the test backlog the "implement missing tests" + "100% CI coverage" phases close.

---

## Status at a glance

| Lens | Answer |
|---|---|
| **Status** | 239 Hard Requirements, **all done** (framework feature-complete on `dev`; +3 from merged PRs #129/#105/#130). Design ≈96% complete; testing-run-by-CI ≈82%. |
| **Protected (can't break)** | all 239 Hard Requirements; the P0 lifecycle invariants are the release-blockers. |
| **Needs test units** | After n125 all offline-feasible gaps are closed; only two genuinely live-only items remain - HG-R175 (server-side rule enforcement: a non-admin actually being rejected) and HG-R220 (the real `acli` submit) - both exercised by the canary workflow rather than the per-push offline suite. |
| **What to add next** | 2 pending sym9 requests (Phase 0, specs not yet published) + 6 deferred intents. |

---

## Hard Requirements
<!-- Committed + protected. Locked internal invariants. A regression against any row is a release-blocker. -->

### BOOTSTRAP

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R001 | Template works out of the box - no install step, no `make setup`, no CI required. | P0 | ✅ done | ✅ lifecycle | internal | `bin/bootstrap-ci` · BOOTSTRAP-01 |
| HG-R002 | Git hooks auto-activate the first time any in-repo script runs (`ensure_hooks_path` in `_lib.sh`). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/_lib.sh` · BOOTSTRAP-02 |
| HG-R003 | Version is lazily initialized from the current calendar the first time a claim script needs it. | P1 | ✅ done | ✅ lifecycle | internal | `bin/version` · BOOTSTRAP-03 |
| HG-R004 | Git preserves executable bits via its index so nothing needs `chmod`. | P1 | ✅ done | ✅ lifecycle | internal | `.gitattributes`/index · BOOTSTRAP-04 |
| HG-R005 | `bin/bootstrap-ci` is the canonical one-shot repo setup: idempotent, safe to re-run, `--check` read-only, `--dry-run` prints every API call. | P0 | ✅ done | ✅ lifecycle | internal | `bin/bootstrap-ci`, `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-05 |
| HG-R006 | bootstrap-ci verifies Actions is enabled. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-06 |
| HG-R007 | bootstrap-ci verifies dev exists on origin and seeds it at main's SHA if missing. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-07 |
| HG-R008 | bootstrap-ci is the canonical dev-seeding path (no `create` event fires for refs that exist at repo birth). | P1 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-08 |
| HG-R009 | bootstrap-ci applies branch protection on main + dev via `apply-repo-rules.sh`. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/apply-repo-rules.sh` · BOOTSTRAP-09 |
| HG-R010 | bootstrap-ci applies Repository Rules (`pool-creations`, `safety-lockdown`, `vault-readonly`). | P0 | ✅ done | ✅ lifecycle | internal | `rulesets/*.json` · BOOTSTRAP-10 |
| HG-R011 | bootstrap-ci binds required status checks: offline-test-suites on PRs to dev+main, plus commit-audit/compile/coverage/runtime/reconcile/opened-via-correct-flow on PRs to dev (seven dev contexts total). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-11 |
| HG-R012 | bootstrap-ci sets merge-commit defaults so merge subject inherits PR title and merge body inherits PR body. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-12 |
| HG-R013 | bootstrap-ci locks merge mode to `--no-ff` only (disables squash + rebase). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-13 |
| HG-R014 | bootstrap-ci disables auto-delete merged branches so the claim flow can vault each merged pool branch. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-14 |
| HG-R015 | bootstrap-ci sets repo topics `v4rian` and `how-git`. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-15 |
| HG-R016 | bootstrap-ci consumer-cleanup prunes framework-internal artifacts; skipped only when BOTH FRAMEWORK_REPO marker AND `is_template` are true. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-16 |
| HG-R017 | Consumer cleanup keeps `framework-tests/`, removes self-test workflow, replaces root README only when it still md5-matches the shipped template. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-17 |
| HG-R018 | Each bootstrap-ci step probes current state via GET and mutates only on detected drift (idempotent). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · BOOTSTRAP-18 |
| HG-R019 | Manual clone path: clone → `rm -rf .git` → `git init` → customize → commit → push to main; hooks activate on first script run. | P2 | ✅ done | ✅ lifecycle | internal | `README.md` · BOOTSTRAP-19 |
| HG-R020 | All framework content lives under hidden namespace `.io.v4rian.how-git/`; consumer root carries only `.gitignore` + generated version artifacts. | P0 | ✅ done | ✅ lifecycle | internal | `.io.v4rian.how-git/` · BOOTSTRAP-20 |
| HG-R021 | The only owner/repo binding is `remote.origin.url`; no hardcoded OWNER/REPO; suite fails if any file embeds a pinned literal. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/_lib.sh` · BOOTSTRAP-21 |

### BRANCHING

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R022 | Branch structure: `main` ← `dev` ← `pool/nN.{kind}.[sprintX-][JIRA-]short-name`. | P0 | ✅ done | ✅ lifecycle | internal | `docs/Git_Strategy.md` · BRANCHING-01 |
| HG-R023 | Allowed kinds: feature, fix, r&d, refactor, reconcile, doc. | P0 | ✅ done | ✅ hooks | internal | `githooks/pre-push` · BRANCHING-02 |
| HG-R024 | `nN` is a creation sequence number allocated atomically by the allocator; no collisions. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · BRANCHING-03 |
| HG-R025 | Short-name format `[a-z0-9][a-z0-9-]*` - hyphens only, lowercase, no underscores. | P0 | ✅ done | ✅ hooks | internal | `githooks/pre-push` · BRANCHING-04 |
| HG-R026 | Optional `sprintX-` prefix and optional `JIRA-` prefix in the branch name. | P1 | ✅ done | ✅ hooks | internal | `githooks/pre-push` · BRANCHING-05 |
| HG-R027 | Each pool branch has a paired safety branch created at the same moment, atomically, identical suffix. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · BRANCHING-06 |
| HG-R028 | Pool + safety both point at current dev HEAD at creation. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · BRANCHING-07 |
| HG-R029 | Developers never create remote pool/safety branches; only the allocator (server-trusted identity). | P0 | ✅ done | ✅ lifecycle | internal | `rulesets/pool-creations.json` · BRANCHING-08 |
| HG-R030 | Pre-push hook + server rules reject pushing new remote pool/safety branches from a dev identity (local spikes allowed). | P0 | ✅ done | ✅ hooks | internal | `githooks/pre-push` · BRANCHING-09 |
| HG-R031 | Pushing commits to an existing remote pool branch is unrestricted (only creation is gated). | P1 | ✅ done | ✅ lifecycle | internal | `rulesets/pool-creations.json` · BRANCHING-10 |
| HG-R032 | pre-push rejects branch names not matching the canonical `^(pool\|safety)/n…` regex. | P0 | ✅ done | ✅ hooks | internal | `githooks/pre-push` · BRANCHING-11 |
| HG-R033 | post-checkout warns locally at branch creation when the name is non-conforming. | P1 | ✅ done | ✅ lifecycle | internal | `githooks/post-checkout` · BRANCHING-12 |
| HG-R034 | Protected branches main/dev push freely (always accepted by hooks). | P1 | ✅ done | ✅ hooks | internal | `githooks/pre-push` · BRANCHING-13 |
| HG-R035 | Pool branches merge back via PR into dev and are vaulted after merge. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/archive-pool-branch.sh` · BRANCHING-14 |
| HG-R036 | Both flat (`safety/nN…`) and major-prefixed (`safety/vYYYY.MAIN/nN…`) safety layouts are valid and lockdown-covered. | P1 | ✅ done | ✅ lifecycle | internal | `rulesets/safety-lockdown.json` · BRANCHING-15 |
| HG-R037 | `kind` may be auto-classified from the JIRA payload when `--kind` is omitted. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · BRANCHING-16 |

### ALLOCATOR

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R038 | Branch creation is a synchronous repo-owned operation; the only non-CI identity the creation restriction trusts. | P0 | ✅ done | ✅ lifecycle | internal | `.github/workflows/allocate-pool-branch.yml` · ALLOCATOR-01 |
| HG-R039 | Allocator accepts kind, optional sprint, optional JIRA ref, short slug. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-02 |
| HG-R040 | Allocator atomically allocates next `nN` (1 + max over pool, safety, vault refs, landing subjects and off-grid reservations). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-03 |
| HG-R041 | Allocator atomically creates both pool + safety from current dev HEAD. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-04 |
| HG-R042 | Allocator returns synchronously with the new branch name, or a structured error (no fire-and-forget). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-05 |
| HG-R043 | On partial pair-creation failure the allocator rolls back the partial state (all-or-nothing, Invariant I7). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-06 |
| HG-R044 | Caller receives a structured error (not a hang/timeout) within 10s on failure. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-07 |
| HG-R045 | Two concurrent requests produce two distinct nN values, never the same nN twice (off-grid: reservation ref in the pair's transaction). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-08 |
| HG-R046 | Allocator validates input against the same regex pieces as the pre-push hook. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-09 |
| HG-R047 | Callers include JIRA, the `create-pool-branch` CLI, and other automations; the repo owns naming/allocation regardless of caller. | P1 | ✅ done | ✅ lifecycle | internal | `bin/create-pool-branch` · ALLOCATOR-10 |
| HG-R048 | Allocator runs as a GitHub-Actions identity with contents:write, restricted by Repository Rules to be the only path to a remote pool/safety branch. | P0 | ✅ done | ✅ lifecycle | internal | `.github/workflows/allocate-pool-branch.yml` · ALLOCATOR-11 |
| HG-R049 | `bin/create-pool-branch` is the local CLI wrapper that dispatches the in-repo allocator workflow via `gh workflow run` (no standalone service). | P0 | ✅ done | ✅ lifecycle | internal | `bin/create-pool-branch` · ALLOCATOR-12 |
| HG-R050 | CLI is synchronous, reads token from `gh auth token`/env, prints branch name + checkout one-liner on success, structured error + non-zero on failure. | P1 | ✅ done | ✅ lifecycle | internal | `bin/create-pool-branch` · ALLOCATOR-13 |
| HG-R051 | CLI `--dry-run` validates input and shows what would be created without calling the endpoint. | P1 | ✅ done | ✅ lifecycle | internal | `bin/create-pool-branch` · ALLOCATOR-14 |
| HG-R052 | `--requirement` text becomes the body of the initial `[REQ]` commit (rule-scrubbed) AND is written verbatim to the lane's own `requirements/<pool ref with / as __>` (legacy lanes: the shared `active-requirement`). | P1 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-15 |
| HG-R053 | `--requirement-file` reads requirement from a file; JIRA Automation passes it via `client_payload.requirement`. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-16 |
| HG-R054 | Allocator workflow handles idempotent JIRA-key reuse detection + optional Claude kind classification with retry. | P1 | ✅ done | ✅ lifecycle | internal | `.github/workflows/allocate-pool-branch.yml` · ALLOCATOR-17 |
| HG-R055 | The pool+safety pair is built atomically in one allocator run (post-hoc pair-safety workflow retired). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-18 |
| HG-R056 | The paired safety anchor stays at the pristine dev tip (one commit behind the pool branch by construction). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · ALLOCATOR-19 |

### COMMIT-DISCIPLINE

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R057 | Every commit uses a canonical tag prefix (`[NEW]`/`[FIX]`/`[REFACTOR]`/`[DOCS]`/`[TEST]`/`[REVERT]`/`[HOTFIX]`/`[MERGE]`). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/lib/auto-fix-commit-message.sh` · COMMIT-01 |
| HG-R058 | Title is sentence-case, under 72 characters. | P1 | ✅ done | ✅ hooks | internal | `githooks/commit-msg` · COMMIT-02 |
| HG-R059 | Body is a 1-3 sentence description paragraph followed by bullets naming the actual symbols changed. | P1 | ✅ done | ✅ lifecycle | internal | `skills/git-commit-audit` · COMMIT-03 |
| HG-R060 | No placeholder or speculative content; only the diff is the diff. | P1 | ✅ done | ✅ lifecycle | internal | `skills/git-commit-audit` · COMMIT-04 |
| HG-R061 | commit-msg enforces 8-100 char subject; `[MERGE]`+`[REQ]` exempt to 140. | P0 | ✅ done | ✅ hooks | internal | `githooks/commit-msg` · COMMIT-05 |
| HG-R062 | pre-commit scrubs em/en-dashes from staged text files; never blocks; re-stages and notes each rewrite. | P0 | ✅ done | ✅ hooks | internal | `githooks/pre-commit` · COMMIT-06 |
| HG-R063 | Em-dash allowlist exempts files that legitimately carry those bytes; hook + push gate share the allowlist. | P1 | ✅ done | ✅ lifecycle | internal | `githooks/pre-commit` · COMMIT-07 |
| HG-R064 | prepare-commit-msg runs deterministic auto-fix (dash scrub, banned-word, [TAG] derivation, sentence cap, third-person bullets). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/lib/auto-fix-commit-message.sh` · COMMIT-08 |
| HG-R065 | Push gate `required.commit-audit` inspects every added line for em/en-dash bytes; surfaces SHA+path+line + exits non-zero; runs regardless of test mode. | P0 | ✅ done | ✅ lifecycle | internal | `ci/audits/push/required.commit-audit.sh` · COMMIT-09 |
| HG-R066 | `required.commit-audit` applies the full git-commit-audit lens per commit in the push range. | P0 | ✅ done | ✅ lifecycle | internal | `ci/audits/push/required.commit-audit.sh` · COMMIT-10 |
| HG-R067 | Per-commit semantic claude judgment covers tag fit, fabricated symbols, non-atomic mixing, body-vs-diff contradiction. | P0 | ✅ done | ✅ lifecycle (offline mock) | internal | `ci/audits/push/required.commit-audit.sh` · COMMIT-11 |
| HG-R068 | `bin/smart-commit` composes a message via a sub-claude loading in-repo audit skills; stages by name (never `git add -A`); `--dry-run`/`--message-only`/`--yes`. | P1 | ✅ done | ✅ lifecycle | internal | `bin/smart-commit` · COMMIT-12 |
| HG-R069 | No `claude` CLI required at commit or push time (deterministic structural lens is the hard gate). | P0 | ✅ done | ✅ lifecycle | internal | `githooks/prepare-commit-msg` · COMMIT-13 |
| HG-R070 | Local hooks are guardrails only, bypassable via `--no-verify`; CI is the source of truth. | P0 | ✅ done | ✅ lifecycle | internal | `githooks/*` · COMMIT-14 |

### MERGE-CLAIM-DEV

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R071 | Pool→dev merge is always `--no-ff` producing a merge commit on dev's first-parent line. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · DEV-01 |
| HG-R072 | post-merge fires `claim-dev-merge.sh` which calls `bin/version --seal` for `vYEAR.SERIES.DEV`. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · DEV-02 |
| HG-R073 | Annotated tag created on the merge commit and pushed; no chore-version commit on dev (tags are the seal). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · DEV-03 |
| HG-R074 | Claim amends merge subject to canonical `[MERGE] pool/X into dev: vYYYY.X.Y`. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · DEV-04 |
| HG-R075 | Claim force-pushes dev, tags, and vaults the pool branch. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · DEV-05 |
| HG-R076 | Connected mode: `claim-on-merge-dev` runs `claim-dev-merge.sh` remotely after the GitHub-UI merge. | P0 | ✅ done | ✅ lifecycle | internal | `ci/audits/pr-merge-dev/required.claim.sh` · DEV-06 |
| HG-R077 | Off-grid mode: admin runs `git merge --no-ff <pool>` then `bin/finalize-pool-merge` (refuses in connected). | P1 | ✅ done | ✅ lifecycle | internal | `bin/finalize-pool-merge` · DEV-07 |
| HG-R078 | Both claim scripts derive every dev version through `bin/version` (single authority); neither computes math itself. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · DEV-08 |
| HG-R079 | Both claim scripts refuse a dirty tree, refuse to re-claim an existing tag (idempotent), support `--dry-run`. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · DEV-09 |
| HG-R080 | Auto-rebase walks every open pool→dev PR after a dev merge: updates aspirational title, cuts a reconcile candidate off new dev tip, cherry-picks (L1-L5 claude ladder), comments on the PR. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/auto-rebase-pools-after-dev-merge.sh` · DEV-10 |
| HG-R081 | Auto-rebase never force-pushes the developer's pool branch and never opens/closes any PR - admin is sole merge decider. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/auto-rebase-pools-after-dev-merge.sh` · DEV-11 |
| HG-R082 | Cherry-pick range covers the full pool delta since merge-base of pool tip and dev tip. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/auto-rebase-pools-after-dev-merge.sh` · DEV-12 |
| HG-R083 | If every commit aborts under L5 (zero content past dev tip), the script refuses the push and the PR comment names the empty-reconcile state. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/auto-rebase-pools-after-dev-merge.sh` · DEV-13 |
| HG-R084 | Reconcile-merge dual-vault: close-up vaults BOTH the reconcile branch and the matching original pool branch in one pass. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · DEV-14 |
| HG-R085 | Dual-vault probe logs absence if original already vaulted; loud stderr + skip if >1 non-reconcile candidate matches same nN+short. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · DEV-15 |
| HG-R086 | `bin/init-pool-merge` opens the pool→dev PR via the template skeleton (connected only; refused off-grid). | P1 | ✅ done | ✅ lifecycle | internal | `bin/init-pool-merge` · DEV-16 |
| HG-R087 | Each dev merge produces a version tag; tags are internal, never promoted to public releases. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · DEV-17 |
| HG-R088 | Conflict handling: reconcile flow comments on the existing PR, leaves original pool branch + PR untouched; partial reconcile pushed for review if L5 exhausts. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/auto-rebase-pools-after-dev-merge.sh` · DEV-18 |
| HG-R089 | `claim-on-merge-dev` accepts a manual `workflow_dispatch` gated on admin role (emergency re-claim). | P2 | ✅ done | ✅ lifecycle | internal | `.github/workflows` claim dispatcher · DEV-19 |

### RELEASE-MAIN

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R090 | Dev→main merge is `--no-ff` (merge-commit countability depends on it). | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-01 |
| HG-R091 | Every dev→main merge produces a GitHub Release. | P0 | ✅ done | ✅ lifecycle (offline mock) | internal | `scripts/claim-main-release.sh` · MAIN-02 |
| HG-R092 | Release REUSES the existing dev tag (same code = same version); no new git tag. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-03 |
| HG-R093 | A GitHub Release object is attached to the existing dev tag via `gh release create`. | P0 | ✅ done | ✅ lifecycle (test_R093_claim_main_release_creates_release_object) | internal | `scripts/claim-main-release.sh` · MAIN-04 |
| HG-R094 | post-merge fires `claim-main-release.sh` which calls `bin/version --release-tag`. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-05 |
| HG-R095 | Claim amends merge subject to canonical `[MERGE] dev into main: vYYYY.X`. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-06 |
| HG-R096 | Connected mode: `claim-on-merge-main` runs `claim-main-release.sh` remotely after the GitHub-UI merge. | P0 | ✅ done | ✅ lifecycle | internal | `ci/audits/pr-merge-main/required.claim.sh` · MAIN-07 |
| HG-R097 | Off-grid mode: admin runs `bin/ship` (merges + claims locally; refuses connected); `--skip-push` for air-gap. | P1 | ✅ done | ✅ lifecycle | internal | `bin/ship` · MAIN-08 |
| HG-R098 | `bin/init-release` opens the release PR with body pre-filled from the CHANGELOG `## Unreleased` section. | P1 | ✅ done | ✅ lifecycle | internal | `bin/init-release` · MAIN-09 |
| HG-R099 | Every dev→main merge body closes on an `## Open work pool branches at release` section. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-10 |
| HG-R100 | Open-work rows: ref column-aligned, first→last commit dates ISO-8601 short, sorted ascending by first-commit-date. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-11 |
| HG-R101 | Open-work sourcing: connected reads `refs/remotes/origin/pool/*`, off-grid reads `refs/heads/pool/*`; reconcile sub-branches + main-reachable excluded. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-12 |
| HG-R102 | First-commit-date = first commit on pool not in the safety anchor, with documented fallbacks. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-13 |
| HG-R103 | Empty case renders the section followed by `(no open work pool branches at release)`. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-14 |
| HG-R104 | Release reuses the dev-tag's already-built artifact (no rebuild) on main promotion. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-15 |
| HG-R105 | claim-main-release prepends a `PR #N <url>` reference as the first body paragraph (falls back to bare `PR #N`). | P2 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-16 |
| HG-R106 | claim-main-release creates the GitHub Release via API only if a token is available; the git tag is canonical regardless. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/claim-main-release.sh` · MAIN-17 |
| HG-R107 | `claim-on-merge-main` accepts a manual `workflow_dispatch` gated on admin role. | P2 | ✅ done | ✅ lifecycle | internal | `.github/workflows` claim dispatcher · MAIN-18 |
| HG-R108 | `bin/release-of <sha>` returns the earliest release tag whose ancestor set includes the commit, or `unreleased`. | P2 | ✅ done | ✅ lifecycle | internal | `bin/release-of` · MAIN-19 |

### VERSIONING

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R109 | Version format `v{YYYY}.{SERIES}.{DEV}`, derived deterministically from git merge counts. | P0 | ✅ done | ✅ lifecycle | internal | `bin/version` · VER-01 |
| HG-R110 | `YYYY` = 4-digit year from `date -u +%Y` at compute time; never stored. | P0 | ✅ done | ✅ lifecycle | internal | `bin/version` · VER-02 |
| HG-R111 | `SERIES` = count of main first-parent merges this year; increments on each release; resets on year rollover; never manually bumped. | P0 | ✅ done | ✅ lifecycle | internal | `bin/version` · VER-03 |
| HG-R112 | `DEV` = count of dev first-parent merges in the current cycle (1-indexed cycle 0, 0-indexed cycle 1+). | P0 | ✅ done | ✅ lifecycle | internal | `bin/version` · VER-04 |
| HG-R113 | Same code = same version; release reuses the dev tag; binary-identical builds never carry different versions. | P0 | ✅ done | ✅ lifecycle | internal | `bin/version` · VER-05 |
| HG-R114 | `bin/version` computes all three segments; every other tool calls it. | P0 | ✅ done | ✅ lifecycle | internal | `bin/version` · VER-06 |
| HG-R115 | `bin/version` default prints `vYEAR.SERIES.DEV-<sha7>.<build>`; `--seal`/`--next-dev`/`--build` modes. | P1 | ✅ done | ✅ hooks | internal | `bin/version` · VER-07 |
| HG-R116 | Build counter is per-clone (`version.build`, gitignored); reset with `--reset`. | P2 | ✅ done | ✅ hooks | internal | `bin/version` · VER-08 |
| HG-R117 | Year-rollover: first merge after Jan 1 UTC reads YYYY from clock, DEV resets to 1; lazy, no scheduled job. | P1 | ✅ done | ✅ lifecycle | internal | `bin/version` · VER-09 |
| HG-R118 | Version monotonicity (I6): tags sort chronologically under SemVer comparison. | P1 | ✅ done | ✅ lifecycle | internal | `bin/version` · VER-10 |
| HG-R119 | A stray root `VERSION` file triggers a heal warning and should be deleted; tags are the seal. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/heal.sh` · VER-11 |
| HG-R120 | Cycle counter starts at zero (SERIES=0) to match the existing tag chain from `v2026.0.1`. | P1 | ✅ done | ✅ lifecycle | internal | `bin/version` · VER-12 |

### CI-DISPATCH

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R121 | `ci-dispatch.yml` is the single layered dispatcher; one status check per `.sh` under `ci/{tests,audits}/<trigger>/`. | P0 | ✅ done | ✅ lifecycle | internal | `.github/workflows/ci-dispatch.yml` · CID-01 |
| HG-R122 | usr layer (`ci/` at root) is consumer-owned; any `.sh` there runs as a separate check on its trigger. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/ci-dispatch.sh` · CID-02 |
| HG-R123 | sys layer (`.io.v4rian.how-git/ci/`) runs ONLY when the FRAMEWORK_REPO marker is present. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/ci-dispatch.sh` · CID-03 |
| HG-R124 | Triggers: push, pr-open, pr-merge-dev, pr-merge-main, tag. | P0 | ✅ done | ✅ lifecycle | internal | `.github/workflows/ci-dispatch.yml` · CID-04 |
| HG-R125 | The script basename minus `.sh` is the GitHub check context name. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/ci-dispatch.sh` · CID-05 |
| HG-R126 | Any `required.*` file is bound as a required check on PRs to dev by bootstrap-ci; everything else is advisory. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/bootstrap-ci-steps.sh` · CID-06 |
| HG-R127 | Framework gates ship as sys-layer `required.{commit-audit,compile,coverage,runtime,offline-test-suites}.sh`. | P0 | ✅ done | ✅ lifecycle | internal | `ci/audits/push/`, `ci/tests/push/` · CID-07 |
| HG-R128 | the dev-required-checks ruleset binds those five context names plus `reconcile`; `opened-via-correct-flow` is bound separately by bootstrap-ci-steps branch protection and enforced by validate-pr-open closing mis-opened PRs. | P0 | ✅ done | ✅ lifecycle | internal | `rulesets/dev-required-checks.json` · CID-08 |
| HG-R129 | resolve maps push-to-dev→pr-merge-dev, push-to-main→pr-merge-main, v*-tag→tag, other→push, with chore(version) self-push guard. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/ci-dispatch.sh` · CID-09 |
| HG-R130 | Each script runs from repo root with clean checkout; exits 0/non-zero; must not write outside its work area. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/ci-dispatch.sh` · CID-10 |
| HG-R131 | Dispatcher sets `CI_TRIGGER`, `CI_LAYER`, `CI_CHECK_NAME` before each script. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/ci-dispatch.sh` · CID-11 |
| HG-R132 | Legacy claim/build workflows folded into the dispatcher as sys-layer entries; permissions bumped for claim scripts. | P1 | ✅ done | ✅ lifecycle | internal | `.github/workflows/ci-dispatch.yml` · CID-12 |
| HG-R133 | `validate-pr-open.yml` fires on every PR into dev/main: auto-amends title, body auto-fix, signature, posts `opened-via-correct-flow`. | P0 | ✅ done | ✅ lifecycle | internal | `.github/workflows/validate-pr-open.yml` · CID-13 |
| HG-R134 | claude-judgment credential resolution: `CLAUDE_CODE_OAUTH_TOKEN` preferred over `ANTHROPIC_API_KEY`; OAuth wins when both bound; both threaded by dispatch + allocator. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/` claude helper · CID-14 |
| HG-R135 | claude-judgment fallback returns 0 with WARN when claude unavailable / no creds / SKILL.md missing - never red-checks a push. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/` claude helper · CID-15 |
| HG-R136 | Under `LIFECYCLE_TEST_MODE=1` the claude helper short-circuits to a canned outcome; `COMMIT_AUDIT_DRY_RUN=1` previews invocation. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/` claude helper · CID-16 |
| HG-R137 | `seed-dev-on-main-create.yml` seeds dev at repo birth (doesn't fire on template-generate; bootstrap-ci is canonical). | P1 | ✅ done | ✅ lifecycle | internal | `.github/workflows/seed-dev-on-main-create.yml` · CID-17 |
| HG-R138 | doc-freshness gate fires on every dev→main PR: asserts CHANGELOG covers the release + docs mention new surface; bound required on main. | P1 | ✅ done | ✅ lifecycle | internal | `.github/workflows/doc-freshness.yml` · CID-18 |
| HG-R139 | Workflows are thin acceptance dispatchers invoking in-repo scripts under `scripts/workflows/`; logic stays testable/overridable. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/` · CID-20/21 |

### AUDITS

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R140 | Deterministic compile/coverage/runtime/offline-suite enforcement runs async in CI as required checks on PRs to dev. | P0 | ✅ done | ✅ lifecycle | internal | `ci/audits/push/` · AUDIT-01 |
| HG-R141 | `required.compile` verifies compile per repo type (consumer overrides the recipe). | P0 | ✅ done | ✅ lifecycle (wiring) | internal | `scripts/audits/compile.sh` · AUDIT-02 |
| HG-R142 | `required.coverage` verifies binary content coverage (framework fallback marker-gated). | P0 | ✅ done | ✅ lifecycle (wiring) | internal | `scripts/audits/coverage.sh` · AUDIT-03 |
| HG-R143 | `required.runtime` verifies boot/launch per repo. | P0 | ✅ done | ✅ lifecycle (wiring) | internal | `scripts/audits/runtime.sh` · AUDIT-04 |
| HG-R144 | `required.commit-audit` resolves the push range from event SHAs or origin fallbacks, iterates commits, applies the lens. | P0 | ✅ done | ✅ lifecycle | internal | `ci/audits/push/required.commit-audit.sh` · AUDIT-05 |
| HG-R145 | audit wrappers exec-delegate to `audit-retry.sh` exponential-backoff (8 attempts, 5-300s). | P1 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/audit-retry.sh` · AUDIT-06 |
| HG-R146 | Claude-driven judgment steps stay claude-driven; never replaced by a deterministic shortcut; AI touchpoint surfaced in PR body if refactored. | P0 | ✅ done | ✅ lifecycle | internal | `skills/git-commit-audit` · AUDIT-07 |
| HG-R147 | Legacy claude audit skills moved from sync pre-push to async CI (Step 2); skills kept as authoritative lens with a STATUS header. | P1 | ✅ done | ✅ lifecycle | internal | `skills/git-*` · AUDIT-08 |
| HG-R148 | post-checkout runs a snapshot-preflight audit in addition to the name warning. | P2 | ✅ done | ✅ lifecycle | internal | `githooks/post-checkout` · AUDIT-09 |

### TESTS (harness)

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R149 | Every test exercises behavior end-to-end (scratch repo, real script, assert post-conditions); structural greps are guards only, never substitutes. | P0 | ✅ done | ✅ lifecycle | internal | `framework-tests/test-lifecycle.sh` · TEST-01 |
| HG-R150 | `test-lifecycle.sh` covers regex, hooks, all ops bins, version math, claim scripts, archive, auto-rebase+reconcile, build shape, gh mock, rollover, scaffold, RC matrix. | P0 | ✅ done | ✅ lifecycle | internal | `framework-tests/test-lifecycle.sh` · TEST-02 |
| HG-R151 | `test-hooks.sh` runs regex + version-bin structural checks. | P0 | ✅ done | ✅ hooks | internal | `framework-tests/test-hooks.sh` · TEST-03 |
| HG-R152 | Scaffold mode: in-flight tasks ship SKIP'd assertions; once a pool lands, the post-merge claim re-runs under `LIFECYCLE_TEST_SCAFFOLD_MODE=1`. | P1 | ✅ done | ✅ lifecycle | internal | `framework-tests/test-lifecycle.sh` · TEST-04 |
| HG-R153 | Summary reports `<P> passed, <F> failed, <S> skipped` and prints the parked roster after the gate decision. | P2 | ✅ done | ✅ lifecycle | internal | `framework-tests/test-lifecycle.sh` · TEST-05 |
| HG-R154 | `--filter <name>` runs a single test/coverage block; `--verbose` for detail. | P2 | ✅ done | ✅ lifecycle | internal | `framework-tests/test-lifecycle.sh` · TEST-06 |
| HG-R155 | Before pushing, contributors run both suites with `LIFECYCLE_TEST_MODE=1`; CI reruns both on every PR via offline-test; red blocks merge. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/offline-test.sh` · TEST-07 |
| HG-R156 | Offline suite never reaches the real GitHub API; throwaway-canary tests stop before the real API call. | P0 | ✅ done | ✅ lifecycle | internal | `framework-tests/_gh_mock.py` · TEST-10 |

### HOOKS

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R157 | Hooks activate via `core.hooksPath .io.v4rian.how-git/githooks`, auto-applied by `ensure_hooks_path` on first script run. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/_lib.sh` · HOOK-01 |
| HG-R158 | `pre-commit` scrubs em/en-dashes from staged files (binary detection via mime-encoding). | P0 | ✅ done | ✅ hooks | internal | `githooks/pre-commit` · HOOK-02 |
| HG-R159 | `prepare-commit-msg` smart auto-fix layer. | P0 | ✅ done | ✅ lifecycle | internal | `githooks/prepare-commit-msg` · HOOK-03 |
| HG-R160 | `commit-msg` 8-100 char subject guardrail (`[MERGE]`/`[REQ]` to 140). | P0 | ✅ done | ✅ hooks | internal | `githooks/commit-msg` · HOOK-04 |
| HG-R161 | `pre-push` branch-name regex guardrail (regex-only since Step 2). | P0 | ✅ done | ✅ hooks | internal | `githooks/pre-push` · HOOK-05 |
| HG-R162 | `post-checkout` branch-name warning + snapshot-preflight audit. | P1 | ✅ done | ✅ lifecycle | internal | `githooks/post-checkout` · HOOK-06 |
| HG-R163 | `post-merge` auto-claims version on dev/main when `git pull` brings a new merge. | P0 | ✅ done | ✅ lifecycle | internal | `githooks/post-merge` · HOOK-07 |
| HG-R164 | Hooks are guardrails, bypassable with `--no-verify`; server-side Repository Rules are authoritative. | P0 | ✅ done | ✅ lifecycle | internal | `githooks/*` · HOOK-08 |
| HG-R165 | `heal.sh` re-sets hooks path, re-chmods exec bits, warns on stray VERSION; idempotent; `--dry-run`. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/heal.sh` · HOOK-09 |

### RULESETS-GOVERNANCE

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R166 | main protection: PR required, CI green, ≥1 review, no direct push, no force-push, no deletions, dismiss stale approvals. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/apply-repo-rules.sh` · GOV-01 |
| HG-R167 | dev protection: PR required, CI green, no direct push (bot bump only), no force-push, no deletions. | P0 | ✅ done | ✅ lifecycle | internal | `rulesets/dev-required-checks.json` · GOV-02 |
| HG-R168 | `pool/*` restrict creations to the branch-creator identity only. | P0 | ✅ done | ✅ lifecycle | internal | `rulesets/pool-creations.json` · GOV-03 |
| HG-R169 | `safety/*` restrict creations to branch-creator, updates to no one (read-only), deletions to the main-merge identity only. | P0 | ✅ done | ✅ lifecycle | internal | `rulesets/safety-lockdown.json` · GOV-04 |
| HG-R170 | `vault/*` is read-only frozen: a rule blocks all writes; both flat + major-prefixed layouts matched. | P0 | ✅ done | ✅ lifecycle | internal | `rulesets/vault-readonly.json` · GOV-05 |
| HG-R171 | Repository-Rules support is probed up-front by repo visibility + owning-account plan; unsupported tiers get a clear banner. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/apply-repo-rules.sh` · GOV-06 |
| HG-R172 | `apply-repo-rules.sh` self-derives ORG/REPO, auto-installs CLIs on macOS, routes precondition failures through a visible banner. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/apply-repo-rules.sh` · GOV-07 |
| HG-R173 | Two separate identities: `branch-creator` App (contents:write) and `ci-bot` (Actions token, contents+releases:write), kept separate for audit distinction. | P1 | ✅ done | ✅ lifecycle | internal | `docs/repo-config.md` · GOV-08 |
| HG-R174 | Repository-Rules bypass list seeds both the Actions bot and OrganizationAdmin (built-in emergency override). | P1 | ✅ done | ✅ lifecycle | internal | `scripts/apply-repo-rules.sh` · GOV-09 |
| HG-R175 | Non-admin verification: cannot create pool/safety, push/delete safety, force-push dev/main, or bypass review; App can create, ci-bot can delete safety + push bump. | P0 | ✅ done | ⚠️ live-only (ruleset content + RepositoryRole bypass covered offline in n107; server-side ENFORCEMENT - a non-admin actually being rejected - runs only via the canary workflow) | internal | `docs/repo-config.md` checklist · GOV-10 |
| HG-R176 | safety-lockdown carries a second include `refs/heads/safety/*/*` so prefixed anchors get the same protection. | P1 | ✅ done | ✅ lifecycle | internal | `rulesets/safety-lockdown.json` · GOV-11 |
| HG-R177 | vault-readonly carries a second include `refs/heads/vault/*/*`; `bin/lockdown` inline JSON mirrors it. | P1 | ✅ done | ✅ lifecycle | internal | `rulesets/vault-readonly.json`, `bin/lockdown` · GOV-12 |

### DISTRIBUTION

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R178 | `build-on-tag` (folded into ci-dispatch `tag` trigger) runs on every `v*` tag + admin `workflow_dispatch` and invokes `scripts/build.sh`. | P0 | ✅ done | ✅ lifecycle | internal | `ci/audits/tag/required.build.sh` · DIST-01 |
| HG-R179 | `build.sh` is the single build source of truth: Node / Qt-CMake / template-self dispatcher; consumers override the body. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/build.sh` · DIST-02 |
| HG-R180 | build.sh Node: `npm install` then `npm run build` if present, then tar dist into artifact dir. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/build.sh` · DIST-03 |
| HG-R181 | build.sh CMakeLists: prints consumer-must-override banner and exits non-zero. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/build.sh` · DIST-04 |
| HG-R182 | build.sh neither marker: emits a small text summary of the tag. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/build.sh` · DIST-05 |
| HG-R183 | Output contract: every artifact lands under `./build/artifacts/` with `$TAG` in the filename. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/build.sh` · DIST-06 |
| HG-R184 | build-on-tag wraps build.sh in exponential-backoff retry and skips when the idempotency probe says output is present. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/workflows/build-retry.sh` · DIST-07 |
| HG-R185 | Distribution is a separate bundle from build-on-tag; the same dev-tag artifact is reused unchanged on main promotion. | P1 | ✅ done | ✅ lifecycle (test_R185_distribute_public_uploads_asset_via_gh_release) | internal | `scripts/distribute-*.sh` · DIST-08 |
| HG-R186 | `distribute-internal.sh` is a consumer-fill placeholder that fails loudly until overridden. | P2 | ✅ done | ✅ lifecycle (test_R186_distribute_internal_is_placeholder) | internal | `scripts/distribute-internal.sh` · DIST-09 |
| HG-R187 | `distribute-public.sh` default = `gh release upload`; extras are a placeholder. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/distribute-public.sh` · DIST-10 |
| HG-R188 | Local build path: checkout the tag, `TAG=v… bash scripts/build.sh`, output at `build/artifacts/`; idempotency probe 0/1. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/build.sh` · DIST-11 |

### OFF-GRID

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R189 | Every repo runs in one of two modes in `.io.v4rian.how-git/MODE`: connected (default) or off-grid; committed. | P0 | ✅ done | ✅ lifecycle | internal | `.io.v4rian.how-git/MODE` · OFFGRID-01 |
| HG-R190 | `bin/set-mode --get\|off-grid\|connected` flips mode (admin-gated); flip lands as a `[MODE] switch to <new>` commit. | P1 | ✅ done | ✅ lifecycle | internal | `bin/set-mode` · OFFGRID-02 |
| HG-R191 | Connected gate runs against the GitHub permission API; off-grid gate is advisory (admins.txt allowlist). | P1 | ✅ done | ✅ lifecycle | internal | `scripts/_lib.sh` · OFFGRID-03 |
| HG-R192 | Each step refuses in the wrong mode with a message naming the correct mode + the `bin/set-mode` flip. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/_lib.sh` · OFFGRID-04 |
| HG-R193 | Off-grid pool→dev: `git merge --no-ff` then `bin/finalize-pool-merge` (runs claim-dev-merge locally). | P1 | ✅ done | ✅ lifecycle | internal | `bin/finalize-pool-merge` · OFFGRID-05 |
| HG-R194 | Off-grid dev→main: `bin/ship` (merges + runs claim-main-release locally); `--skip-push` for air-gap. | P1 | ✅ done | ✅ lifecycle | internal | `bin/ship` · OFFGRID-06 |
| HG-R195 | Connected entry points refuse off-grid; off-grid bins refuse connected. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/_lib.sh` · OFFGRID-07 |
| HG-R196 | Off-grid mutates refs locally via `update-ref`/`commit-tree` + post-merge; always-present workflows no-op so a wired remote does not race local close-ups. | P1 | ✅ done | ✅ lifecycle | internal | `bin/finalize-pool-merge`, `bin/ship` · OFFGRID-08 |
| HG-R197 | `bin/test-off-grid-e2e` exercises the off-grid lifecycle against a real throwaway repo; verifies subject form, tag, vault, and that NO workflow fired. | P1 | ✅ done | ✅ lifecycle (test_n62_off_grid_e2e_full_lifecycle_in_scratch_repo) | internal | `scripts/test-off-grid-e2e.sh` · OFFGRID-10 |
| HG-R198 | test-off-grid-e2e token + account are NEVER implicit (cross-account PAT guard); `--dry-run` prints planned calls; throwaway deleted on success unless `--keep`. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/test-off-grid-e2e.sh` · OFFGRID-11 |
| HG-R199 | Off-grid JIRA is unreachable by design; jira-ingress renders a draft to `.local/jira-drafts/<UTC>.md` and suggests a `--no-jira` recipe. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/jira-ingress.sh` · OFFGRID-12 |

### DOCTOR-HEAL

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R200 | `bin/doctor` default = fast structural file-presence + exec-bit checks + MODE sanity. | P1 | ✅ done | ✅ lifecycle | internal | `bin/doctor` · DOC-01 |
| HG-R201 | `bin/doctor --deep` runs both framework suites against the consumer's actual install. | P1 | ✅ done | ✅ lifecycle | internal | `bin/doctor` · DOC-02 |
| HG-R202 | `bin/status` reports branch+sha, version seal, latest tag, ahead/behind, open-PR count, dev claims, mode; `--json`. | P1 | ✅ done | ✅ lifecycle | internal | `bin/status` · DOC-03 |
| HG-R203 | `bin/queue` = open-PR overview with conflict prediction. | P2 | ✅ done | ✅ lifecycle | internal | `bin/queue` · DOC-04 |
| HG-R204 | `bin/preview-merge` = safe dry-run of a pending PR merge. | P2 | ✅ done | ✅ lifecycle | internal | `bin/preview-merge` · DOC-05 |
| HG-R205 | `bin/changelog` = markdown release notes from tag history. | P2 | ✅ done | ✅ lifecycle | internal | `bin/changelog` · DOC-06 |
| HG-R206 | `scripts/verify-template.sh` exercises the template end-to-end on a separate throwaway repo (never the template itself); `--from-branch` variant. | P1 | ✅ done | ✅ lifecycle (test_R206_R208_verify_template_documents_bump_cycle_and_invariants); execution = canary | internal | `scripts/verify-template.sh` · DOC-07 |
| HG-R207 | verify-template static invariants always run (root layout, exec bits, hooksPath, heal-after-drift, test-hooks green, claim scripts present). | P1 | ✅ done | ✅ lifecycle | internal | `scripts/verify-template.sh` · DOC-08 |
| HG-R208 | verify-template `--with-bump-cycle` adds five claim-script invariants on the throwaway (tags+Release+bumps); deletes throwaway unless `--keep`. | P1 | ✅ done | ✅ lifecycle (test_R206_R208_verify_template_documents_bump_cycle_and_invariants); execution = canary | internal | `scripts/verify-template.sh` · DOC-09 |
| HG-R209 | Silence-is-success: exit-0 prints nothing; non-zero always prints (announce echo, EXIT trap with name+status, heartbeat before long steps). | P1 | ✅ done | ✅ lifecycle | internal | `scripts/_lib.sh` · DOC-10 |
| HG-R210 | `bin/test-parallel-pr-auto-heal-canary` exercises parallel-PR auto-heal on a real throwaway; positive + negative L5; flag set. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/test-parallel-pr-auto-heal-canary.sh` · DOC-11 |
| HG-R211 | Throwaway-canary plumbing lives in `scripts/_throwaway_lib.sh`, sourced (never executed) by all three canaries. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/_throwaway_lib.sh` · DOC-12 |
| HG-R212 | The three throwaway canaries wire into `canaries.yml`: workflow_dispatch, nightly cron 08:17 UTC, PR→main; push intentionally NOT wired. | P1 | ✅ done | ✅ lifecycle | internal | `.github/workflows/canaries.yml` · DOC-13 |
| HG-R213 | canaries.yml requires `secrets.CANARY_TOKEN` + `vars.CANARY_ACCOUNT` (refuses GITHUB_TOKEN/guess); missing either posts SKIPPED + exits 0. | P1 | ✅ done | ✅ lifecycle | internal | `.github/workflows/canaries.yml` · DOC-14 |
| HG-R214 | The orchestrator resolve step filters the matrix by bin-on-disk presence so a new canary lands without a flaky window. | P2 | ✅ done | ✅ lifecycle | internal | `.github/workflows/canaries.yml` · DOC-15 |

### JIRA-INTEGRATION

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R215 | `bin/jira-ingress` is an ingress path, NOT the only path (allocator accepts direct admin invocation without any JIRA key). | P1 | ✅ done | ✅ lifecycle | internal | `bin/jira-ingress` · JIRA-01 |
| HG-R216 | Manual mode validates fields against the git-commit-audit lens before filing. | P2 | ✅ done | ✅ lifecycle (offline) | internal | `scripts/jira-ingress.sh` · JIRA-02 |
| HG-R217 | Claude mode composes spec'd title/body/kind from a one-liner; surfaces `QUESTION:` on a gap and re-invokes until complete. | P2 | ✅ done | ✅ lifecycle (test_R217_jira_ingress_claude_render_flows_into_ticket) | internal | `scripts/jira-ingress.sh` · JIRA-03 |
| HG-R218 | Sprint routing: no `--sprint` → backlog; active `--sprint <N>` binds via JIRA custom-field so the Automation rule fires the allocator workflow. | P1 | ✅ done | ✅ lifecycle (test_R218_jira_ingress_sprint_routing_in_sprint_vs_backlog) | internal | `scripts/jira-ingress.sh` · JIRA-04 |
| HG-R219 | Preview/render-only paths (`--dry-run`, `--no-submit`, off-grid) work without acli or JIRA Automation; dry-run names the Automation expectation. | P2 | ✅ done | ✅ lifecycle (offline) | internal | `scripts/jira-ingress.sh` · JIRA-05 |
| HG-R220 | Submit backend is the OFFICIAL Atlassian CLI `acli`; ingress emits a precondition banner with install+auth commands when absent; never auto-installs. | P1 | ✅ done | ⚠️ live-only (offline acli arg-vector banner covered via test_R220_jira_ingress_test_mode_prints_acli_arg_vector; the REAL acli submit is live-only) | internal | `scripts/jira-ingress.sh` · JIRA-06 |
| HG-R221 | JIRA is an optional integration; the allocator/branch naming omits the JIRA segment when absent and requires no change to run without a tracker. | P0 | ✅ done | ✅ lifecycle | internal | `scripts/allocate-pool-branch.sh` · JIRA-07 |

### SKILLS

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R222 | 12 git-* audit skills ship under `.io.v4rian.how-git/skills/`. | P0 | ✅ done | ✅ lifecycle (presence) | internal | `skills/git-*` · SKILL-01 |
| HG-R223 | `git-commit-audit/SKILL.md` body is used as system context for the per-commit claude judgment layer. | P0 | ✅ done | ✅ lifecycle | internal | `skills/git-commit-audit` · SKILL-02 |
| HG-R224 | `git-reconcile-intent` drives the auto-rebase L1-L5 ladder; `how-dev` is the binding post-push CI discipline; both ship repo-agnostic. | P0 | ✅ done | ✅ lifecycle (presence) | internal | `skills/git-reconcile-intent`, `skills/how-dev` · SKILL-03 |
| HG-R225 | Claude-driven judgment steps (auto-rebase L1-L5, snapshot preflight, strategy audits) are the framework's differentiator and stay claude-driven. | P0 | ✅ done | ✅ lifecycle | internal | `skills/git-*` · SKILL-04 |

### MISC

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R226 | Hotfixes follow the same `pool → dev → main` path; no out-of-band route; allocate `pool/nN.fix.JIRA-XXX-…` from dev HEAD. | P0 | ✅ done | ✅ lifecycle | internal | `docs/Git_Strategy.md` · MISC-01 |
| HG-R227 | A true bypass (catastrophic incident) is a documented admin override, not a policy. | P2 | ✅ done | - n/a (policy) | internal | `docs/Git_Strategy.md` · MISC-02 |
| HG-R228 | License is MIT. | P2 | ✅ done | - n/a | internal | `.io.v4rian.how-git/LICENSE` · MISC-03 |
| HG-R229 | Active-requirement stored in two places per branch: the lane's tracked `requirements/<pool ref with / as __>` file + `[REQ]` commit body; fetched via `get-active-requirement.sh` (lane file first, then the file the [REQ] commit added or its body, then a legacy shared `active-requirement` the lane changed, exit-0 empty otherwise); `migrate-active-requirement.sh` moves legacy lanes. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/get-active-requirement.sh` · MISC-05 |
| HG-R230 | Auditors that spawn claude (auto-rebase L1-L5, post-checkout preflight) prepend the active requirement to every prompt. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/auto-rebase-pools-after-dev-merge.sh` · MISC-06 |
| HG-R231 | `open-pr.sh` is idempotent (re-run PATCHes the existing PR, no duplicate); auto-derives target/version/title/body. | P1 | ✅ done | ✅ lifecycle | internal | `scripts/open-pr.sh` · MISC-07 |
| HG-R232 | open-pr token resolution order: `$GH_TOKEN`, `$CREATE_POOL_BRANCH_TOKEN`, `gh auth token`, GCM store; `--doctor` prints deps + sources. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/open-pr.sh` · MISC-08 |
| HG-R233 | "Dev rewritten under you": auto-rebase detects orphan base and switches to `git rebase --onto origin/dev <old-base> <pool>`. | P2 | ✅ done | ✅ lifecycle | internal | `scripts/auto-rebase-pools-after-dev-merge.sh` · MISC-09 |
| HG-R234 | Tag-conflict recovery: drop the local tag and re-run (scripts idempotent on tag-exists). | P2 | ✅ done | ✅ lifecycle | internal | `scripts/claim-dev-merge.sh` · MISC-10 |
| HG-R235 | Every framework-internal file lives inside `.io.v4rian.how-git/`; root README is a 3-line consumer stub. | P1 | ✅ done | ✅ lifecycle | internal | `README.md` · MISC-11 |
| HG-R236 | Namespace directory uses the dotted reverse-DNS form `.io.v4rian.how-git/`. | P1 | ✅ done | ✅ lifecycle | internal | `.io.v4rian.how-git/` · MISC-12 |

### LATE ADDITIONS (merged 2026-05-29, PRs #129/#105/#130 - promoted from the 2 concurrent requests)

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R237 | `bin/abandoned-pool-branches` reports open pool branches with no live PR / merged-or-stale state, for hygiene triage. | P2 | ✅ done | ✅ lifecycle (abandoned ×8) | internal | `bin/abandoned-pool-branches`, `scripts/abandoned-pool-branches.sh` · PR#105/n96 |
| HG-R238 | claim-dev-merge pushes dev before tagging on each attempt and restores dev on an orphan-tag failure, so a failed claim never leaves an orphaned tag or an un-force-pushed dev. | P1 | ✅ done | ✅ lifecycle (orphan ×38) | internal | `scripts/claim-dev-merge.sh`, `scripts/_lib.sh` · PR#130/n123 |
| HG-R239 | Ruleset bypass is admins only (no Integration actor, no DeployKey, no provisioned CI identity); privileged transitions complete locally via bin/post-merge-lifecycle under the admin's own gh session. | P1 | ✅ done | ✅ lifecycle (n122 TEST) | internal | `scripts/apply-repo-rules.sh` · PR#129/n122 |

### CONSUMER-LIFECYCLE + RELEASE-INTEGRITY (landed 2026-07-02, n149-n160)

| ID | Requirement | Pri | Status | Tests | Source | Trace |
|----|-------------|-----|--------|-------|--------|-------|
| HG-R240 | Consumer repos carry SPEC provenance (source, ref, tag, stamped) written only by the vendoring tools; the framework source never carries SPEC and SPEC never participates in version derivation. | P0 | ✅ done | ✅ lifecycle (attach + sync-framework tests) | internal | `scripts/_lib.sh` (get_spec_field, stamp_spec) · n149 |
| HG-R241 | doctor --consumer runs read-only readiness diagnostics for a consumer install: vendored dir, hooksPath, MODE validity, SPEC provenance (absent = warning), override obligations. | P1 | ✅ done | ✅ lifecycle (doctor consumer readiness) | internal | `bin/doctor` · n150 |
| HG-R242 | ci-local runs the layered ci tree locally when Actions is off, reusing the dispatcher's own discovery walk and env contract, with required versus advisory exit semantics. | P1 | ✅ done | ✅ lifecycle (ci-local enumerates + filters) | internal | `bin/ci-local` · n151 |
| HG-R243 | attach vendors the framework into an existing repository as one atomic adoption commit: connected MODE, SPEC stamped, workflows wired, ignore entries appended, dev seeded, hooks activated; refuses targets already carrying a copy. | P0 | ✅ done | ✅ lifecycle (attach adopts an existing repo) | internal | `bin/attach`, `scripts/attach.sh` · n152 |
| HG-R244 | sync-framework migrates a consumer's vendored copy to any framework revision, up or down, by three-way apply of the source diff with consumer-owned state excluded, restamping SPEC to the target. | P0 | ✅ done | ✅ lifecycle (sync-framework migrates the vendored copy) | internal | `bin/sync-framework`, `scripts/sync-framework.sh` · n153 |
| HG-R245 | The doc-freshness gate's opt-in claude worker rewrites stale tracked docs in place and commits them, pushing the PR head only under an explicit push opt-in; every unavailability path warns without reddening the check. | P2 | ✅ done | ✅ lifecycle (doc-freshness gate, canned worker) | internal | `scripts/workflows/doc-freshness-check.sh` · n154 |
| HG-R246 | Every v* tag build is a release-type compile (BUILD_TYPE=release exported to build.sh); promotion reuses the dev tag's artifact without a rebuild, so debug configurations never produce tagged artifacts. | P0 | ✅ done | ✅ lifecycle (build-retry exports release BUILD_TYPE) | public | `scripts/workflows/build-retry.sh`, `scripts/build.sh` · n158 |
| HG-R247 | The release artifact audit bans debug code and debug builds from tag artifacts: deterministic hard gate (debug-named outputs, source maps, debugger statements, tarball payloads extracted) plus an additive claude inspection, enforcing when it runs and warning when unavailable. | P0 | ✅ done | ✅ lifecycle (artifact audit ×3) | public | `scripts/workflows/release-artifact-audit.sh` · n158 |
| HG-R248 | The release test surface proves tag artifacts run as intended before distribution: portability report (file type, Mach-O minos floor), generic run checks, and a consumer override obligation mirrored in doctor. | P0 | ✅ done | ✅ lifecycle (release-test ×3 + doctor obligation) | public | `scripts/release-test.sh` · n158 |
| HG-R249 | finalize-pool-merge resolves the merged pool branch under both the flat and the prefixed pool/vYYYY.MAIN/nN layouts. | P1 | ✅ done | ✅ lifecycle (finalize resolves prefixed pool branch) | internal | `bin/finalize-pool-merge` · n156 |
| HG-R250 | The gh mock models per-PR mergeability (CONFLICTING override) so conflict paths are testable offline; validate-pr-open's reconcile seeding is suite-locked for both verdicts. | P1 | ✅ done | ✅ lifecycle (mock conflicting PRs + reconcile seeding) | internal | `framework-tests/_gh_mock.py` · n160 |
| HG-R251 | Claim ceremonies converge under failure injection: a retry over a sealed dev completes idempotently, and a mid-ceremony push failure never corrupts local state (re-run converges the restored origin). | P1 | ✅ done | ✅ lifecycle (mid-ceremony death + push failure) | internal | `scripts/claim-dev-merge.sh` · n160 |
| HG-R252 | Version math holds at depth: DEV per pool merge, SERIES advance + DEV reset per release across three cycles and twelve merges, and prior-year merges never count toward the current year's counters. | P1 | ✅ done | ✅ lifecycle (release cycles + year rollover) | internal | `bin/version` · n160 |
| HG-R253 | The core hooks enforce through the real git entry points: pre-commit scrubs on a real commit, commit-msg rejects on a real commit, pre-push rejects and accepts on a real push. | P1 | ✅ done | ✅ lifecycle (hooks fire through real git operations) | internal | `githooks/` · n160 |
| HG-R255 | Commit audit receipts gate: bodies asserting observed behavior name the verifying artifact (Receipts: section); the judge flags unreceipted claims as AUDIT_FAIL receipts, distinct from shape failures; no-claim commits exempt. Promoted from the manual feature-request file (vxtr session, 2026-07-02). | P0 | ✅ done | ✅ lifecycle (receipts rubric asserts) | internal | `skills/git-commit-audit` §J, `scripts/_lib.sh` · n161 |
| HG-R256 | Artifact build-number identity: filenames carry the commit short sha, release builds refuse a dirty tree (dev builds labeled dirty), and aged siblings sweep to a recoverable artifact trash, never deleted. Promoted from the manual feature-request file (vxtr, 2026-07-02). | P0 | ✅ done | ✅ lifecycle (sha label + dirty gate + retention) | public | `scripts/build.sh` · n162 |
| HG-R257 | ci-local --archive records each run's verdict chain on refs/v4rian/ci-log, a custom ref outside heads and tags so origin pushes can never trigger workflows; unreachable origins degrade to a local archive with a WARN. Promoted from the off-grid CI feature request's v2 scope (2026-06-28). | P1 | ✅ done | ✅ lifecycle (archive ref chain + origin push) | internal | `bin/ci-local` · n163 |
| HG-R258 | A per-user skills tree (~/.config/how-git/skills, HOW_GIT_USER_SKILLS_DIR to relocate) overrides any in-repo audit skill by name and adds new ones; every claude-pointing consumer (smart-commit, commit-audit, judge prompts, reconcile) resolves through resolve_skill, with user-only skills merged into smart-commit's referenced set. | P1 | ✅ done | ✅ lifecycle (user skill override resolution) | internal | `scripts/_lib.sh` (resolve_skill, list_user_extra_skills) · n164 |
| HG-R254 | The strategy doc carries a Design Rationale section consolidating the why behind every load-bearing decision; the lifecycle suite's scratch scaffolds never inherit host consumer state. | P2 | ✅ done | ✅ doc-freshness gate + lifecycle (scaffold isolation via connected-mode tests) | internal | `docs/Git_Strategy.md` · n157, `framework-tests/test-lifecycle.sh` · n155 |

---

## Units of Intent
<!-- NOT binding, NOT protected. Promotes to a Hard Requirement when a sprint activates or an idea is locked. -->

| ID | Intent | Pri | Source | Sprint | Notes |
|----|--------|-----|--------|--------|-------|
| HG-I09 | GravityDB-backed requirements register storage (model unchanged; Markdown remains authoritative until scheduled). | P3 | operator (register header note) | - | Storage-layer swap only; no row semantics change. |
| ~~HG-I01~~ | **Request #1 (tag-regression)** - PROMOTED 2026-05-29 → **HG-R238** (claim no-orphan-tag / restore-dev force-push, PR #130, merged). | - | internal | done | Lineage crumb; lives now as HG-R238. |
| ~~HG-I02~~ | **Request #2 (cleanup-prs)** - PROMOTED 2026-05-29 → **HG-R237** (abandoned-pool-branches helper, PR #105) + **HG-R239** (apply-rules retry, PR #129), both merged. | - | internal | done | Lineage crumb; lives now as HG-R237 + HG-R239. |
| HG-I03 | doc-freshness **auto-rewrite worker**: apply + push the rewritten docs (today detection + block only; `invoke_claude_worker_stub` emits `AUTOFIX_STUB=stub-only-no-real-call`). | P2 | internal | - | Genuine internal stub at `scripts/workflows/doc-freshness-check.sh:261`; the gate (block on stale docs, HG-R138) is done. |
| HG-I04 | **User-space claude-skills** override + expansion folder. | P3 | internal | - | Explicitly deferred to a later release per user direction (CHANGELOG). |
| HG-I05 | **Off-grid allocation** (pool/safety pair creation while off-grid). | P3 | internal | - | Shipped: `bin/create-pool-branch` runs `scripts/allocate-pool-branch.sh` locally (RUNBOOK "Off-grid allocation"); only `bin/bootstrap-offgrid` remains open. |
| HG-I06 | **JIRA → endpoint webhook automation** (the JIRA-Automation → `gh workflow run` rule itself, end to end). | P3 | internal | - | Marked out-of-scope/separate-work in the docs; ingress + routing client-side are done (HG-R218). |
| HG-I07 | Framework's **own first dev→main release** (chicken-and-egg: `Use this template` is fully canonical only after the first release). | P1 | internal | - | Operational milestone, not code; tracked so it is not forgotten. |
| HG-I08 | **Re-evaluate `allow_force_pushes=true` on `dev`** - it enables the claim-amend force-push but lets any `contents:write` identity force-push the shared branch. Design a posture that normalizes the merge subject without a protected-branch history rewrite (merge-time `merge_commit_title`, or a fast-forward-safe tag-only claim). | P2 | internal | **next major version sprint** | Deferred by Joel 2026-05-29; do NOT act now. See final design-gaps report. |

---

## Scrapped
<!-- Graveyard. Kept for traceability. Never deleted. -->

| ID | Requirement | Scrapped | Why |
|----|-------------|----------|-----|
| HG-S01 | Standalone branch-creator HTTP service (`POST /v1/branches`, separate stack/deploy). | 2026-05 | Superseded by the in-repo allocator workflow (`allocate-pool-branch.yml` + `scripts/allocate-pool-branch.sh` + `bin/create-pool-branch`). README spec retained at `services/branch-creator/` for historical reference. Allocator requirements (HG-R038…R056) are the live replacement. |
| HG-S02 | Root `VERSION` file storage model (CI reads/updates a tracked VERSION file). | 2026-05 | Superseded by tags-as-seal; a stray root VERSION now triggers a heal warning + deletion (HG-R119). IMPLEMENTATION_HANDOFF still documents the old model as historical. |
