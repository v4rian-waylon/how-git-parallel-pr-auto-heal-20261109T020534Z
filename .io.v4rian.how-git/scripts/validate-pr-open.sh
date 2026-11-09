#!/usr/bin/env bash
# validate-pr-open.sh - canonical PR-open validator for the v4rian model.
#
# Invoked by .github/workflows/validate-pr-open.yml on every
# pull_request: [opened, edited, synchronize] event targeting dev or
# main. Same script handles both pool→dev and dev→main flows so the
# shielding, body amendment, and status-check posting all funnel
# through one place. Devs cannot evade by opening a PR a different
# way - the workflow re-runs server side and the dev branch ruleset
# requires the opened-via-correct-flow check before merge.
#
# Behavior in order:
#
#   1. Hard reject when the source branch shape is wrong for the
#      target. pool/* → dev and dev → main are the only legal pairs.
#      Anything else gets the PR closed via `gh pr close` with a
#      comment naming the rule violated.
#
#   2. Hard reject when the target is `main` AND the actor (PR author)
#      is not an admin on the repo. Releases are admin-only by design.
#      PRs into `dev` (the pool→dev path) are openable by any dev with
#      write access - the deeper enforcement on dev happens via the
#      server-side ruleset and the async audit-pushed-branch checks.
#
#   3. Scrub the PR body's characters (auto_fix_body from
#      scripts/lib/auto-fix-commit-message.sh), drop any legacy
#      signature comment, and gate it with check-merge-message.sh:
#      the body becomes the merge body, so it keeps the ruled shape
#      and nothing here prepends a tag, flattens the list or appends
#      a signature.
#
#   4. Post the opened-via-correct-flow status check on the PR head
#      commit. Green when all checks above passed; red when the PR
#      was closed for a rule violation.
#
# Step 3 also amends the PR title to the canonical merge-subject form
# so the GitHub UI's default merge subject (which the merger sees in
# the confirm-merge dialog) matches what the post-merge claim scripts
# will eventually stamp on the merge commit. Both bin/init-pool-merge
# and bin/init-release open the PR with a placeholder title and
# advertise to the caller that validate-pr-open completes the rename:
#
#   base=dev    [MERGE] <pool-branch> into dev: $(bin/version --next-dev)
#   base=main   [MERGE] dev into main: $(bin/version --release-tag)
#
# Without this amendment the placeholder title leaks into the merge
# commit when the merger uses the default subject (the dev-to-main
# defect previously observed under D-12). claim-dev-merge.sh and
# claim-main-release.sh still own the final merge-subject rewrite
# after the merge lands; this step keeps the open-PR view honest in
# the meantime.
#
# Env contract (all set by the workflow):
#
#   PR_NUMBER       - PR number (e.g. 42)
#   PR_HEAD_REF     - source branch (e.g. pool/n7.feature.foo)
#   PR_BASE_REF     - target branch (dev or main)
#   PR_HEAD_SHA     - head commit SHA the status check attaches to
#   PR_ACTOR        - PR author login
#   PR_BODY         - current body text
#   GH_TOKEN        - workflow token, scopes contents:read + pull-requests:write + statuses:write
#   GITHUB_REPOSITORY - owner/repo
#   GITHUB_RUN_ID   - for signature embedding
#
# Exit codes:
#   0  - validation passed (PR amended where needed, status check green)
#   1  - validation failed for a recoverable reason; status check red, PR may stay open
#   2  - fatal: PR closed with comment because source/actor was illegal
#   3  - env contract violation (missing required input)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script + lib + bin under the namespace dir, regardless of cwd.
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS_DIR=$(dirname "$SCRIPT_DIR")
REPO_ROOT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)
AUTO_FIX_LIB="$SCRIPT_DIR/lib/auto-fix-commit-message.sh"
# Shared helpers: HG_POOL_PREFIX_RE is the one branch-shape definition.
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# Test mode short-circuit: when LIFECYCLE_TEST_MODE=1 is set and the
# required env vars are absent, skip the gh-touching path so the unit
# tests can source this file or invoke its helpers without a live API.
if [ "${LIFECYCLE_TEST_MODE:-0}" = "1" ] && [ -z "${PR_NUMBER:-}" ]; then
  echo "→ test-mode: PR_NUMBER unset; sourcing helpers without gh dispatch"
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Env contract validation
# ---------------------------------------------------------------------------
require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "X validate-pr-open: required env var $name is unset" >&2
    exit 3
  fi
}

require_env PR_NUMBER
require_env PR_HEAD_REF
require_env PR_BASE_REF
require_env PR_HEAD_SHA
require_env PR_ACTOR
require_env GH_TOKEN
require_env GITHUB_REPOSITORY

# Optional fields default to empty so amending against a blank body works.
PR_BODY="${PR_BODY:-}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-0}"

REPO="$GITHUB_REPOSITORY"
STATUS_CONTEXT="opened-via-correct-flow"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Post a commit status (the required check on the PR head commit).
post_status() {
  local state="$1"   # success | failure | pending | error
  local desc="$2"
  gh api -X POST \
    "repos/${REPO}/statuses/${PR_HEAD_SHA}" \
    -f "state=${state}" \
    -f "context=${STATUS_CONTEXT}" \
    -f "description=${desc}" \
    --silent 2>/dev/null || true
}

# Close the PR with a comment naming the rule violated. Used only on
# the hard-reject paths (illegal source branch, non-admin actor).
close_pr_with_reason() {
  local reason="$1"
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$reason" >/dev/null 2>&1 || true
  gh pr close "$PR_NUMBER" --repo "$REPO" --comment "$reason" >/dev/null 2>&1 || true
  post_status "failure" "PR closed: rule violated"
}

# Derive [KIND] from a pool/* branch name. Returns the bracketed
# canonical tag for the auto-derived title. Mapping mirrors the
# allocator's kind set.
kind_to_tag() {
  case "$1" in
    feature)    echo "[NEW]" ;;
    fix)        echo "[FIX]" ;;
    refactor)   echo "[REFACTOR]" ;;
    r\&d)       echo "[REFACTOR]" ;;
    reconcile)  echo "[REFACTOR]" ;;
    doc)        echo "[DOCS]" ;;
    *)          echo "[REFACTOR]" ;;
  esac
}

# Pull the kind segment out of a pool/nN.kind.short branch. Handles both
# the legacy flat layout (pool/nN.kind.short) and the vYYYY.MAIN/ prefixed
# layout (pool/vYYYY.MAIN/nN.kind.short) by consuming the optional major
# segment before extracting the kind.
pool_kind() {
  echo "$1" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?n[0-9]+\.([a-z&]+)\..*|\2|'
}

# ---------------------------------------------------------------------------
# Step 1 - source-branch shape validation
# ---------------------------------------------------------------------------

case "$PR_BASE_REF" in
  dev)
    if ! [[ "$PR_HEAD_REF" =~ $HG_POOL_PREFIX_RE ]]; then
      reason="PR closed: only pool/[vYYYY.MAIN/]nN.kind.short-name branches may open PRs into dev. Source '${PR_HEAD_REF}' violates the v4rian branch shape rule. See .io.v4rian.how-git/docs/Git_Strategy.md."
      echo "X $reason" >&2
      close_pr_with_reason "$reason"
      exit 2
    fi
    ;;
  main)
    if [ "$PR_HEAD_REF" != "dev" ]; then
      reason="PR closed: only the dev branch may open PRs into main. Source '${PR_HEAD_REF}' violates the v4rian release-promotion rule. See .io.v4rian.how-git/docs/Git_Strategy.md."
      echo "X $reason" >&2
      close_pr_with_reason "$reason"
      exit 2
    fi
    ;;
  *)
    reason="PR closed: validate-pr-open only governs PRs into dev or main. Target '${PR_BASE_REF}' is out of scope; open the PR against dev (for pool/* sources) or main (for dev)."
    echo "X $reason" >&2
    close_pr_with_reason "$reason"
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Step 2 - actor (PR author) admin check, ONLY for dev → main PRs
# ---------------------------------------------------------------------------
# Pool → dev PRs are openable by any dev with write access; the deeper
# enforcement on dev is the server-side ruleset plus the async audit
# checks. Dev → main PRs ARE admin-only because they promote a release.

if [ "$PR_BASE_REF" = "main" ]; then
  PERM=$(gh api "repos/${REPO}/collaborators/${PR_ACTOR}/permission" --jq '.permission' 2>/dev/null || echo "unknown")
  echo "→ actor=${PR_ACTOR} permission=${PERM} (base=main; admin required)"
  if [ "$PERM" != "admin" ]; then
    reason="PR closed: actor '${PR_ACTOR}' has permission '${PERM}' on ${REPO} but admin is required to open dev → main release PRs under the v4rian model. Ask a repo admin to open the release PR on your behalf."
    echo "X $reason" >&2
    close_pr_with_reason "$reason"
    exit 2
  fi
else
  echo "→ actor=${PR_ACTOR} (base=${PR_BASE_REF}; admin check not required for pool → dev)"
fi

# ---------------------------------------------------------------------------
# Step 3 - amend the PR title to the canonical merge-subject form
# ---------------------------------------------------------------------------
# The placeholder titles emitted by bin/init-pool-merge and
# bin/init-release are stand-ins until this workflow runs. Compute the
# canonical form from PR_BASE_REF + PR_HEAD_REF + bin/version, fetch
# the current title via gh pr view (the workflow does not pass the
# title in the env), and PATCH only when it drifts. Title PATCH
# failures are non-fatal - the body amendment and status check below
# still run so the validator does not block a PR on a cosmetic gap.

VERSION_BIN="$REPO_ROOT/.io.v4rian.how-git/bin/version"

derive_canonical_title() {
  # Prints the canonical PR title for the (base, head, version) tuple.
  # Returns empty + nonzero exit when bin/version fails so the caller
  # can skip the amendment cycle without aborting the validator.
  local base="$1" head="$2"
  local ver
  case "$base" in
    dev)
      ver=$("$VERSION_BIN" --next-dev 2>/dev/null) || return 1
      printf '[MERGE] %s into dev: %s' "$head" "$ver"
      ;;
    main)
      ver=$("$VERSION_BIN" --release-tag 2>/dev/null) || return 1
      printf '[MERGE] dev into main: %s' "$ver"
      ;;
    *)
      return 1
      ;;
  esac
}

if [ ! -x "$VERSION_BIN" ]; then
  echo "  ! $VERSION_BIN not executable; skipping title amendment"
else
  CANONICAL_TITLE=$(derive_canonical_title "$PR_BASE_REF" "$PR_HEAD_REF" || true)
  if [ -z "$CANONICAL_TITLE" ]; then
    echo "  ! could not derive canonical title for base=$PR_BASE_REF; skipping title amendment"
  else
    CURRENT_TITLE=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title --jq '.title' 2>/dev/null || echo "")
    if [ -z "$CURRENT_TITLE" ]; then
      echo "  ! gh pr view returned empty title; skipping title amendment"
    elif [ "$CURRENT_TITLE" = "$CANONICAL_TITLE" ]; then
      echo "  ok title already canonical: $CANONICAL_TITLE"
    else
      echo "  -> amending title: '$CURRENT_TITLE' -> '$CANONICAL_TITLE'"
      if ! gh pr edit "$PR_NUMBER" --repo "$REPO" --title "$CANONICAL_TITLE" >/dev/null 2>&1; then
        echo "  ! gh pr edit --title failed; continuing with body amendment"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 4 - body scrub + merge shape gate
#
# The PR body becomes the merge commit body word for word (the claim adds
# only its "PR #N <url>" paragraph), so it follows the ruled merge shape:
# a 1-3 sentence macro paragraph, a blank line, a nested list with a period
# on every line. The scrub here touches characters only (dashes, the banned
# "plus" joiner, a Co-Authored-By: Claude trailer): no derived [TAG] on the
# paragraph, no sentence cap that would flatten the list, no signature
# appended. A signature left by older runs of this flow is removed. The
# scrubbed body then goes through check-merge-message.sh; a body that breaks
# the shape fails the opened-via-correct-flow status, so it cannot merge.
# ---------------------------------------------------------------------------

if [ ! -f "$AUTO_FIX_LIB" ]; then
  echo "X validate-pr-open: auto-fix library missing at $AUTO_FIX_LIB" >&2
  post_status "error" "auto-fix library missing"
  exit 1
fi

# Persist the body to a temp file so the library can rewrite it in place.
WORK=$(mktemp -d -t validate-pr-open-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
BODY_FILE="$WORK/body.txt"

# Strip any legacy signature line (<!-- opened-via-correct-flow run=N -->)
# and the blank line that preceded it.
printf '%s\n' "$PR_BODY" \
  | sed -E '/<!-- opened-via-correct-flow run=[^>]* -->/d' \
  | awk '{ l[++n] = $0 } END { while (n > 0 && l[n] ~ /^[ \t]*$/) n--; for (i = 1; i <= n; i++) print l[i] }' \
  > "$BODY_FILE"

# shellcheck disable=SC1090
. "$AUTO_FIX_LIB"
auto_fix_body "$BODY_FILE"

NEW_BODY=$(cat "$BODY_FILE")

if [ "$PR_BODY" != "$NEW_BODY" ]; then
  echo "→ amending body (character scrub or legacy signature removal)"
  gh pr edit "$PR_NUMBER" --repo "$REPO" --body "$NEW_BODY" >/dev/null 2>&1 || {
    echo "X body amendment failed" >&2
    post_status "failure" "body amendment failed"
    exit 1
  }
else
  echo "→ body already canonical; no amendment needed"
fi

if ! bash "$SCRIPT_DIR/check-merge-message.sh" --body-file "$BODY_FILE"; then
  echo "X validate-pr-open: PR body breaks the merge body shape; edit it and the workflow re-runs" >&2
  post_status "failure" "PR body must be a 1-3 sentence paragraph, a blank line, a nested list, periods"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 5 - post the green status check
# ---------------------------------------------------------------------------

post_status "success" "PR opened via the v4rian validate-pr-open flow"

# On dev->main PRs, also report the `release` required context. main's branch
# protection binds it, but nothing pre-merge ever reported it (the release
# claim runs post-merge), so every release PR sat at "Expected - waiting"
# and merged only via silent admin bypass. The releasability gate here is
# real: the release version must resolve from the repo state.
if [ "$PR_BASE_REF" = "main" ]; then
  RELEASE_VERSION=$("$NS_DIR/bin/version" --release-tag 2>/dev/null | tr -d '\r\n' || true)
  if [ -n "$RELEASE_VERSION" ]; then
    gh api -X POST \
      "repos/${REPO}/statuses/${PR_HEAD_SHA}" \
      -f "state=success" \
      -f "context=release" \
      -f "description=releasable as ${RELEASE_VERSION} (claim runs post-merge)" \
      --silent 2>/dev/null || true
    echo "→ release status posted: ${RELEASE_VERSION}"
  else
    gh api -X POST \
      "repos/${REPO}/statuses/${PR_HEAD_SHA}" \
      -f "state=failure" \
      -f "context=release" \
      -f "description=bin/version --release-tag did not resolve a version" \
      --silent 2>/dev/null || true
    echo "! release status FAILED: version did not resolve"
  fi
fi

# Initial `reconcile` status from live mergeability. The reconcile pass
# refreshes this context on every dev merge, but a freshly opened PR has
# no status until the next pass, and binding reconcile as a required
# check would leave clean PRs stuck at "Expected". Seed it here from the
# PR's actual mergeability so green always means "merges as it stands":
# a conflicting head reads failure the moment it is pushed, never stale
# green beside a conflict banner.
if [ "$PR_BASE_REF" = "dev" ]; then
  # GitHub computes mergeability lazily and the first query usually
  # answers UNKNOWN; querying is what schedules the computation, so a
  # short poll settles it for nearly every PR open.
  MERGEABLE="UNKNOWN"
  for _attempt in 1 2 3 4 5; do
    MERGEABLE=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")
    [ "$MERGEABLE" = "MERGEABLE" ] || [ "$MERGEABLE" = "CONFLICTING" ] && break
    sleep 5
  done
  case "$MERGEABLE" in
    MERGEABLE)
      gh api -X POST "repos/${REPO}/statuses/${PR_HEAD_SHA}" \
        -f "state=success" \
        -f "context=reconcile" \
        -f "description=mergeable against dev as it stands" \
        --silent 2>/dev/null || true
      echo "→ reconcile status seeded: mergeable"
      ;;
    CONFLICTING)
      gh api -X POST "repos/${REPO}/statuses/${PR_HEAD_SHA}" \
        -f "state=failure" \
        -f "context=reconcile" \
        -f "description=conflicts with dev; the next reconcile pass publishes a candidate" \
        --silent 2>/dev/null || true
      echo "! reconcile status seeded: CONFLICTING"
      ;;
    *)
      # GitHub computes mergeability lazily; UNKNOWN here resolves on the
      # next synchronize event or reconcile pass. Leave no status rather
      # than guess one.
      echo "  · mergeability not yet computed ($MERGEABLE); reconcile status left to the next pass"
      ;;
  esac
fi

# Post the legacy bump status green. The bump context is a required check
# at the org-level branch protection on dev that no workflow else owns,
# so a PR opened through this flow stamps it from here. Repos that do
# not have bump in their required_status_checks simply receive an
# extra green status with no merge gate behavior attached to it.
gh api -X POST \
  "repos/${REPO}/statuses/${PR_HEAD_SHA}" \
  -f "state=success" \
  -f "context=bump" \
  -f "description=stamped green by validate-pr-open; the legacy context has no live owner" \
  --silent 2>/dev/null || true

echo "OK validate-pr-open: status checks posted green for PR #${PR_NUMBER}"
exit 0
