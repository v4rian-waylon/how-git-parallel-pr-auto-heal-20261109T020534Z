#!/usr/bin/env bash
# apply-repo-rules.sh - apply v4rian branch protection and Repository Rules
# to a GitHub repo via the `gh` CLI. Idempotent. Self-contained.
#
# Run:
#   ./scripts/apply-repo-rules.sh
#
# Self-contained contract (no required env var ceremony):
#   ORG / REPO              derived from `git config --get remote.origin.url`.
#                           Override with the same-named env var only when
#                           targeting a different repo than origin.
#   gh CLI                  auto-installed via brew on macOS when missing;
#                           Linux install hints surfaced to the operator
#                           (workspace no-root-access rule: no sudo from
#                           scripts). gh auth status is verified before any
#                           ruleset POST.
#   python3                 auto-installed via brew on macOS when missing;
#                           Linux install hints surfaced.
#
# Every precondition failure surfaces as a visible banner on STDOUT (not
# STDERR) so operators piping through pagers or stderr-swallowing terminals
# still see the actionable text. See docs/repo-config.md for the full set of
# rules and the verification checklist.

set -euo pipefail

# Announce-upfront: even if every subsequent command silent-fails, the
# operator sees the script started. Origin is resolved with explicit
# fallback so the message works outside a git repo (verify-template
# throwaway clones, fresh framework-tests). Pure bash 3.2 + POSIX.
_apply_origin=$(git config --get remote.origin.url 2>/dev/null || true)
if [ -z "$_apply_origin" ]; then
  _apply_origin_short='<no origin>'
else
  _apply_origin_short=$(printf '%s' "$_apply_origin" \
    | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
fi
echo "→ apply-repo-rules starting on $_apply_origin_short"

# Loud-on-failure EXIT trap per the silence-is-success-in-sh-land rule.
# Only fires when the script exits non-zero; intentional `exit 0`
# (or the implicit success exit) prints nothing so successful runs
# stay silent. Bash 3.2 LINENO inside a trap is unreliable so it is
# omitted; $BASH_COMMAND carries the last command which is enough to
# point the operator at the failing site.
trap '_rc=$?; if [ "$_rc" -ne 0 ]; then printf "\nX %s exited with status %d (last command: %s)\n" "$(basename "$0")" "$_rc" "$BASH_COMMAND" >&2; fi' EXIT

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# Off-grid repos do not run on GitHub-style Repository Rules. Refuse here
# so an admin does not accidentally apply rules against a remote the repo
# no longer considers authoritative. Routed through the precondition banner
# so the refusal is visible regardless of stderr handling. get_mode's only
# failure mode is "no git repo" which surfaces from the upstream
# git rev-parse and would have already broken the caller; defaulting to
# "connected" here is the conservative read-the-MODE-file fallback.
MODE_VAL=$(get_mode 2>/dev/null || echo "connected")
if [ "$MODE_VAL" = "off-grid" ]; then
  precondition_banner "apply-repo-rules" \
    "Repo is in off-grid mode; Repository Rules do not apply." \
    "Off-grid governance lives in admins.txt plus local hooks; remote rulesets are inert." \
    "Flip back to connected first if this repo is rejoining a GitHub remote:" \
    "  bin/set-mode connected"
  exit 2
fi

# Ensure the CLI deps we use are present before we try anything that needs
# them. ensure_dep emits its own banner on failure so the script's exit path
# is uniform.
ensure_dep gh || exit 2
ensure_dep python3 || exit 2
ensure_gh_auth || exit 2

# ---- inputs (ORG + REPO default to origin) ----
DEFAULT_OWNER_REPO=$(git config --get remote.origin.url 2>/dev/null \
  | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
ORG="${ORG:-${DEFAULT_OWNER_REPO%%/*}}"
REPO="${REPO:-${DEFAULT_OWNER_REPO##*/}}"

if [[ -z "$ORG" || -z "$REPO" || "$ORG" = "$REPO" ]]; then
  precondition_banner "apply-repo-rules" \
    "Cannot derive ORG/REPO from origin URL." \
    "Set the env vars explicitly or run from a repo with a configured origin:" \
    "  ORG=<owner> REPO=<name> bash $0"
  exit 2
fi

REPO_FULL="$ORG/$REPO"
RULESETS_DIR="$SCRIPT_DIR/../rulesets"

# Up-front visibility/plan probe. Repository Rules are available on every
# public repo regardless of plan, and on private repos under team, business,
# or enterprise (orgs) / pro, business, enterprise (users). The legacy
# inline check only matched the "GitHub Pro" string returned for free-tier
# users, missing Teams orgs (the canonical v4rian deployment shape). The
# helper reads /repos/<owner>/<repo>'s visibility plus the owning account's
# plan and decides whether to even attempt the ruleset POSTs.
#
# Soft-fail: when the helper cannot determine support (token lacks org-read
# scope, API hiccup, unknown plan name), we still attempt the POSTs and
# surface the actual HTTP error so the operator sees the ground truth
# rather than a guess. The helper's "no" only short-circuits when we can
# positively rule support out.
# Capture the rulesets-support probe's stderr through run_capture_stderr
# so the operator sees the underlying API failure (404 on /repos lookup,
# scope denial, rate limit) on STDOUT rather than a generic "could not
# confirm" line that buries the real cause. The probe's positive result
# is the empty-stdout convention used by repo_supports_rulesets; only
# the exit code distinguishes "supported" from "not supported".
echo "→ probing repo capabilities (visibility + plan)"
RULESET_PROBE_STDOUT=""
RULESET_PROBE_ERR=""
RULESET_PROBE_RC=0
run_capture_stderr RULESET_PROBE_STDOUT RULESET_PROBE_ERR RULESET_PROBE_RC \
  -- repo_supports_rulesets "$ORG" "$REPO"
if [ "$RULESET_PROBE_RC" -eq 0 ]; then
  RULESET_PROBE_OK=true
else
  RULESET_PROBE_OK=false
fi

echo "  · preflight OK"
echo ""
echo "→ applying rules to $REPO_FULL"
if ! $RULESET_PROBE_OK; then
  echo "  · could not confirm ruleset support up-front (probe rc=$RULESET_PROBE_RC); will attempt POSTs and surface API errors verbatim"
  if [ -n "$RULESET_PROBE_ERR" ]; then
    # Indent each captured line by two spaces under the probe note so it
    # threads cleanly with the rest of the banner-free progress lines.
    printf '%s\n' "$RULESET_PROBE_ERR" | sed 's/^/    · /'
  fi
fi
echo ""

# Helper: PUT a branch-protection payload and surface the raw API
# response on failure through a precondition banner. Without this wrap
# the underlying `gh api -X PUT ... >/dev/null` would let stderr flow
# to the terminal naturally but vanish when the operator runs the
# script through `2>/dev/null`; the banner emits to STDOUT so the
# failure is visible regardless of stderr handling.
put_branch_protection() {
  local label="$1" branch="$2"
  shift 2
  local resp err rc
  run_capture_stderr resp err rc -- gh api -X PUT "repos/$REPO_FULL/branches/$branch/protection" "$@"
  if [ "$rc" -ne 0 ]; then
    local err_line="(no stderr emitted by gh)"
    if [ -n "$err" ]; then
      err_line=$(printf '%s' "$err" | sed 's/^/  /')
    fi
    local resp_line="(empty response body)"
    if [ -n "$resp" ]; then
      resp_line=$(printf '%s' "$resp" | sed 's/^/  /')
    fi
    precondition_banner "apply-repo-rules" \
      "Branch protection PUT failed for $label on $REPO_FULL." \
      "Probable causes:" \
      "  - the branch does not exist yet (push the first commit to $branch first)" \
      "  - the token lacks the 'administration' permission on the repo" \
      "  - the repo is archived" \
      "  - a private repo on a free plan (GitHub answers 'Upgrade to GitHub Pro')" \
      "    branch protection needs a public repo or a Pro/Team plan; otherwise" \
      "    run the repo off-grid: bin/set-mode off-grid" \
      "" \
      "Captured stderr from gh (rc=$rc):" \
      "$err_line" \
      "" \
      "Captured stdout from gh:" \
      "$resp_line"
    return 1
  fi
  return 0
}

# --- main branch protection ---
# 'doc-freshness' is the PR-open gate emitted by
# .github/workflows/doc-freshness.yml that compares the dev → main diff
# substance against the user-facing docs (CHANGELOG, RUNBOOK,
# CONTRIBUTING, READMEs). Binding it as a required context here means
# a release cannot land while the docs lag the diff.
echo "→ main branch protection"
put_branch_protection "main branch protection" "main" \
  --field "required_status_checks[strict]=true" \
  --field "required_status_checks[contexts][]=release" \
  --field "required_status_checks[contexts][]=doc-freshness" \
  --field "enforce_admins=true" \
  --field "required_pull_request_reviews[required_approving_review_count]=1" \
  --field "required_pull_request_reviews[dismiss_stale_reviews]=true" \
  --field "restrictions=null" \
  --field "allow_force_pushes=false" \
  --field "allow_deletions=false" \
  || exit 2
echo "  ✓ main protected (release, doc-freshness required)"

# --- dev branch protection ---
# The async audits and tests emitted by .github/workflows/ci-dispatch.yml on
# the pr-open trigger are required for any PR merge to dev. Names match the
# required.*.sh basenames (minus .sh) under
# .io.v4rian.how-git/ci/{tests,audits}/pr-open/ verbatim.
#
# allow_force_pushes is true on dev (and only dev) because the post-merge claim
# flow (claim-dev-merge.sh) amends the just-landed merge commit into spec format
# - rewriting the committer to the CI identity and the subject to
# [MERGE] <source> into dev: vYYYY.SERIES.DEV - which produces a new SHA that
# must be force-pushed over the GitHub merge commit before the dev tag is placed
# on it. With allow_force_pushes=false GitHub rejects that push with GH006
# ("Cannot force-push to this branch"); the claim then cannot seal the version
# on the dev line (the v2026.0.99 incident, 2026-05-28). Permitting the
# force-push restores the spec-format dev tip plus tag-on-dev-tip behavior. This
# is not a developer-facing relaxation: developers never hold write access to
# dev (they work on allocator-created pool/* branches and merge via PR, still
# gated by the required status checks above and the pool, safety, and vault
# lockdown rulesets); force-push is exercised only by the privileged claim flow
# and the repo admin. main keeps allow_force_pushes=false - releases never amend
# main.
echo "→ dev branch protection"
put_branch_protection "dev branch protection" "dev" \
  --field "required_status_checks[strict]=true" \
  --field "required_status_checks[contexts][]=required.commit-audit" \
  --field "required_status_checks[contexts][]=required.compile" \
  --field "required_status_checks[contexts][]=required.coverage" \
  --field "required_status_checks[contexts][]=required.runtime" \
  --field "required_status_checks[contexts][]=required.offline-test-suites" \
  --field "required_status_checks[contexts][]=reconcile" \
  --field "enforce_admins=true" \
  --field "required_pull_request_reviews=null" \
  --field "restrictions=null" \
  --field "allow_force_pushes=true" \
  --field "allow_deletions=false" \
  || exit 2
echo "  ✓ dev protected (required.commit-audit, required.compile, required.coverage, required.runtime, required.offline-test-suites, reconcile required; force-push permitted for the claim amend)"

apply_ruleset_from_file() {
  local label="$1"
  local src="$2"
  local out
  out=$(mktemp -t "v4rian-ruleset-XXXXXX")
  # Drop the human comment field so the GitHub API does not choke on the
  # unknown key, and append the OrganizationAdmin escape hatch where a
  # bypass list exists. When the CI bot App is installed on the repo
  # (truth-from-state probe below, resolved once before the apply loop),
  # its Integration actor is appended too, so the claim's protected
  # pushes ride the App installation token in CI; GitHub accepts custom
  # GitHub Apps as ruleset bypass actors from any source (the rejection
  # that retired the old machinery was specific to the built in
  # github-actions integration). Without the App, admins remain the only
  # bypass and the claim hands protected transitions to
  # bin/post-merge-lifecycle. Rulesets whose bypass list is intentionally
  # empty (e.g. required status checks nothing should ever bypass) keep
  # their empty bypass_actors instead of having anything injected.
  python3 -c '
import json, sys
src, dst, app_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    obj = json.load(f)
obj.pop("_comment", None)
existing = obj.get("bypass_actors")
if existing is None:
    obj["bypass_actors"] = [
        {"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always"},
    ]
else:
    if not any(b.get("actor_type") == "OrganizationAdmin" for b in existing):
        existing.append({"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always"})
    if app_id.isdigit() and not any(b.get("actor_type") == "Integration" for b in existing):
        existing.append({"actor_id": int(app_id), "actor_type": "Integration", "bypass_mode": "always"})
with open(dst, "w") as f:
    json.dump(obj, f, indent=2)
' "$src" "$out" "${CI_BOT_APP_ID_EFFECTIVE:-}"
  echo "→ $label"
  local resp
  local rc=0
  resp=$(gh api -X POST "repos/$REPO_FULL/rulesets" --input "$out" 2>&1) || rc=$?
  rm -f "$out"
  if [ "$rc" -eq 0 ]; then
    echo "  ✓ created"
  elif printf '%s' "$resp" | grep -qE "GitHub Pro|upgrade|not available"; then
    # The API returns the GitHub Pro string when the underlying account's
    # plan cannot enable Repository Rules. Surface the plan we detected
    # (when known) so the operator knows whether to upgrade the user
    # account or the org plan. Routed through the precondition banner so
    # the error survives stderr-swallowing terminals. The plan lookup is
    # captured via run_capture_stderr so a token-scope-missing failure
    # explains why we say "(unknown)" instead of silently dropping it.
    local detected_plan="(unknown)" plan_err="" plan_rc=0
    run_capture_stderr detected_plan plan_err plan_rc \
      -- get_org_plan_name "$ORG"
    if [ -z "$detected_plan" ]; then
      detected_plan="(unknown)"
    fi
    local plan_err_line="(no stderr emitted by gh)"
    if [ -n "$plan_err" ]; then
      plan_err_line=$(printf '%s' "$plan_err" | sed 's/^/  /')
    fi
    precondition_banner "apply-repo-rules" \
      "Repository Rules are not available on $REPO_FULL." \
      "Detected plan for $ORG: $detected_plan" \
      "Supported: public repos on any plan; private repos on org plans" \
      "  team, business, or enterprise (orgs) /" \
      "  pro, business, or enterprise (users)." \
      "" \
      "Branch protection (the legacy layer) still applies; the ruleset" \
      "layer stays inert. Upgrade the plan or make the repo public, then" \
      "re-run this script. Run bin/lockdown for an exit-coded check." \
      "" \
      "Plan lookup stderr (rc=$plan_rc):" \
      "$plan_err_line" \
      "" \
      "Raw API response:" \
      "  $resp"
    return 1
  elif printf '%s' "$resp" | grep -qiE "name already exists|Name must be unique"; then
    echo "  · ruleset already present (use bin/lockdown to update in place)"
  elif printf '%s' "$resp" | grep -qiE "ruleset source must be in an organization|must be in an organization"; then
    # Repository rulesets sourced from an organization (the pool/* creation
    # restriction and the lockdown set) require the repo to live in an org;
    # GitHub rejects the POST with 422 "ruleset source must be in an
    # organization" on a personal-account repo. Branch protection (the
    # legacy layer) already applied above, so skip the org-only ruleset and
    # continue rather than aborting the whole bootstrap. Production repos
    # live in the org where these rulesets do apply; this skip only relaxes
    # personal-account throwaways used to exercise the claim and reconcile
    # flow end to end. See feedback_actions_pr_create_permission.
    echo "  · skipped ($label is an org-sourced ruleset; $REPO_FULL is not in an organization)"
  else
    precondition_banner "apply-repo-rules" \
      "Ruleset apply failed for $label on $REPO_FULL." \
      "" \
      "Raw API response:" \
      "  $resp"
    return 1
  fi
}

# Truth-from-state probe for the CI bot App: when an App is installed on
# the repo, every lockdown ruleset below carries its Integration bypass
# actor so the claim's protected pushes ride the App installation token
# in CI. Empty when no App is installed - admins stay the only bypass.
CI_BOT_APP_ID_EFFECTIVE=$(gh api "/repos/$REPO_FULL/installation" --jq '.app_id // empty' 2>/dev/null || true)
if printf '%s' "$CI_BOT_APP_ID_EFFECTIVE" | grep -qE '^[0-9]+$'; then
  echo "→ CI bot App installed (app id $CI_BOT_APP_ID_EFFECTIVE); injecting its Integration bypass into the lockdown rulesets"
else
  CI_BOT_APP_ID_EFFECTIVE=""
  echo "→ no CI bot App installed; admins are the only ruleset bypass (claim hands protected transitions to bin/post-merge-lifecycle)"
fi

# --- pool/* creation restriction ruleset (reconcile names carved out) ---
apply_ruleset_from_file "pool/* creation restriction" "$RULESETS_DIR/pool-creations.json"
echo "  ✓ pool/* creation restricted; pool/*.reconcile.* carved out so the CI claim publishes candidates"

# --- pool/* deletion lock ruleset ---
apply_ruleset_from_file "pool/* deletion lock" "$RULESETS_DIR/pool-deletions.json"
echo "  ✓ pool/* deletion locked to admins (developers and CI never delete; vault receipts are the archive)"

# --- safety/* creation + update + deletion restriction ruleset ---
apply_ruleset_from_file "safety/* full lockdown" "$RULESETS_DIR/safety-lockdown.json"
echo "  ✓ safety/* locked down (created by allocator, deleted by claim, never modified)"

# --- dev required status checks ruleset ---
# Layered ON TOP of the dev branch protection above for belt-and-suspenders
# coverage: branch protection is the legacy mechanism, Repository Rulesets
# are the modern equivalent. GitHub merges the two, so the strictest wins.
apply_ruleset_from_file "dev required status checks" "$RULESETS_DIR/dev-required-checks.json"
echo "  ✓ dev requires required.commit-audit, required.compile, required.coverage, required.runtime, required.offline-test-suites checks before PR merge"

# --- vault/* read-only ruleset ---
apply_ruleset_from_file "vault/* read-only lockdown" "$RULESETS_DIR/vault-readonly.json"
echo "  ✓ vault/* frozen on touch (creation open so the CI claim vaults with its plain token; update and deletion admin only)"

echo ""
echo "✓ rules applied to $REPO_FULL"
echo ""
echo "Next: walk through the verification checklist in docs/repo-config.md"
echo "      using a non-admin developer account. Confirm:"
echo "      - pool/* creation rejected for normal devs"
echo "      - safety/* update/delete rejected for normal devs"
echo "      - vault/* creation, update, and deletion rejected for normal devs (frozen archive)"
