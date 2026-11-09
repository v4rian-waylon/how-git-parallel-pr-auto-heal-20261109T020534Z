# how-git

**Template repository for the v4rian way of doing git.**

A minimal, production-safe branching model built around stability,
traceability, parallel development, and atomic version claiming on PR
merge. Clone the template and push - no install step, no `make
setup`, no CI required. Hooks auto-activate on first script use;
version bumping happens via in-repo scripts (`claim-dev-merge.sh`,
`claim-main-release.sh`).

The template's working content lives under the hidden namespace
directory `.io.v4rian.how-git/` so consumer projects bootstrapped from
this template have a clean repo root for their own code, with only
`.gitignore` at top level (tags are the version seal; there is no `VERSION` file).

---

## What's in the box

```
<repo-root>/
├── .gitignore                              ← stays at root; git reads from here
├── README.md                               ← repo root README for first-time visitors
├── .github/workflows/                      ← seven CI dispatchers (see below)
└── .io.v4rian.how-git/                     ← every template file lives here
    ├── README.md                           ← you are here
    ├── LICENSE
    ├── docs/
    │   ├── Git_Strategy.md                 ← THE strategy (read this first)
    │   ├── IMPLEMENTATION_HANDOFF.md       ← for engineers/agents building infra
    │   ├── repo-config.md                  ← branch protection / Repository Rules (optional)
    │   ├── RUNBOOK.md                      ← operator cheat sheet
    │   ├── CONTRIBUTING.md                 ← contributor flow + commit conventions
    │   └── CHANGELOG.md                    ← human-readable companion to the tag chain
    ├── githooks/                           ← core.hooksPath points here
    │   ├── pre-commit                      ← scrubs em/en-dashes from staged prose files only (code and data keep their bytes; the vendored copy is exempt in consumers; same rule as the push-side dash gate in `commit-audit.sh`)
    │   ├── prepare-commit-msg              ← smart auto-fix layer (dash scrub + tag derivation + bullet rewrite); opt out with `HOW_GIT_AUTOFIX=0` or `git config howgit.autofix false`; never rewrites rebase/cherry-pick replays; `[MERGE]` bodies get only the rule scrub, keeping their list
    │   ├── commit-msg                      ← subject length (8-100, 140 for `[MERGE]`/`[REQ]`), approved `[TAG]` plus sentence case, the message rules (no em/en dash, no "plus" in prose, no Claude co-author trailer) + merge message shape gate
    │   ├── pre-push                        ← validates every pushed destination ref name (detached HEAD works) and re-checks the message rules on newly published working-branch commits + merge message shape gate
    │   ├── post-checkout                   ← warns on local non-conforming names (same shared regex)
    │   ├── post-merge                      ← AUTO-claims version when `git pull` brings a new merge onto dev / main (the automator)
    │   └── README.md
    ├── scripts/                            ← maintenance + operator-run-canary scripts
    │   ├── _lib.sh                         ← shared helpers: the pool kind list (`HG_BRANCH_KINDS`, `hg_kind_ok`), hook wiring, dep auto-install (gh/jq/python3), allocator app-id lookup, precondition banner emitter, claude_resolve_conflict + claude_render_spec wrappers, and the one branch-name regex (`HG_BRANCH_RE`), message rules, dash rule, credential strip, and SPEC source probes every hook and script sources
    │   ├── _throwaway_lib.sh               ← shared helpers for the throwaway-creation canaries (token resolution, seed, clone retry, delete); sourced by verify-template, test-off-grid-e2e, and test-parallel-pr-auto-heal-canary
    │   ├── lib/auto-fix-commit-message.sh  ← shared commit-message auto-fix (dash scrub + tag derivation + bullet rewrite) sourced by the hooks + smart-commit
    │   ├── audits/                          ← the four audit gates run by ci-dispatch sys-layer
    │   │   ├── commit-audit.sh             ← per-commit claude judgment: tag fit, fabricated symbols, atomicity, body-vs-diff
    │   │   ├── compile.sh                  ← compile gate
    │   │   ├── coverage.sh                 ← binary-coverage gate (N/A pass with no recognised project type)
    │   │   └── runtime.sh                  ← boot/runtime gate
    │   ├── workflows/                       ← per-trigger CI step scripts invoked by ci-dispatch.yml (ci-dispatch.sh, *-retry.sh, doc-freshness-check.sh, offline-test.sh, verify-actor-admin.sh, verify-dispatch-ref.sh, claim-tag-drift-sanity.sh)
    │   ├── abandoned-pool-branches.sh      ← read-only reporter; enumerates pool branches that look abandoned without deleting any ref (safety anchors stay forever)
    │   ├── allocate-pool-branch.sh         ← canonical pool/* + safety/* atomic allocator (called by allocate-pool-branch.yml, and locally off-grid); --help lists every counter source
    │   ├── lint-protocol.sh                ← deterministic consistency lint over skills, protocol docs and allocator kinds; `--copy <path>` reports drift of a vendored copy
    │   ├── apply-repo-rules.sh             ← applies branch protection + Repository Rules via gh CLI (self-contained: admins are the only ruleset bypass, auto-installs missing CLIs on macOS, accepts Teams plans)
    │   ├── get-active-requirement.sh       ← resolves the currently-active requirement/sprint binding for a branch
    │   ├── post-merge-lifecycle.sh         ← local privileged vault / delete / reconcile after a pool→dev merge
    │   ├── archive-pool-branch.sh          ← vaults a merged pool branch to vault/nN.*
    │   ├── auto-rebase-pools-after-dev-merge.sh   ← L1-L5 reconcile ladder for sibling pools
    │   ├── build.sh                        ← canonical project-type-dispatching build script (consumer overrides for real recipes)
    │   ├── release-test.sh                 ← run + portability gate over tag artifacts (consumer overrides for real launch tests)
    │   ├── claim-dev-merge.sh              ← canonical dev-merge claim: tag + archive + auto-rebase
    │   ├── claim-main-release.sh           ← canonical main-release claim: tag + (Release) + GC safety
    │   ├── check-merge-message.sh          ← deterministic merge title + body shape gate (hooks, claims, validate-pr-open)
    │   ├── check-merge-parity.sh           ← PR body equals merge body minus the claim's PR reference paragraph
    │   ├── distribute-internal.sh          ← PLACEHOLDER; project fills in
    │   ├── distribute-public.sh            ← default: gh release upload
    │   ├── heal.sh                         ← repair script: re-set core.hooksPath, re-chmod
    │   ├── jira-ingress.sh                 ← files JIRA tickets to spec via Atlassian acli (manual fields or claude-driven prompt; sprint binding via --from-json custom-field)
    │   ├── open-pr.sh                      ← opens or updates a PR for the current branch (idempotent)
    │   ├── sync-framework.sh               ← migrates a consumer's vendored framework copy to any source revision (up or down)
    │   ├── test-off-grid-e2e.sh            ← operator-run off-grid lifecycle e2e against a real throwaway repo
    │   ├── test-parallel-pr-auto-heal-canary.sh   ← operator-run parallel-PR auto-heal scenario canary against a real throwaway repo
    │   ├── validate-pr-open.sh             ← canonical PR-open validator (called by validate-pr-open.yml)
    │   ├── verify-template.sh              ← end-to-end test of the template
    │   └── reconstruct.sh                  ← library behind bin/reconstruct (sourced, never executed)
    ├── agent-hooks/                        ← agent-side guards (shared/ + claude/ + codex/ adapters), installed by bin/install-agent-hooks
    ├── bin/                                ← operator binaries
    │   ├── install-agent-hooks             ← installs the agent hooks into Claude Code and Codex CLI (merge, backup, idempotent, --uninstall)
    │   ├── version                         ← canonical version utility (3-segment, merge-count math)
    │   ├── status                          ← current-state snapshot
    │   ├── ship                            ← one-command dev to main release
    │   ├── release-of                      ← commit to release-tag lookup
    │   ├── changelog                       ← markdown release notes from tag history
    │   ├── preview-merge                   ← safe dry-run of a pending PR merge
    │   ├── queue                           ← open PR overview with conflict prediction
    │   ├── doctor                          ← one-shot template health check (--consumer for consumer install readiness diagnostics)
    │   ├── smart-commit                    ← guided commit helper (dash scrub + tag derivation + bullet rewrite at compose time); audit skills resolve through the per-user override tree (~/.config/how-git/skills)
    │   ├── bootstrap-ci                    ← one-shot repo-level CI setup (idempotent, --check / --dry-run)
    │   ├── ci-local                        ← runs the layered ci tree locally when Actions is off (off-grid / no remote); --workflow <name> runs a thin entry's trigger off grid; --archive records runs on refs/v4rian/ci-log (custom ref, never fires workflows); merge claims run only with --allow-claim
    │   ├── finalize-pool-merge             ← off-grid pool→dev close-up (local merge + claim ceremony without a remote)
    │   ├── post-merge-lifecycle            ← local privileged vault / delete / reconcile after a pool→dev merge
    │   ├── abandoned-pool-branches         ← read-only reporter for pool branches that look abandoned
    │   ├── create-pool-branch              ← local CLI wrapper: allocator workflow (connected) or local allocator (off-grid)
    │   ├── init-pool-merge                 ← local CLI for opening a pool/* to dev PR (validate-pr-open amends)
    │   ├── init-release                    ← local CLI for opening a dev to main release PR (body seeded in the merge shape from the pool merges)
    │   ├── reject-pr                       ← close a PR as a structured rejection; the branch stays for fixes and a reopen
    │   ├── jira-ingress                    ← files JIRA tickets to spec from manual fields or a claude-driven casual prompt (acli backend)
    │   ├── sync-framework                  ← migrates a consumer's vendored framework copy to any source revision (up or down)
    │   ├── test-off-grid-e2e               ← operator-run e2e: real throwaway repo + full off-grid lifecycle
    │   ├── test-parallel-pr-auto-heal-canary  ← operator-run e2e: real throwaway repo + parallel-PR auto-heal scenarios
    │   └── reconstruct                     ← git-reconstruct mechanics: identity, scaffold, gaps, audit-structure, scrub, preflight, relocate, fast-forward, verify-artifacts, plus three claude judgment calls under a one line contract; --help is the reference
    ├── skills/                             ← 13 git-* skills (full lens stack) + git-reconstruct, how-dev; git-shuttle/tools/ ships the deterministic content-match.sh (Step C two-sided parent ranking, deletions included) and integration-check.sh (Step C.5 INTEGRATED / INTEGRATED_ELSEWHERE / NEW triage), sharing one scope rule set (NAME/, a/b/ and NAME excludes printed on stderr, links compared as links, unreadable files exit 3)
    │   ├── git-{commit,compile,coverage,merge,runtime,strategy}-audit/
    │   ├── git-{history-preservation,history-rewrite,reconcile-intent,shuttle,snapshot-preflight,snapshots,token-discovery}/
    │   ├── git-reconstruct/                ← consolidating many source projects into one new repo, driven by bin/reconstruct
    │   └── how-dev/                        ← developer-discipline skill shipped alongside the git-* lens stack
    ├── rulesets/                           ← Repository Ruleset JSON definitions
    │   ├── dev-required-checks.json        ← required status checks bound on PRs into dev
    │   ├── pool-creations.json             ← pool/* creation pinned to the allocator workflow identity
    │   ├── pool-deletions.json             ← pool/* deletion pinned to the claim/vault identity
    │   ├── safety-lockdown.json            ← safety/* create/update/delete pinned to allocator + claim
    │   └── vault-readonly.json             ← vault/* refs frozen read-only once a pool is archived
    ├── services/branch-creator/
    │   └── README.md                       ← historical spec for the standalone allocator endpoint
    └── framework-tests/
        ├── _gh_mock.py                     ← offline `gh` CLI stub for hermetic lifecycle tests
        ├── _gh_mock_enable.sh              ← puts the gh mock on PATH for a test run
        ├── test-hooks.sh                   ← exercises the local hooks
        ├── test-agent-hooks.sh             ← agent-hooks guards + install-agent-hooks against a fake HOME
        └── test-lifecycle.sh               ← offline tests covering hooks + scripts + CI + full cycle
```

**Eleven CI workflows ship under `.github/workflows/`** (added incrementally over `pool/n6`, `pool/n11`, `pool/n13`, `pool/n26`, `pool/n32`, `pool/n33`, `pool/n35`, `pool/n51`, `pool/n87`):
`allocate-pool-branch.yml`, `audit-pushed-branch.yml`, `bootstrap-ci.yml`, `build-on-tag.yml`, `canaries.yml`, `ci-dispatch.yml`, `dev-merge.yml`, `doc-freshness.yml`, `main-merge.yml`, `seed-dev-on-main-create.yml`, `validate-pr-open.yml`. They are thin acceptance dispatchers that invoke the in-repo scripts; the model itself runs on git alone and the workflows degrade gracefully on other forges. The earlier `claim-on-merge-dev.yml` and `claim-on-merge-main.yml` workflows, and the event-driven half of the old `build-on-tag.yml`, have been folded into `ci-dispatch.yml` as its `pr-merge-dev`, `pr-merge-main`, and `tag` triggers. Four named manual entries sit on top of that one engine: `audit-pushed-branch.yml` (push tree on a branch or tag of this repo, or a commit on a branch), `dev-merge.yml` and `main-merge.yml` (re-claim) and `build-on-tag.yml` (rebuild of one tag, `-f tag=vX`) are `workflow_dispatch`-only callers of `ci-dispatch.yml` through its `workflow_call` entry with their trigger label, all four behind `verify-actor-admin.sh`, passing secrets by name; `ci-dispatch.yml` refuses a requested ref that is a pull request head or foreign to the repo (`scripts/workflows/verify-dispatch-ref.sh`). They carry no event trigger and no logic of their own, so no event runs a job twice, and each has an off-grid twin, `bin/ci-local --workflow <name>`, which reads the trigger from the workflow file; ci-local skips the `pr-merge-dev` / `pr-merge-main` claims unless `--allow-claim` is passed. The manual entries and `ci-local` are re-runs for reading and repair: neither satisfies a PR required check, only the push run of the head SHA does (re-run that `ci-dispatch.yml` run to re-green one). `ci-dispatch.yml` is the layered CI dispatcher that fans out a separate status check per shell script under `ci/{tests,audits}/<trigger>/` at the repo root (consumer-owned usr layer) and `.io.v4rian.how-git/ci/{tests,audits}/<trigger>/` (framework-owned sys layer, gated on the FRAMEWORK_REPO marker). The framework's own pr-open audit + test gates live as sys-layer `required.compile.sh`, `required.coverage.sh`, `required.runtime.sh`, and `required.offline-test-suites.sh` files; the `required.*` filename prefix marks each as a required status check on PRs to dev, bound automatically by `bin/bootstrap-ci`. The folded `pr-merge-dev` / `pr-merge-main` claim handlers run on the push to dev / main, with `dev-merge.yml` / `main-merge.yml` as the admin-gated manual re-claim escape when the automatic push run does not complete; each wraps the canonical claim script invocation in an exponential-backoff retry loop with a 4320 minute job timeout. Retries ride out transient API or network failures, but the workflow exits failed once attempts are exhausted so persistent failures still surface. The folded `tag` trigger invokes the canonical `scripts/build.sh` on every `v*` tag push (and through `build-on-tag.yml` for admin re-builds), with the same exponential backoff retry shape and a `BUILD_IDEMPOTENCY_CHECK` probe that short-circuits when output for the target tag is already present. Every tag build is a release-type compile (`BUILD_TYPE=release` - the release ceremony reuses the dev tag's artifact at main promotion without a rebuild, so debug code and debug builds are banned from the artifact path), and the same job then chains `release-artifact-audit.sh` (deterministic no-debug scan over the artifacts plus an additive claude inspection) and the consumer-overridable `scripts/release-test.sh` run + portability surface proving the artifacts run as intended; distribution is a separate bundle and is not wired in here. `bootstrap-ci.yml` runs the one-shot repo-level CI setup, and `doc-freshness.yml` gates documentation staleness on PRs; with `DOC_FRESHNESS_AUTOFIX=1` the gate also runs an opt in claude worker that refreshes the stale docs and commits them, pushing the PR head only under `DOC_FRESHNESS_AUTOFIX_PUSH=1`. `validate-pr-open.yml` fires on every PR opened, edited, or synchronize event into dev or main and runs the canonical `validate-pr-open.sh` script that auto-derives the title from `bin/version`, scrubs the body's characters only (no tag, no list flattening, no signature, since the body becomes the merge body), gates it with `check-merge-message.sh`, and posts the `opened-via-correct-flow` status check (failure when the body breaks the merge shape). `canaries.yml` orchestrates the three throwaway canaries (`verify-template.sh`, `bin/test-off-grid-e2e`, `bin/test-parallel-pr-auto-heal-canary`) on `workflow_dispatch` (manual operator dispatch with a `canary` input picking one or `all`), `schedule` (nightly cron at 08:17 UTC), and `pull_request` opened/synchronize/reopened against `main` (the pre-release sweep); each canary creates and deletes a real GitHub repo per invocation, so push triggers on every dev advance are intentionally avoided and the job posts a SKIPPED summary + exits 0 when the operator has not configured `secrets.CANARY_TOKEN` + `vars.CANARY_ACCOUNT`. The original "No `Makefile`" claim still holds: the template is tooling-minimal and every operation is either a bin or a script.

**Canonical source.** The framework repo's own `dev` is the single source of the spec: `skills/`, `docs/` and every rule above. Every other `.io.v4rian.how-git/` tree, the vendored copy in a consumer repo or a workspace copy such as fractaris's, is a copy migrated by `bin/sync-framework` and checked against this repo, never edited as a source. Where a skill, a doc and a hook disagree, the hook or script is the behaviour and the prose is the defect. Skills carry only the rules no hook or script enforces; a rule a hook owns appears once, as an "enforced by" line naming that hook.

**Loader.** `skills/how-git/SKILL.md` is the entry point an agent invokes before git work: its decision tree maps each task (commit, branch, merge, release, rewrite, rebuild) to the one to three skills and the `bin/*` tools to read, so a commit loads `git-commit-audit` alone instead of every skill and both strategy docs. It also carries the binding rules no hook enforces; the lifecycle suite keeps it under 6,500 bytes and fails if it names a skill or tool that does not exist.

---

## The v4rian way in one paragraph

Every working branch is paired at birth with a `safety/` anchor branch
that captures the exact commit it was branched from, atomically, by
the repository itself, never by a developer. Working branches live
under the `pool/` namespace (e.g. `pool/n7.fix.PROJ-123-token_leak`)
and their paired anchors mirror the suffix under `safety/`. Versions
follow `v{YYYY}.{SERIES}.{DEV}` and are claimed
atomically by whichever PR merges first. Dev merges tag internally;
main merges promote to public Releases. Safety anchors stay forever,
released or abandoned, as the institutional record of where every
working branch was allocated. The full design and invariants are in
[`docs/Git_Strategy.md`](docs/Git_Strategy.md); the why behind each
load-bearing decision is consolidated in its Design Rationale section.

---

## Modes: connected and off-grid

The framework runs in two modes recorded in `.io.v4rian.how-git/MODE`:
`connected` (default) and `off-grid`. The operator-facing workflow is
identical in both. An allocator produces an atomic pool plus safety
pair at the dev tip, pool branches merge into dev via PR with a claim
ceremony amending the merge subject and tagging the dev tip, dev
merges into main with a release ceremony tagging the release and
archiving the pool refs to vault. Only the under-the-hood
implementation differs. Connected mode dispatches GitHub workflows
that POST to the Git Data API and `gh pr create` against the remote.
Off-grid mode invokes the same canonical scripts locally so they
mutate refs in the working copy via `git update-ref --stdin`,
`git commit-tree`, and the post-merge hook. Flip between modes with
`bin/set-mode connected` or `bin/set-mode off-grid`. A flip to off-grid
is local and needs no GitHub admin (the remote's own rules still guard
every push); a flip to connected checks GitHub admin and its refusal
lists the fixes. A new repo is seeded in one step with
`bin/bootstrap-offgrid`: it heals the hooks, commits the namespace by
name when the repo is empty, flips to off-grid and publishes main and
dev in one atomic push leased on both being absent, so nobody pushes
main by hand.

Off-grid, `bin/create-pool-branch` allocates locally and never reissues
a number it can see; `scripts/allocate-pool-branch.sh --help` and
RUNBOOK "Off-grid allocation" list what it counts, fetches, refuses and
reserves, and the window that remains between two separate clones.

The workflow files still ship in an off-grid repo, so GitHub may start
runs on its pushes, but `ci-dispatch.yml` resolves every event-driven
run to no trigger once `MODE` reads `off-grid`: no gate, claim or build
job executes remotely, and `bin/ci-local` runs the same tree locally.
The admin-gated manual entries still run the trigger they name.

### Merge policy and warp mode

Who may merge a pool into dev, and how, is a per-repo choice committed in
`.io.v4rian.how-git/MERGE_POLICY` (documented key=value lines; defaults
keep the behaviour from before the file existed):

| Key | Values (default first) | Effect |
|---|---|---|
| `dev_merge_who` | `admins`, `anyone`, `list` | who may merge a pool into dev; `admins` = `admins.txt` (absent file = permissive first run) |
| `dev_merge_list` | comma-separated emails | allowed mergers when `dev_merge_who=list` |
| `dev_merge_pr` | `required`, `optional` | connected mode: pre-push refuses a local merge push to dev unless optional |
| `dev_merge_approval` | `none`, `required` | merge commit needs `Approved-by: <email>` from another allowed merger |
| `dev_merge_gates` | comma-separated `ci-local` push checks | must pass before the off-grid close-up |
| `dev_merge_max_commits` | `20`, any integer, `0` = no cap | most non-merge commits one pool may bring into dev; bigger deliveries land as sequential pools; never lifted by warp |

`bin/set-merge-policy` prints the policy, reads one key (`--get KEY`) or
validates and commits `KEY=VALUE` changes as a `[MODE] set merge policy`
commit, admin-gated like `bin/set-mode`. `bin/finalize-pool-merge`
enforces who, approval, the commit cap and gates; `bin/init-pool-merge`
announces the policy and refuses a pool above the cap; the pre-push hook
enforces the cap on every merge pushed to dev and who and PR on direct
merge pushes to dev. The commit-time atomicity gate (5 or more top-level
dirs) honours its multi-paragraph bypass only up to
`git config howgit.atomicMaxFiles` staged files (default 50). `bin/doctor` rejects unknown keys and invalid values.

What is enforced where:

| Path | Enforced | Announced only |
|---|---|---|
| Off-grid close-up (`bin/finalize-pool-merge`) | who, approval trailer, gates | |
| Direct merge push to dev (pre-push, outside CI) | who; PR when connected and `dev_merge_pr=required` | |
| Connected PR merged on GitHub | the dev required status checks `apply-repo-rules.sh` sets | who and approval (`bin/init-pool-merge` prints them) |

No local hook runs on a GitHub-side merge, and the framework writes no
server rule for `dev_merge_who`, `dev_merge_approval` or warp: dev
protection sets `required_pull_request_reviews=null`, and flipping warp
changes no server ruleset. `bin/attach` vendors with `WARP` reset to off;
`bin/sync-framework` treats `WARP` as consumer-owned and never migrates it.

`bin/warp on|off|status` flips the committed `WARP` flag (admin-gated,
logged as `[MODE] warp on|off`). While on, developers merge pools into
dev without PRs whatever the policy says about who, PR and approval,
which suits prototyping and pre-launch work; required gates still run
and dev to main rules are never touched. `bin/status`, `bin/doctor`,
`bin/init-pool-merge`, `bin/finalize-pool-merge` and pre-push print
`WARP MODE ON` while it is on. `MERGE_POLICY` and `WARP` are consumer
owned: `bin/sync-framework` never overwrites them.

---

## Portability

The only owner/repo binding in this framework is `git config --get remote.origin.url`. Every script that needs to know "what repo is this?" derives the answer at runtime from that single source. There are no hardcoded owner/repo strings in framework code, defaults, doc strings, or test assertions. Consequence: when the framework moves to a different org, the operator runs `git remote set-url origin <new-url>` once and every internal mechanism keeps working; nothing else needs to be found and updated. The lifecycle suite enforces this with a check that fails if any framework-internal file embeds an `OWNER/REPO` literal pinned to a specific account.

---

## Using this template

The template works out of the box - no install step. Git hooks
auto-activate the first time you run any in-repo script (`open-pr.sh`,
`claim-dev-merge.sh`, `claim-main-release.sh` source `scripts/_lib.sh`
and call `ensure_hooks_path` on startup), the version is derived
from tags and merge history by `bin/version`, and git preserves
executable bits via its index so nothing needs `chmod`.

### Option A - GitHub template repo (recommended)

1. On GitHub, click **Use this template → Create a new repository**
2. Clone the new repo locally
3. Run `bin/bootstrap-ci` to seed `dev`, apply branch protection,
   apply Repository Rules, bind required status checks, set merge-commit
   defaults, lock merge mode, disable auto-delete merged branches, set
   repo topics, and prune any framework-internal artifacts that arrived
   via Use-this-template. Idempotent; `--check` audits without mutating
   and `--dry-run` prints every API call.
4. Customize `.io.v4rian.how-git/docs/` as needed for your project
5. Push to your remote; hooks will auto-activate on your first
   `bash .io.v4rian.how-git/scripts/open-pr.sh` (or any other in-repo script)

**Chicken-and-egg note for the framework's own first release:** the
GitHub `Use this template` button seeds a new repo from the template's
**default branch** only. Until the framework lands its first
`dev` to `main` release, the framework files live on `dev` and the
default `main` branch carries only the intro commit (`.gitignore` and
`README.md` per the v4rian intro-commit shape). Consumers who click
`Use this template` before that first release receive a near-empty
repo. Until then, exercise the deliverable from `dev` via
`bash .io.v4rian.how-git/scripts/verify-template.sh --from-branch dev`
instead; that path seeds a throwaway consumer from any named branch on
the source. Once the first `dev` to `main` release lands, the
chicken-and-egg resolves and the `Use this template` button becomes
the canonical adoption path.

### Option B - Manual clone

The framework is org-agnostic, so the clone URL below is a placeholder. Use the actual clone URL of wherever this framework lives (the GitHub "Code" button on the framework repo gives the right value).

```bash
git clone <framework-source-url> my-new-repo
cd my-new-repo
rm -rf .git
git init
# customize as needed
git add .
git commit -m "chore: bootstrap from how-git template"
git remote add origin <your-remote>
git push -u origin main
# hooks activate on first script run (open-pr.sh, claim-*.sh)
```

### Option C - Attach to an existing repo: `bin/attach`

Midlife adoption for a repository that already has history and wants the
framework without restarting from the template. Run it FROM a framework
checkout (that checkout is the source):

```bash
.io.v4rian.how-git/bin/attach <target-repo-path>              # do the adoption
.io.v4rian.how-git/bin/attach <target-repo-path> --dry-run    # print the plan, change nothing
.io.v4rian.how-git/bin/attach <target-repo-path> --no-commit  # stage in the target, skip the commit
```

attach refuses (exit 2) when the target is not a clean git repo with at
least one commit, when it already carries `.io.v4rian.how-git/` (updating
an existing vendored copy is `bin/sync-framework`'s job), or when a
framework workflow filename collides with an existing target workflow.
On success it vendors the framework directory (FRAMEWORK_REPO marker and
SPEC excluded, exec bits preserved), resets `MODE` to `connected`, copies
the acceptance workflows, appends the missing framework `.gitignore`
entries without rewriting existing content, seeds a local `dev` branch at
HEAD, activates hooks via the target copy's `heal.sh`, stamps SPEC
provenance from the source checkout, and records the whole adoption as
one `[NEW]` commit in the target. That commit runs with hooks disabled so
the vendored copy lands byte for byte. SPEC `source=` never carries
credentials (`user:token@` is stripped, and `stamp_spec` refuses anything
that still looks like one), and when HEAD is tagged SPEC `ref=` is the
commit the tag resolves to at that source, not a local rewritten twin.
`bin/doctor --consumer` verifies the ref exists at the source. Follow up with `bin/bootstrap-ci`
(connected) or `bin/set-mode off-grid` (off-grid); the full operating
manual is `.io.v4rian.how-git/docs/RUNBOOK.md`.

### Heal: `bash .io.v4rian.how-git/scripts/heal.sh`

`scripts/heal.sh` is a **repair** script, not a first-time install.
Run it when state has drifted - `core.hooksPath` was overwritten, a
script lost its executable bit through a tool that didn't preserve
mode, or a stray `VERSION` file from a pre-redesign checkout is left at
the repo root.
Idempotent and safe to run repeatedly. A fresh clone of the template
never needs it. `--dry-run` shows what would change without mutating.
Parallel lanes never collide on their requirement: the allocator writes
each lane's text to its own `.io.v4rian.how-git/requirements/<pool ref
with / as __>`, so no two lanes add the same path and merges stay clean on
any host, forge merges included. `scripts/get-active-requirement.sh`
reads the lane file (by name, SHA, or detached HEAD alike), then the
`[REQ]` commit body, then a legacy shared `active-requirement` the lane
itself wrote. Each new lane's `[REQ]` commit drops the lane files it
inherits from dev, so merged lanes' files do not pile up. Lanes allocated
before this layout still carry the shared file: heal.sh and sync-framework
name them, and `bash .io.v4rian.how-git/scripts/migrate-active-requirement.sh`
moves each one to its lane file in one commit (nothing pushed). Lanes that
share one legacy text (a lane cut from another) are migrated with exactly
one mover per text; the others add their lane file beside the shared one,
so the merges never conflict, and the next allocated lane drops the shared
file left on dev.

### Commit message auto-fix and its opt-out

`prepare-commit-msg` rewrites messages toward the commit conventions. To
keep a message byte for byte, run one commit with `HOW_GIT_AUTOFIX=0 git
commit ...` or switch it off with `git config howgit.autofix false` (repo)
or `git config --global howgit.autofix false` (user). Rebase and
cherry-pick replays are never rewritten. The rules do not switch off:
`commit-msg` refuses a subject without an approved tag (`[NEW]`, `[FIX]`,
`[TEST]`, `[DOCS]`, `[REFACTOR]`, `[PERF]`, `[REVERT]`, `[HOTFIX]`, or the
machine shapes `[MERGE]`, `[REQ]`, `[MODE]`) or with a lowercase start after
a human tag; `fixup!`, `squash!` and `amend!` subjects are checked after the
marker; a merge in progress is left to the merge-message gate and a
rebase or cherry-pick replay keeps the subject it was first checked with. The
hooks suite runs the 200-subject jev corpus (61 seeded violations) through
it. It also refuses em/en dashes, every entry of `AUTO_FIX_BANNED_WORDS`
(default `plus`; comma separated, trimmed, phrases allowed;
`word=replacement` sets what the scrub writes, a bare entry other than
`plus` is refused but never rewritten) in prose, and a
`Co-Authored-By: Claude` trailer, whatever the subject prefix.
Identifiers are not prose: code spans, any token holding a `/` (ref names,
paths, URLs, but also `plus/minus` or a stray `plus/`), JIRA keys, hyphen
compounds, and words joined by `_` (`plus_logging`) are exempt from the
word rule and never rewritten. The lint trades these few misses for no
false refusals on identifiers; human review remains the backstop. An
unset or empty `AUTO_FIX_BANNED_WORDS` means the default list, while a
value holding only separators (`" , "`) switches the word rule off. `pre-push` re-checks the stored messages of working-branch
commits new to the destination, judged from destination facts only (the
tips it advertises and the ref's old value; never local tags, local main
or dev, or remote-tracking refs); when the destination advertises nothing
this repo has, the lane's safety anchor and the newest `vYYYY.S.D` claim
tag reachable from it bound the range, so a first push by URL is not
refused for legacy history; with neither, every commit is judged. The CI commit-audit runs the
same rules over the push range. Machine-written messages comply at write
time: `[MERGE]` bodies and the allocator's `[REQ]` message go through the
rule scrub, while the requirement file keeps the verbatim text.

### Migrating the vendored copy - `.io.v4rian.how-git/bin/sync-framework <target-ref>`

Consumer repos (no `FRAMEWORK_REPO` marker) move their vendored
framework copy between source revisions with `bin/sync-framework`.
The tool resolves the framework source from `--source` or the SPEC
`source=` line, resolves the base from `--base-ref`, the SPEC `ref=`
line, or content matching against the source's tags and dev/main
tips, then applies the base to target diff three way with consumer
owned state (`MODE`, `SPEC`, `admins.txt`, `active-requirement`, `requirements/`,
`MERGE_POLICY`, `WARP`)
excluded. A SPEC `ref=` the source does not have is recovered through
SPEC `tag=` when that tag's vendored tree matches the copy. A clean apply
restamps SPEC and commits (hooks disabled, so the copy stays byte for
byte); a conflicted apply
leaves the markers, prints the resolution steps, and exits 1.
Downgrade is the same command with an older target ref. `--dry-run`
previews the plan; `--no-commit` leaves the result staged.

### Opening PRs - `bash .io.v4rian.how-git/scripts/open-pr.sh`

`scripts/open-pr.sh` opens (or updates) a PR from the current branch
following the v4rian model. It is **idempotent** - re-running it on the
same branch PATCHes the existing PR's title + body instead of creating
a duplicate.

Auto-derives:

| Field   | From                                                                  |
|---------|-----------------------------------------------------------------------|
| target  | `pool/*` → `dev`; `dev` → `main`                                      |
| version | `bin/version --next-dev` for pool→dev; `bin/version --release-tag` for dev→main (same code = same version, so release reuses dev tag) |
| title   | `[TAG] <version>: <subject of latest commit>` (pool→dev) or `[MERGE] dev into main: <release>` (dev→main) |
| body    | `git log --reverse origin/<base>..HEAD` (or `--body-file <path>` to override) |

Token resolution order (first wins): `$GH_TOKEN`,
`$CREATE_POOL_BRANCH_TOKEN`, `gh auth token` (if gh installed),
`~/.gcm/store/git/https/github.com/<account>.credential`. The
`--doctor` flag prints which deps + token sources are available and
exits without calling the API.

### Claiming a version - `bash .io.v4rian.how-git/scripts/claim-dev-merge.sh` / `claim-main-release.sh`

Under the v4rian model the version is **claimed by whichever PR merges
first**, not pre-allocated at branch creation. The claim is a git
operation, not a CI operation. Two scripts handle it.

Both scripts read every dev version derivation through `bin/version`
(the single authority for `vYEAR.SERIES.DEV`); neither computes the
math itself. `claim-dev-merge.sh` calls `bin/version --seal` for the
tag to land on the just-merged commit, and `claim-main-release.sh`
calls `bin/version --release-tag` for the release tag (which reuses
the latest dev tag because same code = same version). Adding or
changing version components is therefore a one-place edit in
`bin/version`; consumers never drift.

`claim-dev-merge.sh` amends the just-landed merge commit into spec
format (committer normalized to the CI identity, subject set to
`[MERGE] <source> into dev: vYEAR.SERIES.DEV`) and force-pushes the
rewritten commit over the GitHub merge commit before tagging it. dev
branch protection therefore permits force-push (set by
`apply-repo-rules.sh`); `main` does not, since releases never amend
`main`. The force-push is exercised only by this privileged claim flow
and the repo admin, never by developers, who hold no write access to
dev. The push runs on every claim attempt before the tag, so a retry
that finds the merge already amended still re-pushes dev rather than
tagging a commit that a rejected earlier push left off the dev line.

| When | Run this | What it does |
|---|---|---|
| After a `pool/*` PR merges into `dev` | `bash .io.v4rian.how-git/scripts/claim-dev-merge.sh` | derives the next `vYEAR.SERIES.DEV` from `bin/version --seal` (merge-count math; no VERSION file, no counter), mints a fresh tag on the just-merged dev HEAD (internal tag, no Release), pushes the tag and dev. The tag IS the seal - no VERSION file is touched |
| After `dev` merges into `main` | `bash .io.v4rian.how-git/scripts/claim-main-release.sh` | reuses the existing dev tag as the release (same code = same version, so no new tag and no counter commit), **optionally** creates a GitHub Release via API from that tag if a token is available, GCs `safety/` anchors whose paired `pool/` branch is reachable from `origin/dev`, pushes |

Both scripts refuse to claim a tag that already seals another commit (so
re-running after a partial failure is safe) and support `--dry-run`. What
a claim will and will not do to dev, the work tree, tags and hooks is in
[RUNBOOK, Claim safety](docs/RUNBOOK.md#claim-safety-what-the-claim-will-and-will-not-do).

Token resolution for the optional GitHub Release in `claim-main-release.sh`
matches `open-pr.sh`'s chain. If no token is reachable, the git tag is
still pushed and is canonical; only the GitHub Release sidecar is
skipped.

`claim-main-release.sh` also appends an `## Open work pool branches at release`
section to the amended merge commit body so every release log closes on an
honest roster of what was still in flight at the moment of the cut. See
the `docs/RUNBOOK.md` "Open work pool branches at release" sub-section
for the row shape, sort order, sourcing rules, and the empty-roster
placeholder.

### Building on every tag: `ci-dispatch.yml` tag trigger + `scripts/build.sh`

Every `v*` tag push runs `ci-dispatch.yml`'s tag trigger, whose
`ci/audits/tag/required.build.sh` check builds the tagged commit with
`.io.v4rian.how-git/scripts/build.sh`. `build-on-tag.yml` is the admin
rebuild entry over the same check (`gh workflow run build-on-tag.yml
-f tag=vX`), and `bin/ci-local --workflow build-on-tag` runs it off grid
on the checked out tag (or `TAG=vX`). The
script is the **single source of truth** for the build; consumer
projects override it in their fork with their actual recipe (npm run
build, cmake + ninja, xcodebuild, cargo, etc.) and the workflow stays
unchanged.

`build.sh` dispatches by project markers in the repo root:

| Marker present | Behaviour |
|---|---|
| `package.json` | `npm install --no-audit --no-fund` then `npm run build` if a build script exists, then best-effort tar of `dist/`, `build/`, `out/`, or `lib/` into the artifact dir |
| `CMakeLists.txt` | Prints a consumer-must-override banner and exits non-zero (Qt / C++ recipes vary too widely for a meaningful default) |
| Neither (template itself) | Emits a small text summary of the tag for the workflow to upload |

**Output contract:** every artifact lands under `./build/artifacts/`
at the repo root, with filenames embedding `$TAG`. The directory IS
the API between this workflow and the (later) distribution bundle that
attaches the same artifacts to a GitHub Release.

**Triggers:** `push: tags: ['v*']` on `ci-dispatch.yml` (primary,
event-driven) and `build-on-tag.yml`'s `workflow_dispatch` with a `tag`
input for admin manual re-builds of a specific historical tag.

**Retry + idempotency:** the workflow wraps `build.sh` in the same
exponential backoff retry as the audit workflow (eight attempts, five
second base, five minute cap, seventy two hour envelope). Before
building it asks `build.sh` (with `BUILD_IDEMPOTENCY_CHECK=1`) whether
output for the target tag is already present at the contract path; if
so, the build step is skipped and the workflow exits 0. Distribution
is deliberately out of scope here so the same artifact built at dev
tag time is reused unchanged when the release promotes to main.

### Protocol lint - `bash .io.v4rian.how-git/scripts/lint-protocol.sh`

A deterministic lint, no AI, keeps the protocol text honest. It fails on a `[[link]]` in a skill that is not an in-tree skill (or any memory note name), on a named `bin/`, `scripts/`, skill tool, workflow or `git-*` skill that does not exist, on retired phrases (`cat VERSION`, `[CLEANUP]`, a `Changes:` header, "straight to dev", `feature/` outside a legacy section; a line that negates them passes), on a fixed `/tmp` path in a skill, and on an allocator kind list that differs from `HG_BRANCH_KINDS` in `_lib.sh`. `--copy <path>` compares the canonical namespace with a copy (fractaris, a vendored tree) and prints a diff summary; per-repo files (MODE, SPEC, REQUIREMENTS.md) are skipped.

On the framework source (FRAMEWORK_REPO marker) the pre-commit hook runs it with `--staged` and blocks only findings on lines the commit adds; the sys-layer push step `ci/tests/push/required.protocol-lint.sh` runs it over the whole namespace. Changelog history and the original build spec are records and are not linted.

### Verifying the template - `bash .io.v4rian.how-git/scripts/verify-template.sh`

`scripts/verify-template.sh` exercises the template end-to-end on a
separate throwaway repo (never the template repo itself). Default mode
uses GitHub's `POST /repos/{template}/generate` API (the real "Use
this template" path), tests the deliverable on the source's default
branch. `--from-branch <ref>` simulates `/generate` from a non-default
branch - useful for pre-merge testing.

Static invariants always run: root layout, executable bits, auto-config
of `core.hooksPath` on first script call, `heal.sh` restores state
after drift, `test-hooks.sh` passes 62/62, both claim scripts are
present + executable.

Optional `--with-bump-cycle` flag adds five more invariants that run
the canonical `claim-dev-merge.sh` + `claim-main-release.sh` scripts
on the throwaway and verify the tags + Release + VERSION bumps land
correctly - no CI polling. Then deletes the throwaway (or `--keep`).

### Benchmarking the protocol - `bench/bin/bench`

`bench/` measures how efficiently an agent executes this protocol, so a
change to the skills, loader or tools can be compared against the
baseline after every pool. Six scripted tasks (`bench/tasks/`: atomic
commit, branch with three commits, pool close-up into dev, ship to
main, preflighted message rewrite, folder-snapshot rebuild) each build
a fresh off-grid consumer repo in `$TMPDIR` from the arm's framework
with a local bare origin, hand the agent a fixed prompt, and score the
result with deterministic checkers. An arm (`bench/arms/<name>.conf`)
is a framework ref plus a loader: `how-git` is commit 5028b58 with the
global loader as of 2026-10-29, `neo-git` is a moving ref loading the
in-repo lean loader (`.io.v4rian.how-git/skills/how-git/SKILL.md`). A
loader an arm names must resolve at its ref: the harness refuses the
arm instead of falling back to the baseline bundle (an empty `loader=`
means the bundle's own loader).

    bench/bin/bench --dry                       # fixtures + reference solutions through every checker, no model
    bench/bin/bench selftest                    # known-bad solutions must trip the named checks
    bench/bin/bench isolation                   # one cheap probe proving what a benchmark agent sees
    bench/bin/bench --tasks a --models haiku    # one real run per arm
    bench/bin/bench --models opus,fable --reps 3 --jobs 4
    bench/bin/bench diff RESULTS.jsonl --arms how-git,neo-git
    bench/bin/bench diff BEFORE.jsonl AFTER.jsonl
    bench/bin/bench loadbytes --out loadbytes.md  # zero-model read budget per decision-tree task

`loadbytes` needs no model: per task of the lean loader's decision
tree it counts the bytes each arm tells an agent to read. The old arm
is the global loader plus everything its On invoke steps mandate at
`--old-ref` (the git memories it names, every in-repo `git-*` skill,
`docs/Git_Strategy.md`, `docs/RUNBOOK.md`) plus the how-* skills and
memories its row adds; the new arm is the lean loader at `--new-ref`
plus the skills its row names and the `--help` output of the tools its
row names, run in a detached checkout. `framework-tests/test-bench.sh`
pins the loader refusal and the table offline.

Agent-runner mode measures without headless tokens: `bench export`
builds every arm x task run dir exactly as a run does (fixture repo,
arm framework, sandbox HOME with only that arm's loader and skills,
pre-state snapshot) and writes `RUN/AGENT_PROMPT.md`, the instruction
an external agent follows: stay inside the run dir, read the arm's
loader by absolute path instead of using a Skill tool, and prefix every
command with the printed `env -i ...` line so the arm's hooks, HOME and
backup dirs apply (nested hook audits are stubbed). `bench ingest` then
runs the same checkers as `bench check` and appends a `results.jsonl`
row (mode `external-agent`) next to `runs/`, priced at the model's list
price: exactly with the token split, otherwise every token at the input
price (`cost_basis` says which). A re-ingest replaces the run's row, and
`summary` and `diff` read the rows like measured ones.

    bench/bin/bench export --arms how-git,neo-git --tasks a,b,c,d,e,f --out DIR
    bench/bin/bench ingest DIR/runs/neo-git.agent.a-commit.r1 --tokens N --tool-uses N --duration-ms N --model opus

Runs are headless Claude Code (`claude -p --output-format
stream-json`). Each run gets its own HOME and CLAUDE_CONFIG_DIR holding
only the arm's loader bundle and a settings file (no attribution
trailer, Read/Edit/Write denied under the operator's home), so no
operator CLAUDE.md, memory, skill, plugin, MCP server or Claude Code
hook loads; auth comes from an existing credential
(`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `BENCH_TOKEN_FILE`, or
the ag.i long-lived token, read only) and the harness never logs in.
A `claude` shim on the sandbox PATH meters any AI audit the git hooks
spawn. Per run it records input, cache-read, cache-write and output
tokens, turns, tool calls, protocol files and bytes read, hook denials,
retries, nested hook AI cost, wall time and dollar cost at list price
(`bench/lib/benchcore/metrics.py` cites the source), into
`results.jsonl`, a `summary.md` table per arm x model x task, and a
`report.md` per run with the resulting `git log --graph` and messages
for a human reviewer. `--max-turns`, `--max-budget-usd` and `--timeout`
cap each run; tools a headless session cannot use (`ScheduleWakeup`,
cron, push notifications) are denied by default (`--disallow`).

Readability is a deterministic 0 to 100 score per authored commit:
title 25 (subject 15 to 72 chars, no trailing period), tag 25 (approved
set), mood 10 (capitalised, not past tense or gerund; merges: claimed
spec title), body 20 (a description whose lines end in a period),
topic 20 (at most 2 top-level dirs and 6 files; merges: a nested list
whose lines end in a period). Framework ceremony commits (`[REQ]`,
`[MODE]`) are excluded.

### Silence is success

Every script under `.io.v4rian.how-git/scripts/` and every CLI under
`.io.v4rian.how-git/bin/` follows the sh-land convention: a script
that exits 0 and prints nothing has succeeded. A script that exits
non-zero must always print something (banner, error line, or the
EXIT-trap diagnostic) so an operator can interpret silence as "it
worked." The three-part pattern at script entry that enforces this
is (1) an announce-upfront echo on the first line after
`set -euo pipefail` carrying the script name and the origin slug so
even the earliest silent fall-through still leaves the start-line on
screen; (2) an EXIT trap that prints the script name, the non-zero
exit status, and the last command (`$BASH_COMMAND`) on any failure
exit and stays silent on success; (3) a heartbeat line emitted
before each long preflight step so a silent stall inside a step is
bounded by the heartbeat above it. Helpers in `scripts/_lib.sh`
(`get_org_plan_name`, `repo_supports_rulesets`)
surface their `gh` stderr through the `run_capture_stderr` helper so
the caller's `precondition_banner` carries the actual API error
(missing scope, 404, rate limit) rather than a generic miss. If you
run an admin script and see nothing printed, that means it succeeded.
If a script exits non-zero without printing anything, that is a bug
in the script, not a re-run-it situation; please file an issue.

### Commit identity and time come from the source

`bin/identity` maps the origin's GitHub org to the commit identity:
`v4rian-io` and `v4rian-waylon` commit as `v4rian-waylon (<Model>)`
<v4rian-waylon@users.noreply.github.com> (the model from
`HOW_GIT_MODEL`), `sessionpass` as `waylon-sp`. The map is
`identity-map` in the namespace; `identity-map.local` (consumer-owned)
and `HOW_GIT_IDENTITY_MAP` override it, and `git config how-git.org
<org>` pins the org for a remote that has none (off-grid). Every script
sourcing `scripts/_lib.sh` exports that identity unless the caller
already exported one; `eval "$(.io.v4rian.how-git/bin/identity
--export)"` does the same by hand. In a mapped repo `commit-msg` and
`pre-push` refuse an author or committer whose email is not the mapped
one or whose name is not the map's (`v4rian-waylon (<Model>)` takes any
model or none; `waylon-sp` is exact). In a real GitHub Actions run
(`GITHUB_ACTIONS=true` with a `GITHUB_RUN_ID`) `_lib.sh` keeps the
workflow's configured bot identity (`git config user.*`) and the hooks
accept it, so ceremony commits stay bot-authored. Joel's own identity passes only for rebuilds of his snapshots,
under `HOW_GIT_SNAPSHOT_REBUILD=1` or `git config how-git.snapshotRebuild
true`. A rewrite keeps the original author name, email and date and only
the committer carries the rewriting model: `pre-push` treats a pushed
commit sharing a patch-id with a remote commit the push leaves behind
as a rewrite and refuses it when the author changed; the remote's
`preflight-bak-*` branches are backup copies and never count as left
behind history (pre-push accepts a backup push named exactly
`preflight-bak-YYYY-MM-DD/NN` and skips the message rules for it) (an amend that keeps
a foreign author sets `HOW_GIT_PRESERVE_AUTHOR=1`, as the claim amends
do). Dates keep the source's real offset (`bin/identity --source-date
<path>` gives the mtime with the offset real at that instant, in
`GIT_AUTHOR_DATE` form); ref, repo and zip name stamps are UTC with a
trailing Z (`bin/identity --utc-stamp`).

### Every tool explains itself: `--help`

Run `<tool> --help` (or `-h`) before reading RUNBOOK or Git_Strategy.
Every `bin/*` and every `ci/audits/**/required.*.sh` prints its
agent-facing reference: purpose, usage, flags, preconditions, what it
refuses and why, and its exit codes. The push gates carry their recipes:
`required.compile.sh --help` and `required.runtime.sh --help` give the
per-repo-type compile and boot recipes (Node, Qt lib, Qt app, CLI,
service) and the init-marker and tolerable-error rules. `--help` needs
no argument, works before any repo or mode check, and changes nothing;
the `every bin and required script answers --help cleanly` lifecycle
test runs both flags on every tool in a scratch repo and fails on a
non-zero exit, a missing usage or exit-code section, or any change to
the tree, refs, config or the gh mock state.

### Merge messages: one shape, gated deterministically

Every merge commit (pool into dev, dev into main) and the PR body that
becomes it share one shape (`skills/git-merge-audit`, rule 5): the title
`[MERGE] <source> into <target>: <version>`, a blank line, a 1-3 sentence
macro paragraph, a blank line, then a nested list of `- <Topic>.` lines
each holding `    - <label>: <one-line summary>.` leaves, every list line
ending with a period. `scripts/check-merge-message.sh` checks it
(`--file`, `--commit`, `--body-file`, `--title`; `--pr-ref` admits the
claim's leading `PR #N <url>` paragraph) and runs in four places:
`commit-msg` (every `[MERGE]` subject and every merge created on dev or
main), `pre-push` (every first-parent merge pushed to dev or main and
every `[MERGE]` merge elsewhere), both claims (before the amend; nothing
is amended, pushed or tagged on failure) and `validate-pr-open.sh` (the
PR body; a failure turns `opened-via-correct-flow` red).
`scripts/check-merge-parity.sh <merge> --pr <N>` (or `--pr-body-file`)
proves the merge body minus that reference paragraph equals the PR
body; the claims run it after amending from a PR body.
`scripts/seed-release-body.sh` seeds the release body in this shape from
the pool merges in `main..dev` for `bin/init-release` and `bin/ship` (whose release merge takes dev tip's committer date), and `.github/PULL_REQUEST_TEMPLATE.md` is the
same skeleton. `bin/reject-pr <N> --reason "..."` closes a PR with a
structured `## REJECTION` comment while its branch stays on origin
(`--mention`, `--block-merge`, `--dry-run`).

### Framework tests run in parallel

`framework-tests/test-lifecycle.sh` and `test-hooks.sh` are safe to run
concurrently on one machine (parallel agents, audits, worktrees). Each
lifecycle run owns one `mktemp -d` root (`SCRATCH_BASE`), exports
`TMPDIR` into it so every script under test writes its temp files
there, and removes it on exit; the gh mock joins that root instead of
replacing the runner's EXIT trap. Framework scripts never write a fixed
`/tmp` name: temp files come from `mktemp` (honouring `TMPDIR`) and are
removed after use, and the `framework carries no fixed /tmp paths
(B10)` test enforces it. `run_test` prints logs byte-safely (NUL bytes
dropped, C locale), so a corrupted log can never abort the runner.

Both suites run under `set -o pipefail`, so tests feed grep from a here
string (`grep -q PATTERN <<<"$out"`), never `echo "$out" | grep -q`:
when grep exits early the echo takes SIGPIPE and the test flakes. A lint
case in `test-hooks.sh` enforces it.
The same holds for process checks: capture `ps` into a variable first.

Every lifecycle test is isolated and deterministic regardless of order or
host load. `run_test` runs each test in a subshell with no stdin, from
its own dir under the run root (`SCRATCH_BASE`, `TMPDIR` and
`V4RIAN_TEST_RUN_ROOT` point there), so no `cd`, export, PATH prepend or
trap reaches the next test, and removes that dir as soon as the test
passes: a full run's disk peak is one test, not the 2.2 GB of every
scratch repo at once that used to hit ENOSPC on a nearly full disk. A
set `TMPDIR` is honoured for the run root (BSD `mktemp -t` ignores it).
`--keep-logs` keeps the run root with every log, the dirs of failed
tests and each test's duration, for diagnosing a failure that only a
full run shows.

### Pushing a pool: `bin/push-pool`

`bin/push-pool [--remote NAME | --url URL] [--expect SHA] <pool>` pushes
a pool and its safety anchor in one atomic push. A push through a
one-off token URL updates no tracking ref, so a plain
`--force-with-lease` bounces with "stale info"; push-pool leases on the
destination's advertised sha instead, only when this clone has seen that
commit, and refuses a remote that moved to a commit it never had
(`--expect` pins the lease). The safety anchor is never rewritten.

### Claiming while dev is checked out elsewhere

`bin/finalize-pool-merge` (and `claim-dev-merge.sh`) also accept a
detached HEAD on a merge that descends from local dev, so a linked
worktree can merge and claim while another worktree has dev checked
out: `git worktree add --detach ../merge-wt dev`, merge there, finalize.
After the claim the worktree holding dev is fast-forwarded when clean
(or the dev ref moved when no worktree holds it); otherwise the exact
`git -C <wt> merge --ff-only <sha>` line is printed.

### The post-checkout audit is opt-in

On the framework repo (`FRAMEWORK_REPO` marker) the post-checkout hook
can run the git-snapshot-preflight skill through `claude -p`. It is off
by default: enable it per clone with `git config howgit.checkoutAudit
true` (or `HOW_GIT_CHECKOUT_AUDIT=1`). It never runs on clone or
`git worktree add`, and runs at most once per branch per
`howgit.checkoutAuditInterval` seconds (default 3600). Only an explicit
`AUDIT_PASS` line counts as a pass; a login prompt or any other answer
is reported as SKIPPED with its first line.

### Housekeeping: `bin/sync-pools` and `bin/gc-safety`

`bin/sync-pools` rebases every local pool branch that has no
`origin/<branch>` and lacks dev onto dev (`--onto <ref>` to choose,
`--dry-run` to list). It snapshots each tip first as a local
`safety/<branch>-<YYYYMMDD-HHMMSS>` ref and stops on the first conflict
with the exact continue, abort and restore commands. A pool stacked on
another unpushed pool moves with it in one `git rebase --update-refs`, so
the stack keeps one copy of each commit; only candidate pool refs are
updated, never the snapshots. Pushed pools stay with the auto-rebase pass.

`bin/gc-safety` collects released Pattern-2 snapshots
(`safety/<branch>-<timestamp>` whose tip is merged into dev and whose
pool is vaulted). It is a dry run by default; `--apply` writes them to
`~/.Trash/git-branch-trash/<repo>-<date>.bundle`, verifies the bundle
holds every ref at its SHA, and only then deletes the local refs. It
prints the `git fetch <bundle>` line that restores them. Pattern-1
allocator anchors (`safety/[vYYYY.X/]nN.kind.slug`) stay forever.

### Agent hooks: `bin/install-agent-hooks`

Git hooks run when git does; an agent can destroy work before that
(`git reset --hard`, `rm`, a force push, an edit to a vendored copy).
`agent-hooks/` ships the agent-side guards the protocol relies on, and
`bin/install-agent-hooks` installs them into a person's agent setup:

- `shared/guard-destructive.sh` (PreToolUse on shell commands): destructive
  git (reset --hard, checkout -f, clean -f, branch -D, rebase,
  filter-branch, stash drop/clear, reflog expire, gc --prune, update-ref -d,
  force push) needs a fresh preflight, or `git-preflight.sh <repo> ... &&`
  chained in front; throwaway repos under a temp root are exempt. It also
  denies a push to main, a bare `--force`, `git add -A`/`.`, staging
  secrets or build output, a `Co-Authored-By: Claude` trailer, `gh repo
  delete`, `rm` outside temp roots and printing credential files.
- `shared/git-preflight.sh <repo> [reason]`: a `preflight-bak-<day>/NN` ref
  of the whole working tree (secrets excluded at any depth, pushed to
  origin when there is one) plus a `<repo>-bak-<UTC>Z.zip`; reuses a fresh
  identical snapshot, keeps the newest `PREFLIGHT_KEEP` (5) zips and moves
  older ones to the Trash, honours an exported `GIT_AUTHOR_*` identity.
- `shared/guard-write.sh` (PreToolUse on edits): no write under a vendored
  `.io.v4rian.how-git/` copy; the framework source (FRAMEWORK_REPO marker)
  is exempt.
- `shared/identity-env.sh` (PreToolUse on shell commands): a git write
  (commit, merge, annotated tag, cherry-pick, rebase, commit-tree, revert,
  am, pull) in a repo whose origin org is in the identity map is rewritten
  through `updatedInput` to start with `export GIT_AUTHOR_*=..
  GIT_COMMITTER_*=..;` from `bin/identity` (the repo's vendored copy, else
  the `identity.sh` and `identity-map` installed beside the hook), the
  `<Model>` slot from `HOW_GIT_MODEL`, `ANTHROPIC_MODEL` or the hook
  input's `model`. Every identity field the command or environment already
  sets is kept; the snapshot-rebuild switch, a real CI run, unmapped repos
  and commands that mix a mapped and an unmapped repo are left alone.
  Claude Code returns `allow` only in `bypassPermissions` mode and `ask`
  (the user sees the rewritten command) otherwise, so no permission is
  widened; `HOW_GIT_IDENTITY_DECISION=allow|ask` overrides. Codex rewrites
  only through `allow` + `updatedInput`, reached via `codex-adapter.sh
  identity`. The `commit-msg` and `pre-push` gates still refuse a wrong
  identity whatever the agent does.

Config is environment, with defaults: `HOW_GIT_BAKS_DIR`
(`$HOME/.how-git/baks`), `HOW_GIT_BAKS_MIRROR` (off),
`HOW_GIT_TRASH_DIR` (`/usr/bin/trash`, else `~/.Trash`),
`PREFLIGHT_MAX_AGE_H` (12), `PREFLIGHT_KEEP` (5). Machine policy (sudo,
package installs, a cloud CLI) is not protocol and is left to the
person's own hooks; both run, and any deny wins.

```bash
.io.v4rian.how-git/bin/install-agent-hooks --dry-run      # plan for both agents
.io.v4rian.how-git/bin/install-agent-hooks --claude       # ~/.claude/hooks/how-git + settings.json
.io.v4rian.how-git/bin/install-agent-hooks --codex        # ~/.codex/hooks/how-git + hooks.json + rules + AGENTS.md
.io.v4rian.how-git/bin/install-agent-hooks --uninstall    # reverse exactly
```

The installer merges entries into `settings.json` / `hooks.json` (the
user's other hooks stay, the file is backed up to
`<file>.how-git-bak-<UTC>` before the first write), is silent and
writes nothing on a re-run, replaces handlers of an older install, and
`--uninstall` removes what it added (recorded in
`hooks/how-git/.install.json`), restoring the original bytes when
nothing else changed. `--prefix DIR` installs under a fake home for
tests; without it `$CLAUDE_CONFIG_DIR` and `$CODEX_HOME` are honoured.

What is enforced versus advisory:

| Agent | Enforced | Advisory |
|---|---|---|
| Claude Code | PreToolUse `Bash` and `Write\|Edit\|NotebookEdit` deny the call; `identity-env.sh` rewrites git writes to the mapped identity | none |
| Codex CLI | PreToolUse `^Bash$` and `^(apply_patch\|Edit\|Write)$` through `codex-adapter.sh` (`bash`, `identity`, `patch`), once the hooks are trusted in `/hooks` (Codex runs non-managed hooks only after review); `rules/how-git.rules` forbids a bare force push and `gh repo delete` at once | `AGENTS.md` block; Codex calls itself the hooks "a useful guardrail, not a complete enforcement boundary", and specialised tool paths can skip them |

`framework-tests/test-agent-hooks.sh` proves the guards on scratch repos
and the installer against a fake HOME (both agents, idempotency,
uninstall); `offline-test.sh` runs it with the other suites.

### Linked worktrees and bash 3.2

Every script resolves the repo root from the caller's work tree with
the hook-exported `GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE`
cleared, and `post-merge` hands the claim a plain environment, so a
merge inside `git worktree add` claims like one in the main checkout.
Array expansions use `${a[@]+"${a[@]}"}` (or `${a[*]:-}` in messages)
so an empty array never aborts stock macOS bash 3.2 under `set -u`; the
`no unguarded array expansions under set -u` test fails on any new one.

---

## Reading order for adopters

1. **[`docs/Git_Strategy.md`](docs/Git_Strategy.md)** - the model, the
   invariants, the rationale. Internalize this before changing anything.
2. **[`docs/IMPLEMENTATION_HANDOFF.md`](docs/IMPLEMENTATION_HANDOFF.md)** -
   if you're standing up the infrastructure (hooks, allocator,
   branch protection), the milestone breakdown lives here.
3. **[`docs/repo-config.md`](docs/repo-config.md)** - the server-side
   gates (branch protection, Repository Rules) that make the model
   enforceable rather than aspirational.

---

## What's complete in this skeleton vs. what you'll build

| Component | Status |
|---|---|
| Local hooks (`pre-commit`, `prepare-commit-msg`, `commit-msg`, `pre-push`, `post-checkout`, `post-merge`) | ✅ Ready to use; auto-activate on first script run |
| Layered CI dispatcher (`ci-dispatch.yml` → one check per `ci/{tests,audits}/<trigger>/*.sh` script; sys-layer `required.commit-audit`, `required.compile`, `required.coverage`, `required.runtime`, `required.offline-test-suites` required on PRs to dev) | ✅ Ready to use; deterministic structural enforcement on every PR to dev, plus a per-commit claude judgment layer on `required.commit-audit` that catches tag fit, fabricated symbol names, non atomic mixing, and body-versus-diff contradiction (see `docs/RUNBOOK.md` for the credential-fallback semantics) |
| Hook tests | ✅ Ready to use (`bash .io.v4rian.how-git/framework-tests/test-hooks.sh`) |
| Version claim scripts (`claim-dev-merge.sh`, `claim-main-release.sh`) | ✅ Ready to use |
| PR open / update script (`open-pr.sh`) | ✅ Ready to use |
| PR-open validate workflow (`validate-pr-open.yml` → `opened-via-correct-flow` required check) | ✅ Ready to use; amends the title, gates the body shape, posts the status check |
| Init CLIs (`init-pool-merge`, `init-release`) | ✅ Ready to use; dispatch `gh pr create` with the right base and a merge-shape body |
| End-to-end template verification (`verify-template.sh`) | ✅ Ready to use |
| Heal script (`heal.sh`) | ✅ Ready to use |
| `create-pool-branch` CLI + allocator workflow | ✅ Ready to use; admin GitHub Actions allocator pairs pool/* and safety/* atomically |
| `bootstrap-ci` one-shot repo setup (Actions, dev seed, branch protection, Repository Rules, required status checks, merge-commit defaults, merge-mode lock, auto-delete disable, topics) | ✅ Ready to use; idempotent; `--check` audits, `--dry-run` prints API calls |
| Branch-creator service (legacy spec) | 📋 Superseded by the in-repo allocator workflow; the spec is retained for historical reference |
| Repository Rules / branch protection script | 📋 Template - needs your repo names |
| JIRA → endpoint integration | ❌ Out of scope (separate work) |

---

## License

MIT - see [`LICENSE`](LICENSE).

---

## Credit

The "v4rian way" is named for the brittle reality that **a single point
of failure is one merge away** without disciplined anchoring, version
claiming, and server-side enforcement. This template encodes one
opinionated answer to that problem. It is not the only answer; it is
the answer that fits the design constraints documented in
`Git_Strategy.md`.
