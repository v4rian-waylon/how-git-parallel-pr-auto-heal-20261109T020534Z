# Implementation Handoff - Git Strategy

> ⚠️ **HISTORICAL / SUPERSEDED - DO NOT IMPLEMENT FROM THIS DOC.**
> This handoff describes an earlier model that no longer exists: a committed
> `VERSION` counter file (with `dev_counter` / `main_counter`) and
> `dev-merge.yml` / `main-merge.yml` workflows. None of that ships today.
> **The current model is tags-as-seal:** there is NO live `VERSION` file;
> `SERIES` and `DEV` are derived on demand from git merge records by
> `bin/version` (main first-parent merge count → `SERIES`; per-cycle
> dev-merge count → `DEV`). For the authoritative model read
> **`docs/Git_Strategy.md` (Versioning section)** and **`bin/version`**.
> `REQUIREMENTS.md` HG-S02 also flags this doc as historical. Retained for
> provenance only.

**Source of truth:** `Git_Strategy.md` in this directory. Read it before
writing any code; this handoff assumes you've internalized the
invariants there. This file covers *how* to implement, not *why*.

---

## Audience

Claude Code (or any agent / engineer) tasked with turning the strategy
into running infrastructure. This doc:

- Breaks the work into five independent milestones
- Lists acceptance criteria for each
- Provides ready-to-use scripts for small pieces and specs for larger ones
- Surfaces decisions that have already been made (do not re-litigate)
- Lists implementation choices that are open (please ask the user)

---

## Decision Log (settled - do not re-debate)

| # | Decision | Rationale |
|---|---|---|
| 1 | Branch format `(dev\|safety)/nN.kind.[sprintX-][JIRA-]name` | Locked after several rounds |
| 2 | Version format `v{YYYY}.{SERIES}.{DEV}` | Three-segment derived from git merge counts |
| 3 | `SERIES` is the count of main merges this year (auto-derived, never manually bumped); `DEV` is the count of dev merges in the current cycle (since last main merge); release REUSES the dev tag (same code, same version) | Set in the Component sources table |
| 4 | Calendar prefix (`YYYY`) is derived from clock at compute time, never stored | Eliminates calendar-vs-merge race |
| 5 | Atomic version claim on PR merge; not on branch creation | The whole reason the model exists |
| 6 | Dev merges tag the commit; only main merges promote to public Releases | Internal versions visible, not advertised |
| 7 | Safety branch created **with** the dev branch (atomically), as immutable anchor | Not a pre-merge snapshot; it's the work's birth certificate |
| 8 | Safety branches deleted on the next main merge that releases the paired work | Lifecycle tied to release event, not time |
| 9 | Abandoned safety branches preserved indefinitely | R&D dead-ends are valuable reference material |
| 10 | Branch-creation endpoint is **synchronous** - caller blocks for success/error | Async failure mode is unrecoverable for the user |
| 11 | Endpoint is owned by the repo; JIRA is one caller among many | Portability across trackers |
| 12 | Local hooks are guardrails only; server-side rules are enforcement | Local hooks bypassable with `--no-verify` |
| 13 | Hotfixes go through the standard `dev → main` pipeline | No bypass; speed comes from PR-review urgency |

---

## Invariants (must hold at all times)

These are testable properties of the running system. Violating any is a
bug, regardless of how reasonable the code looks.

- **I1** - Every remote branch under `pool/*` or `safety/*` matches the
  branch-name regex (Milestone 1).
- **I2** - Every `pool/X` branch on the remote has a paired `safety/X`
  branch at creation time, pointing at the same commit.
- **I3** - A safety branch is never modified after creation (no commits,
  no PRs target it, no force-push).
- **I4** - Every merge commit on `dev` or `main` is annotated-tagged
  before the version bump commit lands.
- **I5** - Every `main`-merge tag has a corresponding GitHub Release.
  No `dev`-merge tag has a GitHub Release.
- **I6** - Version monotonicity: tags sort in chronological order under
  SemVer comparison. (Calendar prefix guarantees this across months;
  counters guarantee it within months.)
- **I7** - The endpoint either creates both `pool/X` and `safety/X` or
  creates neither. No partial pairs.

---

## Stack Defaults

Assume unless the user says otherwise:

- **Forge:** GitHub
- **CI:** GitHub Actions
- **Shell:** Bash (POSIX-compatible where reasonable)
- **Endpoint language:** Pick what's simplest for the chosen deployment
  (see Milestone 2 - Open Choices)
- **VERSION storage:** A `VERSION` file at repo root, plain text, single
  line containing the current *active* (not last-claimed) version. CI
  reads and updates it.

If any of these don't match the user's environment, **ask before
diverging**.

---

## Milestones (dependency-ordered)

### Milestone 1 - Local hooks + bootstrap

**Scope:** smallest piece, no infrastructure, validates the format we
designed.

**Deliverables:**

- `.githooks/pre-push`
- `.githooks/post-checkout`
- `.githooks/commit-msg`
- `Makefile` (or `bootstrap.sh`) with a `setup` target
- `.githooks/README.md` (1 paragraph, dev-facing)
- `test/test-hooks.sh` exercising accept/reject cases

**Ready-to-use scripts** - these are tested in concept; ship them as-is
unless you find a real defect.

`.githooks/pre-push`:

```bash
#!/usr/bin/env bash
set -euo pipefail

branch=$(git rev-parse --abbrev-ref HEAD)

# Protected branches push freely (CI handles them)
[[ "$branch" =~ ^(main|dev)$ ]] && exit 0

pattern='^(pool|safety)/n[0-9]+\.(feature|fix|r&d|refactor|reconcile|doc)\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9-]*$'

if [[ ! "$branch" =~ $pattern ]]; then
  cat >&2 <<EOF
✗ Refusing to push: branch name '$branch' is invalid.

  Required:  (pool|safety)/nN.(feature|fix|r&d|refactor|reconcile|doc).[sprintX-][JIRA-]short_name
  Examples:  pool/n3.feature.parser-rewrite
             pool/n3.feature.sprint4-parser_rewrite
             pool/n7.fix.PROJ-123-token_leak
             pool/n12.r&d.sprint5-PROJ-456-embedding_cache

  Rename:    git branch -m <new-name>

  Note: developers cannot push new branches matching pool/* or safety/* to
  the remote - those are server-allocated. Local branches with the right
  format are fine for spikes but won't be accepted by the remote.
EOF
  exit 1
fi
```

`.githooks/post-checkout`:

```bash
#!/usr/bin/env bash
prev=$1; new=$2; is_branch_checkout=$3
[[ "$is_branch_checkout" == "1" ]] || exit 0

branch=$(git rev-parse --abbrev-ref HEAD)
[[ "$branch" =~ ^(main|dev)$ ]] && exit 0

pattern='^(pool|safety)/n[0-9]+\.(feature|fix|r&d|refactor|reconcile|doc)\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9-]*$'

if [[ ! "$branch" =~ $pattern ]]; then
  echo "⚠  Branch '$branch' doesn't match the required pattern."
  echo "   Expected: (pool|safety)/nN.(feature|fix|r&d|refactor|reconcile|doc).[sprintX-][JIRA-]short_name"
  echo "   This is OK for local spikes; the remote will reject it on push."
fi
```

`.githooks/commit-msg`:

```bash
#!/usr/bin/env bash
msg_file=$1
subj=$(head -n1 "$msg_file")
len=${#subj}
if (( len < 8 || len > 100 )); then
  echo "✗ Commit subject must be 8-100 chars (got $len)"
  exit 1
fi
```

`Makefile` target:

```makefile
.PHONY: setup
setup:
	@git config core.hooksPath .githooks
	@chmod +x .githooks/*
	@echo "✓ hooks installed (core.hooksPath = .githooks)"
```

**Acceptance criteria:**

Reject these (exit 1 on push):
- `feature/foo`, `pool/foo`, `pool/n3.feature`, `pool/n3.unknown.foo`
- `pool/N3.feature.foo` (uppercase N)
- `pool/n3.feature.Foo` (uppercase in short-name)
- `safety/n3.feature.foo` *if pushed by a developer identity* -
  reject is via server-side rules, not pre-push, but include the case
  in tests for completeness

Accept these:
- `pool/n3.feature.parser-rewrite`
- `pool/n3.feature.sprint4-parser_rewrite`
- `pool/n7.fix.PROJ-123-token_leak`
- `pool/n12.r&d.sprint5-PROJ-456-embedding_cache`
- `pool/n4.refactor.config-module`

Always accept (protected): `main`, `dev`

**Tests:** `test/test-hooks.sh` should create a tmp git repo, install
the hooks via the Makefile target, and exercise each case above with a
clear PASS/FAIL summary.

---

### Milestone 2 - Branch-creation endpoint

**Scope:** the load-bearing piece. Everything else assumes this exists
and works.

**Contract:**

- **Input** (JSON over HTTP, or equivalent for chosen transport):
  ```json
  {
    "kind": "feature|fix|r&d|refactor|reconcile|doc",
    "short_name": "lowercase_slug_with_underscores_or_hyphens",
    "sprint": 4,                      // optional, integer
    "jira": "PROJ-123"                // optional, "[A-Z]+-[0-9]+" format
  }
  ```
- **Output on success** (HTTP 200):
  ```json
  {
    "branch": "pool/n14.feature.sprint4-PROJ-123-parser_rewrite",
    "safety": "safety/n14.feature.sprint4-PROJ-123-parser_rewrite",
    "commit": "abc123…"
  }
  ```
- **Output on failure** (HTTP 4xx/5xx):
  ```json
  {
    "error": "validation|conflict|allocation_failed|partial_pair_rollback|…",
    "message": "human-readable detail"
  }
  ```

**Operations** (in order):

1. Validate input against the same regex pieces as the pre-push hook
2. Atomically allocate the next `nN`:
   - Query existing remote refs for `pool/n*` and `safety/n*`
   - Find the highest `n` across both scopes (they share the counter
     because safety pairs with dev - see I2)
   - Hold a lock or use a compare-and-swap so concurrent calls don't
     collide
3. Construct both branch names (`pool/...` and `safety/...`, identical
   after the scope prefix)
4. Get current `dev` HEAD commit SHA
5. Create both refs pointing at that SHA. **If the second creation
   fails, delete the first.** All-or-nothing.
6. Return success with the new branch names

**Synchronous contract:** the caller must receive the response only
after both refs exist on the remote. No fire-and-forget.

**Open implementation choices** (ask the user before picking):

- **Deployment model:** standalone HTTP service (Cloudflare Worker, Fly,
  Railway, AWS Lambda) vs. GitHub Actions `workflow_dispatch` with a
  thin polling wrapper. Standalone is genuinely sync; `workflow_dispatch`
  is sync-ish (poll until done).
- **Identity:** GitHub App with `contents:write` is preferred over a PAT
  on a machine user (finer permissions, better audit trail).
- **Lock mechanism for `nN` allocation:** advisory lock in a small KV
  store, optimistic compare-and-swap on a ref, or a mutex file committed
  to a side branch. Pick the simplest that's reliable.
- **Language:** whatever the user's team already runs in production.
  Defaults: TypeScript/Bun for a Worker, Python for Lambda, Go for
  anything self-hosted.

**Acceptance criteria:**

- Issuing two concurrent requests results in two distinct `nN` values,
  never the same `nN` allocated twice (test via parallel invocation)
- If the second branch creation fails (simulate with API stub),
  neither branch exists on the remote afterward
- Caller receives a structured error (not a hang, not a timeout) within
  10s if anything goes wrong
- The branch name returned matches the format regex
- Invocations with invalid `kind` or `short_name` are rejected at step 1
  with a clear validation error
- The bot identity is the *only* identity that successfully creates
  `pool/*` or `safety/*` branches (depends on Milestone 4)

---

### Milestone 3 - CI workflows

**Scope:** the version-bump and release automation triggered by merges
to `dev` and `main`.

**Deliverables:**

- `.github/workflows/dev-merge.yml`
- `.github/workflows/main-merge.yml`

**Trigger:** `push` to `dev` and `main` respectively, filtered so the
workflow's own bump commit doesn't retrigger it (use `[skip ci]` in the
commit message, or check `github.event.head_commit.author`).

**`dev-merge.yml` behavior:**

1. Checkout with `fetch-depth: 0` (need full history for tag lookup)
2. Read current `VERSION` file → e.g., `v2026.0.164`
3. Parse the YYYY from the *current calendar*, not from the VERSION file
4. If current year differs from VERSION's year, the bump logic in step 6
   must handle the rollover
5. Tag the merge commit (HEAD before our bump commit) with `v2026.0.164`
   as an annotated tag; push the tag
6. Compute next active version:
   - Same year → bump `dev_counter` (164 → 165)
   - New year → set `main_counter=0`, `dev_counter=1` (NOTE: this
     is the rare case where a dev merge is the first event of a new
     year with no main merge yet - see strategy doc, "Year-rollover
     behavior")
7. Write the new active version to `VERSION`
8. Commit the bump as `chore(version): v2026.0.164 → v2026.0.165 [skip ci]`
9. Push

**`main-merge.yml` behavior:**

1. Checkout with `fetch-depth: 0`
2. Read current `VERSION`. Drop the trailing `.dev_counter` segment - that's the release version (vYYYY.main.dev → vYYYY.main).
3. Tag the merge commit with the release version (e.g., `v2026.0`)
4. Create a GitHub Release from the tag, with auto-generated release notes
5. Identify safety branches to delete: list `safety/*` branches and
   check if their paired `pool/*` branch has been merged into the current
   `dev` (use `git branch --merged dev` filtered to `pool/*`, then map
   each to its `safety/*` pair). Delete those safety branches.
6. Compute next active version:
   - Current year → bump `main_counter`, reset `dev_counter` to 1
   - New year → set `main_counter=0`, `dev_counter=1`
7. Write the new active version to `VERSION`
8. Commit the bump as `chore(version): v2026.0 → v2026.1.1 [skip ci]`
9. Push

**Acceptance criteria:**

- A merge to `dev` results in exactly one new tag (on the merge commit)
  and one bump commit
- A merge to `main` results in exactly one new tag, one Release, and
  one bump commit
- The Release is *not* created for dev merges
- Safety branches whose dev pairs have been merged are gone after a
  main merge; safety branches whose dev pairs are still in flight are
  preserved
- Safety branches whose dev pairs were never merged (abandoned) are
  preserved indefinitely (test by creating such a pair and verifying
  it survives multiple main merges)
- The VERSION file always parses as a valid version under the format
  regex from Milestone 2
- Two concurrent merges (race) do not produce duplicate tags or version
  numbers - GitHub serializes pushes per branch, so this should hold
  naturally; verify the workflow logic doesn't introduce its own race

---

### Milestone 4 - Repository Rules / branch protection

**Scope:** the server-side gate that makes Milestones 1-3 enforceable.

**Deliverables:** documentation (`docs/repo-config.md` or similar) plus,
if practical, a script using `gh api` or Terraform's `github` provider
to apply the rules idempotently.

**Required rules:**

- **`main`:**
  - PR required
  - Required status checks: all CI jobs from Milestone 3 must pass
  - ≥1 review required
  - No direct push (no committers, only the CI bot for the bump commit)
  - No force-push
- **`dev`:**
  - PR required
  - Required status checks: dev-merge.yml's checks must pass
  - No direct push (except the CI bot for the bump commit)
- **`pool/*` pattern (branch creation):**
  - "Restrict creations": only the branch-creation App identity allowed
- **`safety/*` pattern (branch creation):**
  - "Restrict creations": only the branch-creation App identity allowed
- **`safety/*` pattern (modification):**
  - "Restrict updates": no pushes after creation (read-only)
  - "Restrict deletions": only the main-merge workflow identity allowed

**Acceptance criteria:**

- A developer's PAT or browser session cannot create a new `pool/n99.…`
  branch (verified by attempt)
- A developer cannot push commits to a safety branch (verified by attempt)
- A developer cannot delete a safety branch (verified by attempt)
- The branch-creation App can create `pool/*` and `safety/*` branches
- The main-merge workflow can delete safety branches

---

### Milestone 5 - CLI client

**Scope:** developer-facing tool for invoking the endpoint outside of
JIRA (spikes, admin actions, scripts).

**Deliverables:** a single executable, `bin/create-pool-branch`, that
dispatches the in-repo `allocate-pool-branch` GitHub Actions workflow
via `gh workflow run`. No standalone service.

**UX target:**

```
$ create-pool-branch parser-rewrite --jira PROJ-123 --kind feature --sprint 4
  ✓ actor=joel permission=admin on owner/repo
✓ allocator workflow dispatched on owner/repo
  watch: https://github.com/owner/repo/actions/runs/...
  (the workflow output JSON includes branch_name and branch_url; tail with: gh run watch -R owner/repo)
```

**Behavior:**

- Synchronous; blocks until the endpoint responds
- Auth: reads token from `gh auth token` or env var
- On success, prints the branch name and a one-liner the dev can copy
  to check it out
- On failure, prints the structured error from the endpoint
- Exit code 0 on success, non-zero on any failure
- `--dry-run` flag that validates input and shows what would be created
  without calling the endpoint

**Acceptance criteria:**

- Round-trips with the live endpoint successfully
- Rejects malformed inputs locally (without hitting the endpoint) where
  possible - e.g. `--kind=nonsense` should error before the network call
- The success output is parseable by other tools (consider a `--json` flag)

---

## Open Questions (ask the user before starting)

1. **Forge confirmation.** Is this GitHub, or another forge (GitLab,
   Bitbucket, Gitea)? Several mechanisms (Repository Rules, GitHub App,
   Releases) are GitHub-specific.
2. **Endpoint deployment.** Standalone HTTP service or
   `workflow_dispatch` wrapper? (See Milestone 2 - Open Choices.)
3. **Endpoint language.** Any preference? Suggest TypeScript/Bun for a
   Worker, Python for Lambda, Go for self-hosted.
4. **VERSION storage.** OK to use a `VERSION` file at repo root, or
   would they prefer to derive from tags only (no file)?
5. **Existing CI.** Are there existing GitHub Actions workflows we need
   to integrate with or avoid conflicting with?
6. **Bot identity.** Do they already have a GitHub App in the org we
   should reuse, or should we create a new one specifically for this?
7. **JIRA integration.** Out of scope for Milestones 1-5? (The handoff
   covers the endpoint that JIRA will call; the JIRA-side automation
   is a separate piece of work.)
8. **CLI distribution.** Where does it live - same repo, or a separate
   tooling repo? How do devs get it installed?

---

## Order of Operations Recommendation

Ship in this order; each milestone is independently useful:

1. **M1 (Local hooks)** - immediate value, no infra, gives the team a
   feel for the format
2. **M4 (Branch protection)** - enforce the rules at the server before
   investing in the endpoint
3. **M3 (CI workflows)** - version bumping and tagging come online; the
   team can start landing PRs under the new versioning
4. **M2 (Endpoint)** - once the surrounding policy is in place, the
   allocator becomes the proper way to create branches. Until then,
   admins create branches manually via `gh` CLI.
5. **M5 (CLI)** - last; wraps M2 for ergonomics

If the user wants to ship M2 earlier (e.g. before M4), that's fine, but
note that without M4, devs can still bypass the endpoint by creating
branches directly.

---

## Things explicitly *not* in scope here

- JIRA-side automation (the webhook from JIRA to the endpoint) - separate work
- Slack notifications on release - separate work
- Changelog generation beyond what GitHub's auto-generated notes provide
- Migration plan for existing branches under the old naming scheme
- Documentation for downstream consumers of the public releases

If any of these come up, ask the user whether to scope them in.
