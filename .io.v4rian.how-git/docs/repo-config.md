# Repository Configuration

Server-side enforcement of the v4rian git strategy. Without these
rules, the local hooks are bypassable and the model is aspirational.
With them, the model is reality.

This document is forge-agnostic in spirit but uses GitHub terminology
because that's the assumed default. Translate to GitLab / Bitbucket /
Gitea as needed - the *intent* of each rule is what matters.

---

## Required rules

### `main` branch protection

- ✅ Require a pull request before merging
- ✅ Require status checks to pass: `release`, `doc-freshness`
- ✅ Require approvals: **≥1 review**
- ✅ Dismiss stale approvals when new commits are pushed
- ✅ Restrict who can push to matching branches: **bot identity only**
  (for the version-bump commit)
- ❌ No force-pushes
- ❌ No deletions

### `dev` branch protection

- ✅ Require a pull request before merging
- ✅ Require status checks to pass: `required.commit-audit`,
  `required.compile`, `required.coverage`, `required.runtime`,
  `required.offline-test-suites`, `reconcile`
- ✅ Restrict who can push: **bot identity only** (for version-bump commits)
- ❌ No force-pushes
- ❌ No deletions

### `pool/*` pattern (Repository Rule: Restrict creations)

- ✅ Restrict who can create branches matching `pool/*`: **branch-creator
  App identity only**
- Rationale: enforces the atomic-pair invariant - only the allocator can
  create working branches, and the allocator always creates the safety
  pair too

### `safety/*` pattern (Repository Rules: Restrict creations / updates / deletions)

- ✅ Restrict creations to **branch-creator App identity only**
- ✅ Restrict updates (pushes): **no one** - safety branches are
  read-only after creation
- ✅ Restrict deletions: **no one** - safety branches are permanently
  locked and persist for the life of the repo (`safety-lockdown`
  freezes creation, update, and deletion)
- Rationale: enforces I3 (safety branches are never modified) and the
  stay-forever rule - the release-claim enumerates no safety branches,
  so no identity ever deletes a safety ref

---

## Applying the rules

### Option A - GitHub UI

Settings → Branches → Add classic branch protection rule (for `main` /
`dev`), then Settings → Rules → Rulesets for the `pool/*` and `safety/*`
patterns. Tedious; recommended only for one-off bootstrap.

### Option B - `gh` CLI

Use `scripts/apply-repo-rules.sh`. The script is self-contained and
idempotent: it derives `ORG`/`REPO` from `git config --get
remote.origin.url`, auto-installs missing CLI deps (`gh`, `python3`)
on macOS via Homebrew, and surfaces install hints to the operator on
Linux. No placeholder edits are required for the common case. Override
`ORG` or `REPO` via same-named env vars only when targeting a
non-default repo.

The ruleset templates are shaped so the plain CI token never needs a
bypass (the carve out): `pool-creations` locks pool ref creation to
the allocator flow but excludes the `pool/*.reconcile.*` name shape,
so the CI claim publishes rebase candidates; `pool-deletions` locks
every pool ref deletion to admins (developers and CI never delete -
the vault receipt is the archive and merged pool refs linger until an
admin sweep); `vault-readonly` leaves creation open so the CI claim
vaults merged pools, with update and deletion frozen the instant a
vault ref exists; `safety-lockdown` stays fully locked. A push trigger
audit (`vault-provenance`) flags any carve out ref created by a non CI
actor. Every template names a single bypass actor class: the
`RepositoryRole` admin escape hatch; the script appends
`OrganizationAdmin` where a bypass list lacks one.
No machine identity appears in the bypass list - GitHub rejects the
Actions Integration from non workflow ruleset sources and deploy keys
may be disabled at the org level, so the framework provisions neither.
Reconcile candidates need no bypass either: the auto-rebase rolls the
canonical `pool/*.reconcile.*` name forward by FORCE-PUSHING it in
place (a non-fast-forward update), which the plain workflow token may
do - `pool-creations` carves reconcile out so the first cut lands,
`pool-deletions` only fires on a delete (never on an update), and the
no-force rule binds only the developer's own pool branch, never the
machine-owned candidate. No delete, so CI never deletes a pool ref.
The transitions that DO need a bypass are vault renames and pool
deletions at archive; in CI the claim does only what the workflow
token can (amend, tag) and hands those to `bin/post-merge-lifecycle`,
run LOCALLY under the admin operator's own gh session, on the run
summary. The CI bot App fully
automates them in CI: create the App once on the org (Contents: read
and write, installed on the repo), then `bin/bootstrap-ci --ci-app-pem
<downloaded .pem>` enrolls it set once - the `CI_BOT_APP_PRIVATE_KEY`
secret and the `CI_BOT_APP_ID` variable are written from the operator
shell, the pem never transits a workflow input, and both ruleset
appliers inject the installed App's Integration bypass actor
automatically from a truth-from-state probe. With the App enrolled the
claim's archive and vault pushes ride its installation token and the
local tool is never needed.

### Option C - Terraform

The [`integrations/github`](https://registry.terraform.io/providers/integrations/github/latest/docs)
provider has `github_branch_protection`, `github_repository_ruleset`,
and related resources. If your org already manages repos in Terraform,
add the resources there. Sample:

```hcl
resource "github_branch_protection" "main" {
  repository_id = github_repository.this.node_id
  pattern       = "main"

  required_status_checks { strict = true; contexts = ["release", "doc-freshness"] }
  required_pull_request_reviews { required_approving_review_count = 1 }
  enforce_admins = true
  allows_force_pushes = false
  allows_deletions    = false
}

resource "github_repository_ruleset" "dev_pattern_restrict_creations" {
  name = "dev-pattern-restrict-creations"
  repository = github_repository.this.name
  target = "branch"
  enforcement = "active"
  conditions {
    ref_name {
      include = ["refs/heads/pool/*"]
    }
  }
  rules {
    creation = true  # restricts creations
  }
  # bypass actors: branch-creator app
}
```

(Adapt to your provider version - Terraform's GitHub provider has
evolved its rulesets support; check current syntax.)

---

## Identities required

| Identity | Purpose | Permissions |
|---|---|---|
| `branch-creator` (GitHub App) | Creates `pool/*` + `safety/*` branches via the synchronous endpoint | `contents:write` |
| `ci-bot` (GitHub Actions default `GITHUB_TOKEN`) | Pushes version-bump commits and tags; creates Releases (never deletes safety branches - they stay locked for the life of the repo) | `contents:write`, `releases:write` |

Keep these as **separate** identities so the audit log distinguishes
allocator activity from release activity.

---

## Verification checklist

Before declaring the rules live, verify each of the following with
*a non-admin developer account*:

- [ ] Cannot create a new `pool/n99.feature.foo` branch via `git push`
- [ ] Cannot create a new `safety/n99.…` branch via `git push`
- [ ] Cannot push commits to an existing `safety/…` branch
- [ ] Cannot delete a `safety/…` branch
- [ ] Cannot force-push to `dev` or `main`
- [ ] Cannot bypass PR review on `main`
- [ ] The branch-creator App **can** create matching branches
- [ ] **No one** (including the ci-bot) can delete a `safety/…` branch - safety stays locked for the life of the repo
- [ ] The ci-bot **can** push the version-bump commit to `dev` / `main`

If any of the negative cases (the "cannot"s) actually succeed, fix the
rule before going live. Local hooks are not a substitute.
