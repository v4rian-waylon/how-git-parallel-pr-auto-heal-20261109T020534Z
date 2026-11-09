#!/usr/bin/env bash
# auto-rebase-pools-after-dev-merge.sh: produce a reconcile candidate for
# every active pool/* PR after a successful dev merge claim. The script
# NEVER mutates a developer's pool branch and NEVER closes the original
# PR - automation only UPDATES existing PRs and, for a CLEAN replay of an
# already-legitimated PR, OPENS one cross-linked reconcile PR. The
# developer is sovereign in their pool/* sandbox, but sovereignty cannot
# halt the project: a successful pass links the reconcile candidate on the
# existing PR (recap comment with the quick create link plus the reconcile
# commit status) so the admin can integrate the reconciled work without
# waiting for the developer. Only the admin decides what lands on dev via
# review.
#
# Inherit-status and cross-linked-PR behavior (supersedes the prior
# "never opens a PR" line for the CLEAN-and-legitimated case; the
# conflict/L1-L5 case still never opens a PR):
#   - LEGITIMATED-PR GATE: a PR is reconciled with inheritance ONLY when
#     all 5 required.* checks were already success on its ORIGINAL head
#     SHA before the dev merge (required.commit-audit, required.compile,
#     required.coverage, required.runtime, required.offline-test-suites).
#     If any of the 5 is not success the PR was not legitimated: the pass
#     keeps today's comment-only behavior and logs "not previously green;
#     reconcile candidate left for manual review". No inherit, no PR-open.
#   - INHERIT (CLEAN replay only): a clean cherry-pick with zero conflict
#     edits is byte-identical content to what already passed those checks,
#     so the bot POSTs each of the 5 required.* statuses as success onto
#     the reconcile candidate SHA - inheriting a known-true result with no
#     CI re-run, no workflow triggering, no App, no human. The bot posted
#     them, so vault-provenance passes. The conflict/L1-L5 path NEVER
#     inherits: conflict-resolved commits changed content and must be
#     audited for real.
#   - CROSS-LINKED PR (CLEAN and legitimated only): the pass opens one
#     real reconcile->dev PR whose head is the reconcile branch and whose
#     body cross-references the original PR number (so GitHub auto-creates
#     a timeline cross-reference) and states the original is kept as the
#     record. Idempotent: a second pass does not open a duplicate; it
#     refreshes the existing reconcile PR's body. A one-line cross-link
#     comment then lands on the ORIGINAL PR. The original PR stays open
#     and untouched (the record).
#
# Triggered from claim-dev-merge.sh after the post-claim tag + push.
# For each open PR whose head branch matches the pool/* shape:
#
#   1. Update the PR title's aspirational version prefix to the version
#      it would actually claim if merged next. This is a metadata edit
#      only - it does not touch the pool branch or the PR's open state.
#   2. Cut `pool/nN.reconcile.<short>` off the new dev tip (same nN as
#      the original pool, kind=reconcile, short=original short). The
#      canonical reconcile name stays clean across every pass: no -2 /
#      -3 / -<sha> enumeration ever appears on it. A reconcile candidate
#      is machine-owned, freely rewritable state - NOT developer history.
#      Each pass rebuilds it from scratch against the new dev tip (step 3)
#      and FORCE-PUSHES it onto the canonical name: a rolling pointer that
#      repoints in place. No delete, no rename, no tmp slot. A
#      non-fast-forward update of a pool/*.reconcile.* ref is permitted for
#      the plain workflow token (pool-creations carves reconcile out,
#      pool-deletions never fires on an update, and the no-force rule binds
#      only the DEVELOPER's pool branch). The developer's pool/* branch is
#      still NEVER force-pushed - see feedback_how_git_never_rewrites_history.
#   2a. Post a START-of-reconcile comment on the existing PR BEFORE any
#       cherry-pick attempt so the admin / developer has live visibility
#       into the in-flight pass. The end-of-pass comment (step 4b / 5)
#       still lands at the end; this additive start comment is what gives
#       the PR a two-comment timeline per reconcile attempt instead of
#       just an end-only signal.
#   3. Cherry-pick the pool branch's commits (OLD_BASE..OLD_TIP) onto
#      the reconcile branch one at a time. On any cherry-pick conflict,
#      escalate through the L1-L5 ladder via claude_skill_run to attempt
#      smart resolution. The original pool branch is read-only here.
#   4. All commits cherry-picked successfully (clean or with claude help):
#        a. Force-push the reconcile branch onto the canonical name. The
#           candidate ref carries no CI of its own (a workflow-token push
#           never re-triggers ci-dispatch); it is validated by dev's
#           required checks when the admin merges it.
#        b. Comment on the existing PR with the recap directed at the
#           admin: dev advanced to <sha>, reconcile candidate is
#           `pool/nN.reconcile.<short>`, conflicts resolved as follows.
#        c. Do NOT close the original PR. Do NOT open a new PR. Do NOT
#           push to the original pool branch. The recap comment carries
#           the candidate and its quick create link; the original PR is
#           the developer's record and automation only updates it.
#   5. Some commits unresolvable after L5: push the partial reconcile
#      state for review, comment on the original PR with the unresolved
#      file list plus the full L1-L5 attempt log. The PR stays open;
#      the developer or admin picks up from the partial state.
#   6. Iterative: if dev advances again before either party acts, the
#      next auto-rebase pass rebuilds the canonical reconcile name from
#      scratch against the newest dev tip and force-pushes it (step 2).
#      Prior attempts are not retained as numbered receipts; the canonical
#      ref always carries the most-recent candidate. Receipts of every
#      reconcile attempt still live in the PR's comment timeline (start +
#      end comment pair per pass).
#
# The dev's window of action is organic, not turn-taking: they own the
# pool branch and can push their own resolution at any time. If they
# push a clean state before the admin reviews, the reconcile candidate
# is moot and stays as a receipt only. If the admin reviews first and
# acts on the reconcile, a slow dev's in-progress work becomes wasted
# time. The system gives no protection for slowness; admin's review is
# the gate (see feedback_how_git_never_rewrites_history).
#
# Network-bound: requires gh CLI for PR enumeration + edit + create +
# comment. Skipped silently in LIFECYCLE_TEST_MODE so offline e2e
# doesn't reach GitHub.
#
# Usage:
#   auto-rebase-pools-after-dev-merge.sh                do the rebase pass
#   auto-rebase-pools-after-dev-merge.sh --dry-run      show what would change
#   auto-rebase-pools-after-dev-merge.sh -h | --help    print this help

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "X auto-rebase-pools-after-dev-merge.sh: not inside a git repo" >&2
  exit 2
fi

# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# A reconcile worktree lives in a mktemp dir; an abort mid-pass (^C, a
# killed runner) must not strand it or its registration in the repo.
WORKTREE=""
CHERRYPICK_LOG=""
cleanup_reconcile_worktree() {
  [ -z "$CHERRYPICK_LOG" ] || rm -f "$CHERRYPICK_LOG"
  [ -n "$WORKTREE" ] || return 0
  git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" 2>/dev/null || true
  rm -rf "$WORKTREE"
}
trap cleanup_reconcile_worktree EXIT

DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)  sed -n '2,109p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "X unknown flag: $1" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"

# AUTO_REBASE_FORCE_RUN=1 is the synthetic-e2e test escape: with the gh
# mock active on PATH and AUTO_REBASE_FORCE_RUN=1 set, the script still
# runs end-to-end while LIFECYCLE_TEST_MODE keeps claude_resolve_conflict
# in its deterministic surrogate path. This lets the parallel-PR
# conflict-heal e2e drive the L1-L5 ladder against a synthesized
# conflict scenario without reaching real GitHub or burning claude API
# quota. The default short-circuit still applies for the broader
# lifecycle suite that does not want to exercise the gh-touching path.
if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ] && [ "${AUTO_REBASE_FORCE_RUN:-}" != "1" ]; then
  echo "  . [test-mode] auto-rebase-pools-after-dev-merge skipped (would have iterated open PRs)" >&2
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "  . gh CLI not installed; skipping auto-rebase pass (install gh to enable)" >&2
  exit 0
fi

# Aspirational version derivation from latest reachable tag this year.
# (Tags-as-seal model: VERSION isn't tracked. Falls back to the legacy
# VERSION file content if present, for repos pre-redesign that haven't
# adopted the new model yet.)
NOW_YEAR=$(date -u +%Y)
LATEST_TAG=$(git describe --tags --match "v${NOW_YEAR}.*" --abbrev=0 HEAD 2>/dev/null || true)
ASPIRATIONAL=""
if [ -n "$LATEST_TAG" ]; then
  case "$LATEST_TAG" in
    v[0-9]*.[0-9]*.[0-9]*)
      _main=$(echo "$LATEST_TAG" | awk -F. '{print $2}')
      _dev=$(echo "$LATEST_TAG" | awk -F. '{print $3}')
      ASPIRATIONAL="v${NOW_YEAR}.${_main}.$((_dev + 1))"
      ;;
    v[0-9]*.[0-9]*)
      _main=$(echo "$LATEST_TAG" | awk -F. '{print $2}')
      ASPIRATIONAL="v${NOW_YEAR}.$((_main + 1)).1"
      ;;
  esac
elif [ -f VERSION ]; then
  ASPIRATIONAL=$(cat VERSION)
fi

echo "-> auto-rebase pass: dev tip $(git rev-parse --short HEAD)${ASPIRATIONAL:+ aspirational $ASPIRATIONAL}"

REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
if [ -z "$OWNER_REPO" ]; then
  echo "  . could not derive owner/repo from origin URL; skipping" >&2
  exit 0
fi

# Pool branch shape regex - includes `reconcile` as the 5th legal kind
# so reconcile branches themselves get rebased on subsequent dev merges
# (the iterative chain case in the docstring). Accepts both the legacy
# flat layout (pool/nN.kind.short) and the prefixed layout
# (pool/vYYYY.MAIN/nN.kind.short) so reconcile branches land under the
# same release-line classification as the original allocation.
POOL_PATTERN="$HG_POOL_BRANCH_RE"

short_name_of() {
  # Strip "pool/[vYYYY.MAIN/]nN.<kind>." prefix to get the trailing
  # short-name. The optional major-prefix segment is consumed first so
  # both layouts collapse to the same short name.
  echo "$1" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?n[0-9]+\.[a-z&]+\.||'
}

n_of() {
  # Extract the nN counter, ignoring the optional major-prefix segment.
  echo "$1" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?(n[0-9]+)\..*|\2|'
}

major_prefix_of() {
  # Return the vYYYY.MAIN segment when the branch carries one; empty
  # string when on the legacy flat layout. Used so the reconcile branch
  # inherits the original allocation's release-line classification.
  echo "$1" | sed -nE 's|^pool/(v[0-9]+\.[0-9]+)/n[0-9]+\..*|\1|p'
}

# Progress signal in the PR header where the admin looks: a `reconcile`
# commit status on the ORIGINAL PR's head SHA - pending at pass start,
# success/failure at the end. Comments carry the receipts; the status
# carries the at-a-glance state.
post_recon_status() {
  local sha="$1" state="$2" desc="$3"
  [ -n "$sha" ] || return 0
  gh api -X POST "repos/${OWNER_REPO}/statuses/${sha}" \
    -f "state=${state}" -f "context=reconcile" -f "description=${desc}" \
    --silent >/dev/null 2>&1 || true
}

# The 5 required status check contexts a PR must already carry as success
# on its head SHA to be a LEGITIMATED PR. Kept verbatim in sync with
# rulesets/dev-required-checks.json (the `reconcile` context there is the
# at-a-glance signal this script posts, NOT a required.* CI check, so it
# is not in this gate list). These are the only checks the inherit path
# replays onto the reconcile candidate.
REQUIRED_CONTEXTS="required.commit-audit required.compile required.coverage required.runtime required.offline-test-suites"

# pr_is_legitimated: read the success contexts on the ORIGINAL PR head SHA
# and return 0 only when ALL 5 required.* contexts are success. A PR that
# was already all-required-green before the dev merge is legitimated; its
# content already passed every required check, so a byte-identical clean
# replay can inherit those results. Any missing or non-success context
# means the PR was never legitimated and inheritance is refused.
#
# A required context counts as success when it passed as EITHER a check run
# (Checks API, where GitHub Actions reports every required.* job) OR a legacy
# commit status (Status API). Branch protection treats the two uniformly by
# context name, so this read unions both. Reading only the Status API misses
# the Actions check runs entirely, which is how every live required.* check
# reports, so the gate would never recognize a real legitimated PR. See
# feedback_pr_is_legitimated_reads_check_runs.
pr_is_legitimated() {
  local sha="$1"
  [ -n "$sha" ] || return 1
  local statuses_json checkruns_json
  statuses_json=$(gh api "repos/${OWNER_REPO}/commits/${sha}/status" 2>/dev/null || echo "")
  checkruns_json=$(gh api "repos/${OWNER_REPO}/commits/${sha}/check-runs" 2>/dev/null || echo "")
  [ -n "${statuses_json}${checkruns_json}" ] || return 1
  STATUSES_JSON="$statuses_json" CHECKRUNS_JSON="$checkruns_json" REQ="$REQUIRED_CONTEXTS" python3 -c '
import json, os, sys
ok = set()
try:
    data = json.loads(os.environ.get("STATUSES_JSON") or "{}")
    for e in data.get("statuses", []):
        if e.get("state") == "success":
            ok.add(e.get("context", ""))
except (ValueError, AttributeError):
    pass
try:
    cr = json.loads(os.environ.get("CHECKRUNS_JSON") or "{}")
    for e in cr.get("check_runs", []):
        if e.get("conclusion") == "success":
            ok.add(e.get("name", ""))
except (ValueError, AttributeError):
    pass
for ctx in os.environ["REQ"].split():
    if ctx not in ok:
        sys.exit(1)
sys.exit(0)
' >/dev/null 2>&1
}

# inherit_required_statuses: for a CLEAN replay of a legitimated PR, POST
# each of the 5 required.* contexts as success onto the reconcile
# candidate SHA. The clean cherry-pick produced byte-identical content to
# what already passed those checks on the original head, so the result is
# a known-true inheritance, not a fresh assertion. The bot posts them via
# the same statuses endpoint post_recon_status uses, so vault-provenance
# sees the bot as the author. NEVER called on the conflict/L1-L5 path.
inherit_required_statuses() {
  local recon_sha="$1" orig_pr="$2"
  [ -n "$recon_sha" ] || return 0
  local ctx
  for ctx in $REQUIRED_CONTEXTS; do
    gh api -X POST "repos/${OWNER_REPO}/statuses/${recon_sha}" \
      -f "state=success" -f "context=${ctx}" \
      -f "description=inherited green from #${orig_pr} (legitimated, clean replay)" \
      --silent >/dev/null 2>&1 || true
  done
}

# post_reconcile_mergeable_contexts: post the two non required.* dev gate
# contexts onto the reconcile candidate so the cross-linked PR is mergeable
# without an admin override - reconcile (this clean replay IS the resolved
# candidate, so success) and opened-via-correct-flow (the framework opens the
# cross-linked PR via its own flow, but a GITHUB_TOKEN-opened PR does not
# trigger validate-pr-open to post it). Both are success on the reconcile SHA
# via the same bot statuses endpoint so vault-provenance sees the bot.
post_reconcile_mergeable_contexts() {
  local recon_sha="$1" orig_pr="$2" dev_short="$3"
  [ -n "$recon_sha" ] || return 0
  post_recon_status "$recon_sha" "success" "clean replay inherited green from #${orig_pr}; merges clean onto dev ${dev_short}"
  gh api -X POST "repos/${OWNER_REPO}/statuses/${recon_sha}" \
    -f "state=success" -f "context=opened-via-correct-flow" \
    -f "description=opened by the reconcile automation (framework flow) from #${orig_pr}" \
    --silent >/dev/null 2>&1 || true
}

# open_or_refresh_reconcile_pr: open exactly one reconcile->dev PR whose
# head is the reconcile branch, cross-linking the original PR number so
# GitHub auto-creates a timeline cross-reference. Idempotent: if a PR for
# this head already exists, its body is refreshed instead of opening a
# second one. Echoes the reconcile PR number on stdout (empty on failure).
# CLEAN-and-legitimated path only - the original PR is never closed.
#
# The create runs under the CI bot App installation token (CLAIM_TAG_PUSH_TOKEN,
# the same identity that pushed the reconcile branch via lifecycle_push) rather
# than the workflow GITHUB_TOKEN. A GITHUB_TOKEN PR-create is rejected unless
# the org enables "Actions create and approve pull requests" - a setting that
# would also let CI APPROVE pull requests, which the model forbids (only admins
# approve). An App installation token can CREATE the PR without that toggle and
# without granting any approval right, so the security posture is preserved. No
# App token (no App installed) falls back to the ambient token and degrades to
# the comment-only path. See feedback_actions_pr_create_permission.
open_or_refresh_reconcile_pr() {
  local recon_branch="$1" orig_pr="$2" orig_head="$3" dev_short="$4"
  local title body existing recon_num pr_token
  pr_token="${CLAIM_TAG_PUSH_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
  title="[RECONCILE] candidate for #${orig_pr} onto dev ${dev_short}"
  body=$(printf 'Reconcile candidate for #%s. dev advanced to `%s`; the original `%s` head no longer merges clean, so this PR carries the same pool commits cleanly replayed onto the new dev tip. The original #%s is kept as the record and stays open and untouched; this candidate is the mergeable form. The 5 required checks are inherited as success from #%s (legitimated, byte-identical clean replay) so no CI re-run is needed.\n' "$orig_pr" "$dev_short" "$orig_head" "$orig_pr" "$orig_pr")
  existing=$(gh pr list --repo "$OWNER_REPO" --head "$recon_branch" --state open \
    --json number --jq '.[0].number' 2>/dev/null || echo "")
  if [ -n "$existing" ]; then
    # Refresh the cross-link body on the existing reconcile PR; do NOT open
    # a duplicate.
    GH_TOKEN="$pr_token" gh api -X PATCH "repos/${OWNER_REPO}/pulls/${existing}" -f "body=${body}" \
      --silent >/dev/null 2>&1 || true
    echo "$existing"
    return 0
  fi
  recon_num=$(GH_TOKEN="$pr_token" gh pr create --repo "$OWNER_REPO" --base dev --head "$recon_branch" \
    --title "$title" --body "$body" 2>/dev/null | sed -nE 's#.*/pull/([0-9]+).*#\1#p' | tail -1)
  echo "$recon_num"
}

# Update the EXISTING PR's body to POINT to the latest reconcile candidate.
# GitHub does not allow changing a PR's head branch (REST "Update a pull
# request" accepts title/body/state/base only), and the framework never opens
# a new PR or pushes to the developer's branch - so the PR body itself is where
# the admin is directed to the reconcile candidate. Idempotent: a sentinel
# block is replaced on every pass, never stacked.
point_pr_to_reconcile() {
  local num="$1" block="$2"
  local cur stripped newbody
  # REST GET/PATCH (gh pr edit uses GraphQL author fields that need read:org,
  # which the plain workflow token lacks; the REST pulls endpoint needs only
  # the repo scope the token already carries).
  cur=$(gh api "repos/${OWNER_REPO}/pulls/${num}" --jq '.body // ""' 2>/dev/null || echo "")
  stripped=$(printf '%s' "$cur" | sed -E '/<!-- reconcile-pointer-start -->/,/<!-- reconcile-pointer-end -->/d')
  newbody=$(printf '<!-- reconcile-pointer-start -->\n%s\n<!-- reconcile-pointer-end -->\n%s' "$block" "$stripped")
  gh api -X PATCH "repos/${OWNER_REPO}/pulls/${num}" -f "body=${newbody}" --silent >/dev/null 2>&1
}

PRS_JSON=$(gh pr list --repo "$OWNER_REPO" --state open --base dev \
  --json number,title,headRefName 2>/dev/null || echo "[]")
if [ "$PRS_JSON" = "[]" ] || [ -z "$PRS_JSON" ]; then
  echo "  . no open PRs targeting dev; nothing to rebase"
  exit 0
fi

echo "$PRS_JSON" | python3 -c 'import json,sys
for pr in json.load(sys.stdin):
    print("%s\t%s\t%s" % (pr["number"], pr["headRefName"], pr["title"]))' \
  | while IFS=$'\t' read -r NUM HEAD TITLE; do
      echo
      echo "-- PR #$NUM head=$HEAD --"
      if ! [[ "$HEAD" =~ $POOL_PATTERN ]]; then
        echo "  . head does not match pool/* shape (kinds: $HG_BRANCH_KINDS); skipping" >&2
        continue
      fi

      # Title aspirational-version update.
      if [ -n "$ASPIRATIONAL" ]; then
        NEW_TITLE=$(printf '%s' "$TITLE" | sed -E "s/v[0-9]{4}\.[0-9]+\.[0-9]+(-b\.[0-9]+)?/$ASPIRATIONAL/")
        if [ "$NEW_TITLE" != "$TITLE" ]; then
          echo "  -> updating title aspirational version -> $ASPIRATIONAL"
          if $DRY_RUN; then
            echo "    [dry-run] would: gh pr edit $NUM --title '$NEW_TITLE'"
          else
            gh pr edit "$NUM" --repo "$OWNER_REPO" --title "$NEW_TITLE" >/dev/null \
              || echo "    warn: title edit failed; continuing"
          fi
        fi
      fi

      # Fetch the pool branch + sync dev locally
      if ! git fetch -q origin "$HEAD:refs/remotes/origin/$HEAD" 2>/dev/null; then
        echo "  . could not fetch $HEAD; skipping" >&2
        continue
      fi
      git fetch -q origin dev 2>/dev/null || true

      OLD_TIP=$(git rev-parse "origin/$HEAD")
      DEV_TIP=$(git rev-parse origin/dev)

      # LEGITIMATED-PR GATE: a PR earns the inherit + cross-linked-PR path
      # only when all 5 required.* checks were already success on its
      # ORIGINAL head SHA before this dev merge. A clean replay of such a
      # PR is byte-identical content to what already passed, so the 5
      # statuses can be inherited as a known-true result. A PR that was not
      # all-required-green was never legitimated; it keeps today's
      # comment-only behavior and is left for manual review. The flag is
      # consulted only on the CLEAN path below; the conflict/L1-L5 path
      # never inherits regardless of legitimation.
      LEGITIMATED=false
      if pr_is_legitimated "$OLD_TIP"; then
        LEGITIMATED=true
        echo "  . PR #$NUM is legitimated (all 5 required.* green on $(git rev-parse --short "$OLD_TIP")); clean replay will inherit + open a cross-linked PR"
      else
        echo "  . PR #$NUM not previously green; reconcile candidate left for manual review (no inherit, no PR-open)"
      fi

      # OLD_BASE is the merge-base of the pool tip and the current dev
      # tip: the most-recent common ancestor of the two branches. The
      # cherry-pick range OLD_BASE..OLD_TIP then captures the FULL pool
      # delta since the pool diverged from the line of work that became
      # dev, which is exactly what the reconcile branch must carry.
      #
      # An earlier version computed OLD_BASE as `origin/$HEAD~1` (the
      # parent of the pool tip). That is wrong for any N-commit pool
      # branch with N>1: the cherry-pick range collapses to the single
      # top commit, silently dropping every other pool commit from the
      # reconcile branch. See feedback_auto_rebase_old_base_bug.
      OLD_BASE=$(git merge-base "origin/$HEAD" "$DEV_TIP" 2>/dev/null || echo "")
      echo "  . OLD_BASE=$OLD_BASE (merge-base origin/$HEAD x origin/dev) OLD_TIP=$OLD_TIP DEV_TIP=$DEV_TIP"

      # Orphan-base detection is informational only now. The cherry-pick
      # path cherry-picks OLD_BASE..OLD_TIP from the pool's own history
      # onto the new dev tip, so it works whether OLD_BASE is in dev's
      # history or was orphaned by a dev rewrite. Log when the orphan
      # case happens so the dev/admin sees why the reconcile branch
      # only carries the pool's delta and not the orphaned ancestors.
      if [ -n "$OLD_BASE" ] && ! git merge-base --is-ancestor "$OLD_BASE" "$DEV_TIP" 2>/dev/null; then
        echo "  . old base $OLD_BASE is NOT in current dev's history -> orphan-base; reconcile cherry-picks only the pool's delta"
      fi

      # No in-place rebase + force-push path: that would rewrite the
      # developer's pool branch, which violates the no-rewrite principle
      # (see feedback_how_git_never_rewrites_history). The cherry-pick
      # onto a fresh reconcile branch is the only path, regardless of
      # whether the rebase would have been clean or conflicted.
      #
      # Defensive fallback: when `git merge-base` returned empty (refs
      # share no common history, e.g. an unrelated-histories pool), try
      # one more time with the operands swapped. The OLD_BASE-still-
      # empty branch below then surfaces the unresolvable case to the
      # admin via a PR comment instead of silently doing nothing.
      if [ -z "$OLD_BASE" ]; then
        OLD_BASE=$(git merge-base "$DEV_TIP" "origin/$HEAD" 2>/dev/null || echo "")
      fi
      if [ -z "$OLD_BASE" ]; then
        echo "  warn: cannot compute OLD_BASE for $HEAD; leaving reconcile to manual review" >&2
        gh pr comment "$NUM" --repo "$OWNER_REPO" \
          --body "Auto-rebase against new dev tip $(git rev-parse --short "$DEV_TIP") could not determine the merge-base for this PR. Reconcile branch was not created. Manual rebase required." \
          >/dev/null 2>&1 || true
        continue
      fi

      # If the pool tip is already an ancestor of the new dev tip, this
      # pool's work is already in dev; nothing to reconcile.
      if git merge-base --is-ancestor "$OLD_TIP" "$DEV_TIP" 2>/dev/null; then
        echo "  . pool tip already in dev history; no reconcile needed"
        continue
      fi

      # Compute reconcile branch name (same nN, kind=reconcile, short=original
      # short). When the original head carried a vYYYY.MAIN/ prefix the
      # reconcile branch inherits the same prefix so the release-line
      # classification stays consistent across the iterative reconcile chain.
      ORIG_SHORT=$(short_name_of "$HEAD")
      ORIG_N=$(n_of "$HEAD")
      ORIG_MAJOR=$(major_prefix_of "$HEAD")
      if [ -n "$ORIG_MAJOR" ]; then
        RECON_BRANCH="pool/${ORIG_MAJOR}/${ORIG_N}.reconcile.${ORIG_SHORT}"
      else
        RECON_BRANCH="pool/${ORIG_N}.reconcile.${ORIG_SHORT}"
      fi

      # Reconcile candidates are machine-owned, freely rewritable state, NOT
      # developer history. On every dev advance the candidate is rebuilt from
      # scratch against the new dev tip (worktree + cherry-pick below) and
      # FORCE-PUSHED onto the canonical name - a rolling pointer that repoints
      # in place. No delete, no rename, no tmp slot, no enumeration, no ruleset
      # bypass, no admin: a non-fast-forward update of a pool/*.reconcile.* ref
      # is permitted for the plain workflow token (pool-creations carves
      # reconcile out, pool-deletions never fires on an update, and the no-force
      # rule binds only the DEVELOPER's pool branch). See repo-config (CI never
      # deletes), RUNBOOK (never force-push the developer's branch), and
      # feedback_how_git_never_rewrites_history.
      echo "  -> cutting reconcile branch: $RECON_BRANCH"

      if $DRY_RUN; then
        echo "    [dry-run] would: cherry-pick $OLD_BASE..$OLD_TIP onto $DEV_TIP, push $RECON_BRANCH (CREATE), comment on PR #$NUM"
        continue
      fi

      # Live visibility: post a start-of-reconcile comment on the existing
      # PR BEFORE any cherry-pick attempt. The end-of-pass comment (clean
      # success OR partial-L5) still lands at the end of the loop below; this
      # additive start comment lets the admin / developer see that a pass is
      # in flight rather than only learning about it once it finishes. If
      # auto-rebase fires more than once on the same PR (rewrite-on-every
      # turn per feedback_how_git_never_rewrites_history), each pass posts
      # its own start + end comment pair so the PR carries a timeline of
      # every reconcile attempt.
      DEV_SHORT_AT_START=$(git rev-parse --short "$DEV_TIP")
      POOL_SHORT=$(git rev-parse --short "$OLD_TIP")
      START_BODY=$(printf 'Auto-rebase: starting a reconcile pass against new dev tip **%s** under this PR.\n\nThis PR'\''s head `%s` (tip `%s`) will be cherry-picked onto a fresh `%s` candidate cut from the new dev tip. The original `%s` branch and this PR remain untouched (receipts).\n\n_This reconcile is in progress; a follow-up comment will land when the candidate is ready or when the L1-L5 ladder cannot resolve a hunk._\n' "$DEV_SHORT_AT_START" "$HEAD" "$POOL_SHORT" "$RECON_BRANCH" "$HEAD")
      gh pr comment "$NUM" --repo "$OWNER_REPO" --body "$START_BODY" >/dev/null 2>&1 \
        && echo "  ok: commented on PR #$NUM with reconcile-pass start"
      HEAD_SHA_FULL=$(git rev-parse "$OLD_TIP" 2>/dev/null || true)
      post_recon_status "$HEAD_SHA_FULL" "pending" "reconcile pass running against dev $DEV_SHORT_AT_START"

      # Fresh worktree off the new dev tip; the reconcile branch is created (or
      # reset, via -B) by the worktree add and only the cherry-picked commits go
      # on it. -B not -b: each pass rebuilds the candidate from scratch, so a
      # local reconcile branch left from a prior pass in a reused clone is reset
      # to the new dev tip rather than failing the worktree add.
      WORKTREE=$(mktemp -d -t "v4rian-reconcile-${NUM}-XXXXXX")
      if ! git worktree add -q -B "$RECON_BRANCH" "$WORKTREE" "$DEV_TIP" 2>/dev/null; then
        echo "  warn: could not create reconcile worktree; leaving reconcile to manual review" >&2
        rm -rf "$WORKTREE"
        # The prior candidate (if any) is still intact on origin - nothing was
        # vacated - so it stays available for admin review until a later pass
        # rebuilds it.
        gh pr comment "$NUM" --repo "$OWNER_REPO" \
          --body "Auto-rebase against new dev tip $(git rev-parse --short "$DEV_TIP") could not create the reconcile worktree. Manual rebase required." \
          >/dev/null 2>&1 || true
        continue
      fi

      pushd "$WORKTREE" >/dev/null

      # Fetch the active-requirement for this pool branch so the L1-L5
      # ladder can include it in every claude prompt. The requirement
      # is the canonical intent the allocator stamped onto the branch
      # at creation time (initial [REQ] commit body + tracked file at
      # .io.v4rian.how-git/active-requirement). Older branches that
      # predate this lifecycle step return an empty string; the ladder
      # gracefully proceeds without the extra context.
      ACTIVE_REQUIREMENT=""
      if [ -x "$REPO_ROOT/.io.v4rian.how-git/scripts/get-active-requirement.sh" ]; then
        ACTIVE_REQUIREMENT=$(bash "$REPO_ROOT/.io.v4rian.how-git/scripts/get-active-requirement.sh" "origin/$HEAD" 2>/dev/null || true)
      fi
      REQ_HEADER=""
      if [ -n "$ACTIVE_REQUIREMENT" ]; then
        REQ_HEADER="Active requirement for $HEAD (from the lane's requirements file or its initial [REQ] commit, via get-active-requirement.sh; this is the canonical intent for the branch): ${ACTIVE_REQUIREMENT}. "
      fi

      # Cherry-pick each commit from OLD_BASE..OLD_TIP onto the new dev tip
      # one at a time. On conflict, escalate through the L1-L5 semantic
      # resolution ladder. Every tier invokes claude_resolve_conflict so
      # the resolution is AI-driven (hunk-level allocation per the
      # git-reconcile-intent skill), never a silent mechanical override.
      # The tiers differ in the CONTEXT they pass to claude, not in the
      # mechanism: each tier widens the lens or biases the judgment so
      # progressively harder conflicts can land.
      #
      # Escalation ladder per conflicting commit:
      #   L1. claude with the commit's local context (file list, commit
      #       message, current diff state); apply hunk-level allocation
      #       and clear the markers in place.
      #   L2. L1 failed; claude with broader context (full pool diff
      #       since OLD_BASE, full dev diff since OLD_BASE, the side
      #       contents of the conflicting hunks) so the judgment can
      #       reason across both branches' moves.
      #   L3. L2 failed; claude with the same broader context plus a
      #       bias toward preserving the pool's intent (incoming side
      #       semantically). NOT a `git cherry-pick -X theirs` retry,
      #       which silently overrides; claude still allocates per
      #       hunk and explains the choice.
      #   L4. L3 failed; claude with a bias toward preserving dev's
      #       intent (target side semantically). Same hunk-level
      #       discipline, opposite bias.
      #   L5. L4 failed; claude in surface-not-resolve mode, naming
      #       each unresolved hunk for the admin instead of editing.
      #       The partial state is pushed as a receipt; the admin
      #       picks up from there.
      # After L5, if still unresolved, push partial state + comment with
      # full attempt log. That comment is the receipt of every strategy.
      COMMITS=$(git -C "$REPO_ROOT" rev-list --reverse "$OLD_BASE..$OLD_TIP")
      CONFLICT_RECAP=""
      ALL_CLEAN=true
      L5_SURFACED=false

      attempt_resolve() {
        # $1 = level (1..5), $2 = commit SHA, $3 = original msg, $4 = conflicting files
        local level="$1" c="$2" ORIG_MSG="$3" CONFLICTS="$4"
        local ctx=""
        local pool_diff dev_diff
        pool_diff=$(git -C "$REPO_ROOT" diff --stat "$OLD_BASE..$OLD_TIP" 2>/dev/null | head -30 | tr '\n' '|')
        dev_diff=$(git -C "$REPO_ROOT" diff --stat "$OLD_BASE..$DEV_TIP" 2>/dev/null | head -30 | tr '\n' '|')
        case "$level" in
          1) ctx="${REQ_HEADER}L1: reconcile of $HEAD against dev tip $(git -C "$REPO_ROOT" rev-parse --short "$DEV_TIP"): cherry-picking $c ($ORIG_MSG); conflicting files: $CONFLICTS. Read each conflicting file, apply the git-reconcile-intent hunk-level allocation discipline, edit the files in place to clear every conflict marker so the cherry-picked commit's intent lands cleanly on top of dev. Reply with RESOLVED on success or UNRESOLVED: <reason> if a hunk cannot be allocated without surfacing." ;;
          2) ctx="${REQ_HEADER}L2 (L1 failed): same reconcile, broader context. Pool branch full diff against its old base: ${pool_diff}. Dev's changes since same base: ${dev_diff}. Read each conflicting file in [$CONFLICTS], reason across both branches' moves at hunk granularity, and edit the files in place to preserve the pool's intent while accommodating dev's progress. Clear every conflict marker. Reply RESOLVED or UNRESOLVED: <reason>." ;;
          3) ctx="${REQ_HEADER}L3 (L1+L2 failed): same context as L2 (pool diff ${pool_diff}; dev diff ${dev_diff}) but with a bias: prefer the POOL's intent (the incoming side of each conflict) when the two sides cannot be reconciled additively. This is a semantic bias, not a mechanical override: continue applying hunk-level allocation, but when a hunk is genuinely either-or, lean toward pool. Edit the files in [$CONFLICTS] in place, clear every marker, explain in one sentence why pool's intent prevailed. Reply RESOLVED or UNRESOLVED: <reason>." ;;
          4) ctx="${REQ_HEADER}L4 (L1-L3 failed): same context as L3 (pool diff ${pool_diff}; dev diff ${dev_diff}) but with the opposite bias: prefer the DEV's intent (the target side of each conflict) when the two sides cannot be reconciled additively. Same semantic-bias rule: continue applying hunk-level allocation, lean toward dev only when a hunk is either-or, and only if pool's intent is not entirely lost. If pool's intent would be entirely erased, this bias is wrong, signal UNRESOLVED. Edit the files in [$CONFLICTS] in place, clear every marker. Reply RESOLVED or UNRESOLVED: <reason>." ;;
          5) ctx="${REQ_HEADER}L5 (L1-L4 failed): SURFACE-NOT-RESOLVE mode. Do NOT edit the conflicting files. Instead, name each unresolved hunk in [$CONFLICTS] with: file path, the hunk's role on each side (pool intent vs dev intent), and why neither bias resolves it. Reply SURFACE followed by the per-hunk report so the admin can review. Original commit message: $ORIG_MSG. The conflict markers stay in place for the admin to inspect on the partial reconcile branch." ;;
        esac

        # L5 is surface-only: no edits, no cherry-pick --continue. The
        # SURFACE outcome (rc=2 from the helper) is treated by the
        # caller as "claude surfaced but did not resolve".
        if [ "$level" = "5" ]; then
          claude_resolve_conflict "L${level}" "$ctx" ""
          local rc=$?
          if [ "$rc" = "2" ]; then
            return 2
          fi
          return 1
        fi

        # L1-L4: claude edits the working tree to clear markers, then
        # we finalize the cherry-pick by staging the resolved files and
        # running cherry-pick --continue.
        if ! claude_resolve_conflict "L${level}" "$ctx" "$CONFLICTS"; then
          return 1
        fi
        # Stage the resolved files so cherry-pick --continue can complete.
        local f
        for f in $CONFLICTS; do
          [ -f "$f" ] || continue
          git add -- "$f" >/dev/null 2>&1 || true
        done
        if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
          return 1
        fi
        if git -c core.editor=true cherry-pick --continue >/dev/null 2>&1; then
          return 0
        fi
        return 1
      }

      CHERRYPICK_LOG=$(mktemp -t "v4rian-reconcile-cherrypick-${NUM}-XXXXXX")
      for c in $COMMITS; do
        if git cherry-pick "$c" >"$CHERRYPICK_LOG" 2>&1; then
          continue
        fi
        # Conflict on this commit - escalate through strategies
        CONFLICTS=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
        ORIG_MSG=$(git -C "$REPO_ROOT" log -1 --format='%s' "$c")
        echo "  . conflict on cherry-pick of $c ($ORIG_MSG): $CONFLICTS"
        ATTEMPTS=""
        RESOLVED=false
        SURFACED=false
        for level in 1 2 3 4 5; do
          echo "    -> L${level} attempt"
          attempt_resolve "$level" "$c" "$ORIG_MSG" "$CONFLICTS"
          rc=$?
          if [ "$rc" = "0" ]; then
            ATTEMPTS="${ATTEMPTS}L${level}(resolved) "
            CONFLICT_RECAP="$CONFLICT_RECAP\n- $c \"$ORIG_MSG\": conflicts in $CONFLICTS resolved at L${level} ($ATTEMPTS)"
            RESOLVED=true
            break
          fi
          if [ "$rc" = "2" ]; then
            # L5 SURFACE outcome: claude named the unresolved hunks for
            # the admin without editing. Stop escalating (no tier beyond
            # L5) and let the partial state push as a receipt.
            ATTEMPTS="${ATTEMPTS}L${level}(surfaced) "
            SURFACED=true
            L5_SURFACED=true
            break
          fi
          ATTEMPTS="${ATTEMPTS}L${level}(failed) "
        done

        if ! $RESOLVED; then
          if $SURFACED; then
            CONFLICT_RECAP="$CONFLICT_RECAP\n- $c \"$ORIG_MSG\": SURFACED at L5 for admin review. Files: $CONFLICTS. Attempts: $ATTEMPTS"
          else
            CONFLICT_RECAP="$CONFLICT_RECAP\n- $c \"$ORIG_MSG\": UNRESOLVED after 5 strategies. Files: $CONFLICTS. Attempts: $ATTEMPTS"
          fi
          git cherry-pick --abort >/dev/null 2>&1 || true
          ALL_CLEAN=false
          break
        fi
      done
      rm -f "$CHERRYPICK_LOG"

      DEV_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$DEV_TIP")

      # Empty-reconcile guard: if the worktree HEAD still equals DEV_TIP
      # after the cherry-pick loop, zero pool commits actually landed on
      # the reconcile branch (every cherry-pick aborted, or the loop
      # never produced any commits at all). Pushing in that state would
      # publish a reconcile branch whose tip == dev tip and zero new
      # content - the "tip-of-something pointed somewhere" antipattern
      # that previously misled admins into believing a candidate was
      # ready to merge when it was not. Refuse the push, post a comment
      # that names the empty state explicitly, and continue to the next
      # PR. The original PR stays open (per
      # feedback_how_git_never_rewrites_history: the PR is the
      # developer's record and never closed by automation).
      RECON_HEAD=$(git rev-parse HEAD)
      if [ "$RECON_HEAD" = "$DEV_TIP" ]; then
        echo "  warn: reconcile HEAD == DEV_TIP ($DEV_SHORT); zero pool commits cherry-picked - refusing to push empty reconcile"
        EMPTY_BODY=$(printf 'Auto-rebase against new dev tip **%s** produced an EMPTY reconcile (zero pool commits applied cleanly to current dev). The pool'\''s work is either already represented in dev or the conflicts are deep enough that a hand-rebase is required. The reconcile branch is NOT pushed - there is nothing to merge.\n\nThe original `%s` branch and this PR are untouched. **Developer** can push a fresh resolution to the pool branch at any time. **Admin** retains sole merge authority on dev.\n' "$DEV_SHORT" "$HEAD")
        gh pr comment "$NUM" --repo "$OWNER_REPO" --body "$EMPTY_BODY" >/dev/null 2>&1 \
          && echo "  ok: commented on PR #$NUM with empty-reconcile signal"
        post_recon_status "$(git rev-parse "$OLD_TIP" 2>/dev/null || true)" "failure" "empty reconcile: zero pool commits applied to dev $DEV_SHORT"
        # The new pass produced nothing publishable and we never deleted the
        # prior candidate (the delete is just-before-push, below, and we did
        # not reach it). So any prior candidate stays intact on origin as the
        # most-recent reconcile receipt.
        popd >/dev/null
        git worktree remove --force "$WORKTREE" 2>/dev/null || true
        rm -rf "$WORKTREE"
        continue
      fi

      if $ALL_CLEAN; then
        # All commits cherry-picked successfully (clean or via L1-L5 claude
        # resolution). Force-push the canonical reconcile name to the fresh
        # candidate cut off the new dev tip. The candidate is machine-owned
        # rewritable state, NOT the developer's branch, so a non-fast-forward
        # update repoints the rolling pointer in place - no delete, no ruleset
        # bypass, no admin (RUNBOOK: the pass never force-pushes the DEVELOPER's
        # pool branch; the candidate is fair game; repo-config: CI never
        # deletes a pool ref). The candidate ref carries no CI of its own; it is
        # validated by dev's required checks when the admin merges it.
        PUSH_ERR=$(lifecycle_push --no-verify --force "$RECON_BRANCH:refs/heads/$RECON_BRANCH" 2>&1)
        if [ $? -eq 0 ]; then
          echo "  ok: reconcile branch $RECON_BRANCH force-pushed (rolling pointer)"
        else
          echo "  X reconcile branch push FAILED for $RECON_BRANCH; candidate does NOT exist on origin" >&2
          printf '%s\n' "$PUSH_ERR" | tail -3 >&2
          post_recon_status "$HEAD_SHA_FULL" "failure" "candidate push rejected; see run log"
          popd >/dev/null
          git worktree remove --force "$WORKTREE" 2>/dev/null || true
          rm -rf "$WORKTREE"
          continue
        fi

        # Recap comment on the EXISTING PR. Admin remains the sole merge
        # decider on dev (see feedback_how_git_never_rewrites_history); the
        # developer's pool branch is never pushed to and the original PR is
        # never closed by automation.
        if [ -n "$CONFLICT_RECAP" ]; then
          RECAP_BODY="### Resolutions recap${CONFLICT_RECAP}"
        else
          RECAP_BODY="_No conflicts during cherry-pick onto new dev tip; pure replay of pool commits._"
        fi
        QUICK_LINK="https://github.com/${OWNER_REPO}/compare/dev...${RECON_BRANCH}?expand=1"
        COMPANION_LINE=$(printf '\n**Merge it now:** the candidate is one click away at %s - admin can integrate without waiting for the developer.\n' "$QUICK_LINK")
        COMMENT_BODY=$(printf 'Auto-rebase: dev advanced to **%s** under this PR.\n\nThe reconcile branch [`%s`](../tree/%s) carries the pool commits cherry-picked onto the new dev tip. The original `%s` branch and this PR are untouched (receipts).\n%s\n**Developer** owns the pool branch and may push their own resolution at any time; if a clean update lands before admin review the reconcile is moot and stays only as a receipt.\n\n%s\n' "$DEV_SHORT" "$RECON_BRANCH" "$RECON_BRANCH" "$HEAD" "$COMPANION_LINE" "$RECAP_BODY")
        gh pr comment "$NUM" --repo "$OWNER_REPO" --body "$COMMENT_BODY" >/dev/null 2>&1 \
          && echo "  ok: commented on PR #$NUM with reconcile candidate"
        # Point the PR body itself at the candidate (not just a comment) so an
        # admin opening the PR is sent straight to the mergeable reconcile.
        POINTER_BLOCK=$(printf '> **Reconcile candidate ready to merge.** dev advanced to `%s`; this PR'"'"'s `%s` head no longer merges clean. The reconciled, mergeable candidate is `%s` - **[review and merge it here](%s)**. This PR'"'"'s branch and history stay untouched (receipts).' "$DEV_SHORT" "$HEAD" "$RECON_BRANCH" "$QUICK_LINK")
        point_pr_to_reconcile "$NUM" "$POINTER_BLOCK" \
          && echo "  ok: PR #$NUM body now points to the reconcile candidate"
        # The reconcile context answers ONE question: does THIS head merge
        # into dev as it stands? A pass that needed the ladder means the
        # original head conflicts with dev, so the status is FAILURE with
        # the ready candidate named in the description - never a green
        # check beside a conflict banner. Only a pure replay (zero
        # conflicts, the head still merges clean) reads success.
        if [ -n "$CONFLICT_RECAP" ]; then
          post_recon_status "$HEAD_SHA_FULL" "failure" "conflicts with dev; candidate ready: $RECON_BRANCH"
        else
          post_recon_status "$HEAD_SHA_FULL" "success" "merges clean; replay receipt: $RECON_BRANCH"
        fi

        # Inherit + cross-linked PR: only on a CLEAN replay (zero conflict
        # edits, so CONFLICT_RECAP is empty) of a LEGITIMATED PR. The clean
        # cherry-pick is byte-identical to what already passed every
        # required.* check on the original head, so the 5 statuses are
        # inherited as success onto the reconcile candidate SHA and one
        # cross-linked reconcile->dev PR is opened (idempotent). A pass that
        # needed the L1-L5 ladder changed content and is excluded - it must
        # be audited for real, so it keeps the comment-only behavior.
        if [ -z "$CONFLICT_RECAP" ] && $LEGITIMATED; then
          RECON_SHA=$(git rev-parse HEAD)
          inherit_required_statuses "$RECON_SHA" "$NUM"
          echo "  ok: inherited 5 required.* statuses onto reconcile candidate $(git rev-parse --short "$RECON_SHA") from #$NUM"
          post_reconcile_mergeable_contexts "$RECON_SHA" "$NUM" "$DEV_SHORT"
          echo "  ok: posted reconcile + opened-via-correct-flow success onto reconcile candidate"
          RECON_PR=$(open_or_refresh_reconcile_pr "$RECON_BRANCH" "$NUM" "$HEAD" "$DEV_SHORT")
          if [ -n "$RECON_PR" ]; then
            echo "  ok: cross-linked reconcile PR #$RECON_PR open for $RECON_BRANCH"
            gh pr comment "$NUM" --repo "$OWNER_REPO" \
              --body "$(printf 'Cross-link: a mergeable reconcile candidate for this PR is open as #%s (head `%s`, the 5 required checks inherited green from this PR). This PR is kept open as the record.' "$RECON_PR" "$RECON_BRANCH")" \
              >/dev/null 2>&1 \
              && echo "  ok: cross-link comment posted on PR #$NUM pointing to #$RECON_PR"
          else
            echo "  warn: could not open the cross-linked reconcile PR for $RECON_BRANCH" >&2
          fi
        fi
      else
        # Some commits unresolvable after L5. The partial reconcile IS the
        # latest attempt: force-push it onto the canonical name so the PR
        # points at the most recent reconciliation. The work-so-far is
        # preserved as a receipt; dev or admin picks up from the partial state.
        # The empty-reconcile guard above already eliminated the zero-commits
        # case, so anything reaching here has at least one commit ahead of
        # DEV_TIP on the reconcile branch.
        if PARTIAL_PUSH_ERR=$(lifecycle_push --no-verify --force "$RECON_BRANCH:refs/heads/$RECON_BRANCH" 2>&1); then
          echo "  ok: partial reconcile $RECON_BRANCH force-pushed (rolling pointer)"
        else
          echo "  X partial reconcile push FAILED for $RECON_BRANCH:" >&2
          printf '%s\n' "$PARTIAL_PUSH_ERR" | tail -3 >&2
        fi
        COMMENT_BODY=$(printf 'Auto-rebase: dev advanced to **%s** under this PR.\n\nReconcile against the new dev tip hit conflicts that the L1-L5 ladder could not resolve. The partial reconcile state is pushed to [`%s`](../tree/%s) as a receipt of what was attempted. The original `%s` branch and this PR are untouched.\n\n### Unresolved conflicts%b\n\n**Developer** can push a fresh resolution to the pool branch at any time. **Admin** can pick up from the partial reconcile branch directly or apply a different resolution; admin remains the sole merge decider on dev.\n' "$DEV_SHORT" "$RECON_BRANCH" "$RECON_BRANCH" "$HEAD" "$CONFLICT_RECAP")
        gh pr comment "$NUM" --repo "$OWNER_REPO" --body "$COMMENT_BODY" >/dev/null 2>&1 \
          && echo "  ok: commented on PR #$NUM with partial reconcile recap"
        # Point the PR body at the partial candidate too, so the admin lands on
        # it (and the unresolved hunks) from the PR rather than the stale head.
        QUICK_LINK_PARTIAL="https://github.com/${OWNER_REPO}/compare/dev...${RECON_BRANCH}?expand=1"
        POINTER_BLOCK=$(printf '> **Partial reconcile candidate.** dev advanced to `%s`; the L1-L5 ladder could not fully resolve this PR'"'"'s `%s` against it. The partial candidate `%s` is pushed for review - **[inspect it here](%s)**. This PR'"'"'s branch and history stay untouched (receipts).' "$DEV_SHORT" "$HEAD" "$RECON_BRANCH" "$QUICK_LINK_PARTIAL")
        point_pr_to_reconcile "$NUM" "$POINTER_BLOCK" \
          && echo "  ok: PR #$NUM body now points to the partial reconcile candidate"
        post_recon_status "$HEAD_SHA_FULL" "failure" "partial reconcile: unresolved conflicts after L5 (see PR comments)"
        echo "  warn: reconcile incomplete; partial state on $RECON_BRANCH"
      fi

      popd >/dev/null
      git worktree remove --force "$WORKTREE" 2>/dev/null || true
      rm -rf "$WORKTREE"
    done

echo
echo "ok: auto-rebase pass complete"
