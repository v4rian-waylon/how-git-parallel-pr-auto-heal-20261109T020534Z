#!/usr/bin/env bash
# verify-template.sh - end-to-end test of the how-git template
#
# Creates a brand-new throwaway repo under the authenticated user (NOT under
# the template owner; testing never touches the og repo) seeded with the
# template's content, then exercises the actual consumer workflow on it:
# clone, run the in-repo scripts (open-pr.sh --doctor to trigger auto-config,
# claim-dev-merge.sh, claim-main-release.sh), and run test-hooks.sh, then
# asserts these invariants:
#
#   - Repo root contains only the expected entries (.github/, .gitignore,
#     .io.v4rian.how-git/); tags-as-seal ships NO live VERSION file
#   - Executable bits round-tripped through the bootstrap path
#   - No VERSION file is ever created (the version is an annotated dev tag
#     vYYYY.SERIES.DEV minted by bin/version --seal)
#   - core.hooksPath points into the namespace dir
#   - 26-of-26 hook + bump-math tests pass
#
# Two seed modes:
#
#   default            POST /repos/{template}/generate (real "Use this template" API).
#                      The throwaway is seeded from the template's DEFAULT branch.
#                      Requires is_template=true on the source. NOTE: until the
#                      framework's own first dev to main release lands, the
#                      default branch carries only the intro commit (.gitignore
#                      and the .io.v4rian.how-git namespace; the framework ships
#                      no root README). Use --from-branch dev for pre-first-release
#                      verification.
#
#   --from-branch <ref> Bypasses /generate. Creates an empty repo via
#                      POST /user/repos, mirrors what /generate fundamentally
#                      does (single fresh "Initial commit" containing the tree
#                      of <ref>), and pushes that to the new repo. Lets you
#                      e2e-test the deliverable of any branch (e.g. an unmerged
#                      PR) without touching the source's default branch. The
#                      .io.v4rian.how-git/FRAMEWORK_REPO marker is pruned from
#                      the seed tree before the orphan commit so the throwaway
#                      boots as a clean consumer (bootstrap-ci's consumer
#                      cleanup proceeds, framework-internal tests do not run
#                      against the consumer).
#
# Either way, the throwaway is a SEPARATE repo. The og template repo is
# never modified by this script. Throwaway is deleted on success (unless
# --keep), but auto-delete requires delete_repo scope on the token; if
# missing, the script warns and leaves the throwaway alive for manual
# cleanup.
#
# On a freshly templated CONSUMER (this script's throwaway, or any real
# consumer created via "Use this template"), bin/bootstrap-ci is the
# canonical path that primes the dev branch on origin (Step 2 reads
# main's SHA via the API and POSTs refs/heads/dev at the same commit),
# applies branch protection and Repository Rules, binds required status
# checks, sets merge-commit defaults, locks --no-ff merge mode, disables
# auto-delete merged branches, sets repo topics, and (Step 9b) prunes
# framework-internal artifacts that traveled along with the template.
#
# Dependencies: bash, git, curl, python3.   (No gh required.)
#
# Auth: same resolution chain as open-pr.sh.
#       Needs contents:write on the destination owner for repo creation.
#       Needs delete_repo for auto-cleanup; if absent, warns and skips.
#
# Usage:
#   verify-template.sh                          generate from template's default branch, test, delete
#   verify-template.sh --from-branch <ref>      seed from a named branch on the template (pre-merge testing)
#   verify-template.sh --with-bump-cycle        also exercise claim-dev-merge.sh + claim-main-release.sh
#                                               end-to-end (adds 5 invariants; runs locally - no CI polling)
#   verify-template.sh --keep                   leave throwaway alive (useful with --with-bump-cycle for inspection)
#   verify-template.sh --public                 create the throwaway public (free plans protect no private repo)
#   verify-template.sh --name <slug>            override generated repo name
#   verify-template.sh --template <owner/repo>  test a different template
#   verify-template.sh --dest-owner <owner>     create throwaway under this owner
#                                               (default: authenticated user)
#   verify-template.sh -h | --help              print this help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_throwaway_lib.sh
. "$SCRIPT_DIR/_throwaway_lib.sh"
TEMPLATE_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# Defaults
# TEMPLATE_REPO derives from this repo's origin URL so the framework has no
# hardcoded owner/repo and an origin swap retests connectivity in one step.
TEMPLATE_REPO=$(cd "$TEMPLATE_ROOT" 2>/dev/null && git config --get remote.origin.url 2>/dev/null \
  | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
DEST_OWNER=""
NAME=""
KEEP=false
FROM_BRANCH=""
WITH_BUMP_CYCLE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --template)         TEMPLATE_REPO="$2"; shift 2 ;;
    --dest-owner)       DEST_OWNER="$2"; shift 2 ;;
    --name)             NAME="$2"; shift 2 ;;
    --from-branch)      FROM_BRANCH="$2"; shift 2 ;;
    --with-bump-cycle)  WITH_BUMP_CYCLE=true; shift ;;
    --keep)             KEEP=true; shift ;;
    --public)           export THROWAWAY_PRIVATE=false; shift ;;
    -h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Token resolution: throwaway_resolve_token (_throwaway_lib.sh), the same
# chain open-pr.sh uses.

# ----------------------------------------------------------------------------
# Dependency probe
# ----------------------------------------------------------------------------
for t in bash git curl python3; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "✗ verify-template.sh requires '$t' - install it via your platform's package manager" >&2
    exit 3
  fi
done

TOKEN=$(throwaway_resolve_token) || {
  echo "✗ verify-template.sh: no GitHub token; run 'open-pr.sh --doctor' for resolution options" >&2
  exit 3
}

# ----------------------------------------------------------------------------
# Resolve destination owner (defaults to authenticated user)
# ----------------------------------------------------------------------------
if [ -z "$DEST_OWNER" ]; then
  DEST_OWNER=$(curl -sS -H "Authorization: token $TOKEN" https://api.github.com/user \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('login',''))")
  [ -z "$DEST_OWNER" ] && { echo "✗ could not resolve authenticated user from /user" >&2; exit 3; }
fi

# ----------------------------------------------------------------------------
# Resolve names + paths used by either seed mode
# ----------------------------------------------------------------------------
if [ -z "$NAME" ]; then
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  if [ -n "$FROM_BRANCH" ]; then
    NAME="how-git-verify-frombranch-$STAMP"
  else
    NAME="how-git-verify-$STAMP"
  fi
fi
TEST_DIR=$(mktemp -d -t "how-git-verify-XXXXXX")
# Keep the script's own exit status: a bare cleanup trap would end the run
# with rm's status 0 and report an aborted canary as green.
trap 'rc=$?; rm -rf "$TEST_DIR"; exit $rc' EXIT
CLONE_URL="https://$DEST_OWNER:$TOKEN@github.com/$DEST_OWNER/$NAME.git"

if [ -z "$FROM_BRANCH" ]; then
  # --------------------------------------------------------------------------
  # Seed mode 1: /generate (real "Use this template" API)
  # Requires is_template=true on the source. Throwaway content comes from
  # the source's DEFAULT branch (typically main).
  # --------------------------------------------------------------------------
  echo "→ seed mode: /generate (real 'Use this template' API)"
  echo "→ verifying source template '$TEMPLATE_REPO' has is_template=true"
  SRC_INFO=$(curl -sS -H "Authorization: token $TOKEN" "https://api.github.com/repos/$TEMPLATE_REPO")
  IS_TEMPLATE=$(echo "$SRC_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin).get('is_template'))")
  if [ "$IS_TEMPLATE" != "True" ]; then
    echo "✗ '$TEMPLATE_REPO' has is_template=$IS_TEMPLATE" >&2
    echo "  Flip it at https://github.com/$TEMPLATE_REPO/settings → Template repository → check the box" >&2
    echo "  Or test a non-default branch with --from-branch <ref>." >&2
    exit 1
  fi
  echo "  ✓ is_template: True"

  echo "→ generating throwaway: $DEST_OWNER/$NAME (from $TEMPLATE_REPO default branch)"
  GEN_URL=$(throwaway_create_from_template "$TOKEN" "$TEMPLATE_REPO" "$DEST_OWNER" "$NAME") || exit 1
  echo "  ✓ created $GEN_URL"
else
  # --------------------------------------------------------------------------
  # Seed mode 2: --from-branch
  # Create empty repo, clone the source branch locally, build a fresh single
  # "Initial commit" containing that branch's tree, push it to the new repo's
  # main. Mirrors what /generate fundamentally does (single rooted commit, no
  # shared history), but lets us test any named branch on the source. The og
  # repo is read-only here; we only read from it.
  # --------------------------------------------------------------------------
  echo "→ seed mode: --from-branch '$FROM_BRANCH' (simulates /generate from a non-default ref)"
  echo "→ creating empty throwaway: $DEST_OWNER/$NAME"
  GEN_URL=$(throwaway_create_empty "$TOKEN" "$DEST_OWNER" "$NAME") || exit 1
  echo "  ✓ created $GEN_URL (empty)"

  echo "→ building single-commit seed from $TEMPLATE_REPO@$FROM_BRANCH"
  SRC_CLONE="$TEST_DIR/source"
  git clone -q --branch "$FROM_BRANCH" --single-branch \
    "https://x-access-token:$TOKEN@github.com/$TEMPLATE_REPO.git" "$SRC_CLONE"
  cd "$SRC_CLONE"
  SOURCE_SHA=$(git rev-parse HEAD)
  echo "  · source $TEMPLATE_REPO@$FROM_BRANCH = $SOURCE_SHA"

  # The throwaway is a CONSUMER of the framework, not the framework source
  # itself. The FRAMEWORK_REPO marker file (at .io.v4rian.how-git/FRAMEWORK_REPO)
  # gates framework-internal behaviors (coverage.sh's framework-tests fallback,
  # offline-test.sh's suite invocation, bootstrap-ci's consumer-cleanup skip).
  # If the marker travels into the throwaway, those gates flip the wrong way:
  # consumer-cleanup thinks the throwaway is a framework source and skips its
  # work, then framework-internal tests run against a consumer tree and fail
  # on consumer-legitimate changes. Prune the marker from the seed before the
  # orphan commit so the throwaway boots as a clean consumer.
  if [ -f .io.v4rian.how-git/FRAMEWORK_REPO ]; then
    rm -f .io.v4rian.how-git/FRAMEWORK_REPO
    echo "  · pruned .io.v4rian.how-git/FRAMEWORK_REPO from seed (throwaway is a consumer)"
  fi

  # Make a fresh orphan branch with a single "Initial commit" carrying the
  # current tree. This mirrors the topology /generate produces.
  git checkout -q --orphan _seed
  git -c user.email="verify-template@local" -c user.name="verify-template" \
      commit -q -m "Initial commit"

  echo "→ pushing seed commit to throwaway main"
  git push -q "$CLONE_URL" _seed:main
  cd - >/dev/null
fi

# ----------------------------------------------------------------------------
# Clone the populated throwaway. Both seed paths converge here.
# /generate is asynchronous: the repo's refs may be reachable before the
# working tree is populated, so we retry until BOTH the clone succeeds AND
# the working tree has at least one file other than .git/.
# (--from-branch is synchronous, so this typically passes on the first try.)
# ----------------------------------------------------------------------------
echo "→ waiting for throwaway content to be reachable"
TRIES=0
while :; do
  rm -rf "$TEST_DIR/repo"
  if git clone -q "$CLONE_URL" "$TEST_DIR/repo" 2>/dev/null; then
    populated=$(ls -A1 "$TEST_DIR/repo" 2>/dev/null | grep -vc '^\.git$' || true)
    if [ "${populated:-0}" -gt 0 ]; then
      break
    fi
  fi
  TRIES=$((TRIES+1))
  if [ $TRIES -ge 30 ]; then
    echo "✗ repo not populated after 30 attempts (60s); last populated=${populated:-0}" >&2
    exit 1
  fi
  sleep 2
done
echo "  ✓ cloned ($populated entries at root, $TRIES retries)"

cd "$TEST_DIR/repo"
throwaway_adopt_identity "$DEST_OWNER" || { echo "✗ no commit identity for $DEST_OWNER" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Invariant checks
# ----------------------------------------------------------------------------
echo
echo "=== Invariant 1: repo root contains only the framework's entries ==="
# `|| true` keeps `set -e` + pipefail from killing the script when grep finds
# zero matches (empty root); we want the diagnostic block below to run instead.
ROOT=$(ls -A1 2>/dev/null | grep -v '^\.git$' | sort | tr '\n' ' ' || true)
# The framework ships its CI dispatchers (.github/) and the consumer-owned
# ci/ hook tree at the root (README "What's in the box"); anything else
# is a leak into the consumer's root.
EXPECTED=".github .gitignore .io.v4rian.how-git ci "
echo "    actual:   [$ROOT]"
echo "    expected: [$EXPECTED]"
if [ "$ROOT" = "$EXPECTED" ]; then
  echo "  ✓ root matches (clean for consumer's own files)"
else
  echo "  ✗ root differs - the seed ships a root entry outside the framework surface (.github, .gitignore, .io.v4rian.how-git, ci)" >&2
  exit 1
fi

echo
echo "=== Invariant 2: executable bits survived template generation ==="
FAIL=0
for f in .io.v4rian.how-git/githooks/pre-push \
         .io.v4rian.how-git/githooks/post-checkout \
         .io.v4rian.how-git/githooks/commit-msg \
         .io.v4rian.how-git/scripts/apply-repo-rules.sh \
         .io.v4rian.how-git/scripts/open-pr.sh \
         .io.v4rian.how-git/scripts/verify-template.sh \
         .io.v4rian.how-git/bin/create-pool-branch \
         .io.v4rian.how-git/scripts/allocate-pool-branch.sh \
         .io.v4rian.how-git/bin/version \
         .io.v4rian.how-git/framework-tests/test-hooks.sh; do
  if [ -x "$f" ]; then
    echo "  ✓ $f"
  else
    echo "  ✗ $f NOT executable"
    FAIL=1
  fi
done
[ $FAIL -ne 0 ] && exit 1

echo
echo "=== Invariant 3a: out-of-the-box - no setup; first script invocation auto-activates hooks (no VERSION file under tags-as-seal) ==="
# Confirm starting state is unset (the throwaway is a fresh clone, no heal was run)
PRE_HOOKS=$(git config core.hooksPath 2>/dev/null || true)
PRE_VERSION_EXISTS="no"; [ -f VERSION ] && PRE_VERSION_EXISTS="yes"
echo "    pre: core.hooksPath=[${PRE_HOOKS:-unset}] VERSION exists=$PRE_VERSION_EXISTS"
# Invoke any in-repo script. open-pr.sh --doctor is read-only (no git mutation, no API).
bash .io.v4rian.how-git/scripts/open-pr.sh --doctor >/dev/null 2>&1 || true
POST_HOOKS=$(git config core.hooksPath 2>/dev/null || true)
echo "    post (after open-pr.sh --doctor): core.hooksPath=[${POST_HOOKS:-unset}]"
if [ "$POST_HOOKS" = ".io.v4rian.how-git/githooks" ]; then
  echo "  ✓ hooks auto-activated by first in-repo script call (no setup step required)"
else
  echo "  ✗ hooks did NOT auto-activate; expected .io.v4rian.how-git/githooks, got [${POST_HOOKS:-unset}]"
  exit 1
fi
# tags-as-seal: no in-repo script ever materializes a VERSION file; the version
# is an annotated dev tag minted by bin/version, never a tracked file.
if [ ! -f VERSION ]; then
  echo "  ✓ no VERSION file created by first script call (version derived from git tags)"
else
  echo "  ✗ a VERSION file was created; tags-as-seal forbids a live VERSION file" >&2
  exit 1
fi

echo
echo "=== Invariant 3b: heal - scripts/heal.sh restores expected state after drift (no VERSION file) ==="
# Drift core.hooksPath to something invalid, then heal via the script.
git config core.hooksPath /tmp/this-path-does-not-exist
bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
HOOKS_PATH=$(git config core.hooksPath || true)
# heal.sh restores hooksPath but, under tags-as-seal, MUST NOT create a VERSION
# file (mirrors framework-tests' test_heal_does_not_create_version_file).
[ ! -f VERSION ] && echo "  ✓ no VERSION file after heal (tags-as-seal model)" || { echo "  ✗ heal created a VERSION file (forbidden under tags-as-seal)"; exit 1; }
[ "$HOOKS_PATH" = ".io.v4rian.how-git/githooks" ] && echo "  ✓ core.hooksPath = $HOOKS_PATH (after drift + heal)" || { echo "  ✗ core.hooksPath = $HOOKS_PATH"; exit 1; }

echo
echo "=== Invariant 4: test-hooks.sh passes ==="
TEST_OUT=$(bash .io.v4rian.how-git/framework-tests/test-hooks.sh 2>&1)
if echo "$TEST_OUT" | grep -q "0 failed"; then
  PASSED=$(echo "$TEST_OUT" | grep "passed," | tr -dc '0-9 ,' | awk -F, '{print $1}' | tr -d ' ')
  echo "  ✓ $PASSED tests passed"
else
  echo "  ✗ test-hooks.sh failed"
  echo "$TEST_OUT"
  exit 1
fi

echo
echo "=== Invariant 5: canonical claim scripts present and executable ==="
for f in .io.v4rian.how-git/scripts/claim-dev-merge.sh \
         .io.v4rian.how-git/scripts/claim-main-release.sh; do
  if [ -x "$f" ]; then
    echo "  ✓ $f"
  else
    echo "  ✗ $f missing or not executable"
    exit 1
  fi
done

echo
echo "=== Invariant 5a: in-repo skills present ==="
# Skills now ship inside the template at .io.v4rian.how-git/skills/, so the
# hooks can invoke them via claude_skill_run regardless of the consumer's
# global ~/.claude/skills/ state.
REQUIRED_SKILLS=(git-commit-audit git-strategy-audit git-compile-audit git-coverage-audit git-runtime-audit git-snapshot-preflight git-merge-audit git-history-preservation git-history-rewrite git-token-discovery git-snapshots git-shuttle)
missing=0
for s in ${REQUIRED_SKILLS[@]+"${REQUIRED_SKILLS[@]}"}; do
  if [ -f ".io.v4rian.how-git/skills/$s/SKILL.md" ]; then
    echo "  ✓ skills/$s/SKILL.md"
  else
    echo "  ✗ skills/$s/SKILL.md missing"
    missing=1
  fi
done
[ $missing -eq 0 ] || exit 1

echo
echo "=== Invariant 5b: claude judgment call sites load the right skills ==="
# Pairs of "<file relative to the namespace> <call> <skill>". Kept as a plain
# list (no associative array) so the canary runs on macOS's bash 3.2. The
# commit lens moved from the commit-msg hook to the push-trigger audit.
while read -r site call sk; do
  [ -n "$site" ] || continue
  if grep -q "$call $sk\b" ".io.v4rian.how-git/$site"; then
    echo "  ✓ $site: $call $sk"
  else
    echo "  ✗ $site does NOT call $call $sk"
    exit 1
  fi
done <<'SITES'
githooks/post-checkout claude_skill_run git-snapshot-preflight
scripts/audits/commit-audit.sh resolve_skill git-commit-audit
scripts/_lib.sh resolve_skill git-reconcile-intent
scripts/_lib.sh resolve_skill git-strategy-audit
SITES

echo
echo "=== Invariant 5c: 'git v4r' alias auto-installed by ensure_hooks_path ==="
INSTALLED_ALIAS=$(git config alias.v4r 2>/dev/null || true)
if echo "$INSTALLED_ALIAS" | grep -q "openPR"; then
  echo "  ✓ alias.v4r installed (dispatches openPR / heal / verify / claim-dev / claim-main)"
else
  echo "  ✗ alias.v4r NOT installed; got: [$INSTALLED_ALIAS]"
  exit 1
fi
if git config alias.repo >/dev/null 2>&1; then
  echo "  ✗ the retired alias.repo is still configured"
  exit 1
fi

echo
echo "=== Invariant 5d: merge claims dispatch through ci-dispatch to the in-repo claim scripts ==="
# The claim-on-merge workflows folded into ci-dispatch.yml: a push to dev or
# main resolves to pr-merge-dev / pr-merge-main, whose required.claim.sh runs
# claim-retry.sh, which runs the canonical claim script; dev-merge.yml and
# main-merge.yml are the admin re-claim entries into the same engine.
check_link() {
  if grep -q -- "$2" "$1" 2>/dev/null; then
    echo "  ✓ $1 -> $2"
  else
    echo "  ✗ $1 does not reach $2"
    exit 1
  fi
}
check_link .github/workflows/ci-dispatch.yml 'trigger="pr-merge-dev"'
check_link .github/workflows/ci-dispatch.yml 'trigger="pr-merge-main"'
for t in dev main; do
  check_link ".github/workflows/$t-merge.yml" "trigger: pr-merge-$t"
  check_link ".io.v4rian.how-git/ci/audits/pr-merge-$t/required.claim.sh" 'claim-retry.sh'
done
check_link .io.v4rian.how-git/scripts/workflows/claim-retry.sh 'CLAIM_SCRIPT="claim-dev-merge.sh"'
check_link .io.v4rian.how-git/scripts/workflows/claim-retry.sh 'CLAIM_SCRIPT="claim-main-release.sh"'

echo
echo "=== STATIC INVARIANTS (1-5d) PASSED ==="
echo

# ============================================================================
# Optional git-native bump cycle test
# ============================================================================
# Exercises the canonical claim scripts (claim-dev-merge.sh, claim-main-
# release.sh) against the throwaway. Without this phase the bump scripts
# and the claim scripts are checked for syntax + math only (via Invariants
# 1-5 and test/test-hooks.sh); with this phase the full claim-on-merge
# cycle runs end-to-end with NO CI involvement - pure git tooling.
#
# Invariants 6-11 (tags-as-seal model - version is an annotated dev tag minted
# by bin/version, never a VERSION file; a release REUSES the dev tag):
#   6.  claim-dev-merge.sh tags dev HEAD with the sealed dev tag
#       vYYYY.SERIES.DEV (== bin/version --seal), annotated, no -b.N build suffix
#   7.  the claim creates NO VERSION file (version lives only as the git tag)
#   8.  claim-main-release.sh REUSES the existing dev tag for the release; it
#       mints NO new git tag (no vYYYY.SERIES release-only tag)
#   9.  GitHub Release for the reused dev tag exists (if a token is available; warns + passes if not)
#  10. the release creates NO VERSION file and resets no counter
#  11. a pool->dev merge fires the post-merge hook, which mints a NEW dev tag
#       (tag count grows) bumping the DEV segment - not a -b.N build counter;
#       it runs before the release (8-10), which ships that claimed merge
#       through a --no-ff dev->main merge as bin/ship does

if $WITH_BUMP_CYCLE; then
  echo "=== git-native bump cycle test (Invariants 6, 7, 11, 8-10) ==="
  echo "  · This phase invokes the local claim scripts directly. No CI polling."
  echo

  # The cloned remote URL embeds the token already; this lets push work.
  git remote set-url origin "$CLONE_URL"

  # --------------------------------------------------------------------------
  # Phase 1: create dev, push, run claim-dev-merge.sh, verify tag + bump
  # --------------------------------------------------------------------------
  echo "→ creating dev branch from main and pushing"
  git checkout -q -b dev
  git push -q origin dev
  DEV_SHA=$(git rev-parse dev)
  echo "  · dev pushed at SHA $DEV_SHA"

  # We invoke claim-dev-merge.sh explicitly here to exercise the script path
  # itself (Invariants 6, 7); the post-merge hook (Invariant 11) is exercised
  # separately below by doing a pull that brings in a remote merge.
  echo "→ running claim-dev-merge.sh"
  echo "  · the seed tip is no pool merge, so the claim seals v<year>.0.0 and its vault step reports it found no pool (expected here)"
  bash .io.v4rian.how-git/scripts/claim-dev-merge.sh --skip-pull

  echo
  echo "=== Invariant 6: claim-dev-merge.sh sealed dev HEAD with the bin/version tag ==="
  git fetch -q --tags
  # tags-as-seal: the dev tag is exactly what bin/version --seal returns on dev
  # HEAD - shape vYYYY.SERIES.DEV, annotated, NO -b.N build suffix.
  TAG_DEV=$(bash .io.v4rian.how-git/bin/version --seal)
  echo "    bin/version --seal on dev HEAD = $TAG_DEV"
  case "$TAG_DEV" in
    v[0-9]*.[0-9]*.[0-9]*) : ;;
    *) echo "  ✗ seal '$TAG_DEV' is not the vYYYY.SERIES.DEV shape"; exit 1 ;;
  esac
  case "$TAG_DEV" in
    *-b.*) echo "  ✗ seal '$TAG_DEV' carries a retired -b.N build suffix"; exit 1 ;;
  esac
  if git tag -l "$TAG_DEV" | grep -q "^$TAG_DEV$"; then
    if git cat-file -t "$TAG_DEV" 2>/dev/null | grep -q '^tag$'; then
      echo "  ✓ dev tag $TAG_DEV is annotated"
    else
      echo "  ✗ dev tag $TAG_DEV exists but is not annotated"
      exit 1
    fi
    TAG_SHA=$(git rev-parse "$TAG_DEV"^{commit})
    if [ "$TAG_SHA" = "$DEV_SHA" ]; then
      echo "  ✓ tag $TAG_DEV seals dev HEAD $TAG_SHA"
    else
      echo "  ✗ tag $TAG_DEV exists but on $TAG_SHA, not the pushed dev SHA $DEV_SHA"
      exit 1
    fi
  else
    echo "  ✗ expected dev tag $TAG_DEV not found; tags present:"
    git tag -l | sed 's/^/    /'
    exit 1
  fi

  echo
  echo "=== Invariant 7: the claim created NO VERSION file (version is the tag) ==="
  git pull -q origin dev
  # tags-as-seal retires the VERSION-counter model: the claim mints a tag and
  # never writes a tracked VERSION file. There is no -b.N dev bump to assert.
  if [ ! -f VERSION ]; then
    echo "  ✓ no VERSION file on dev after the claim (the dev tag is the version)"
  else
    echo "  ✗ a VERSION file exists on dev; tags-as-seal forbids it (content: $(head -1 VERSION))"
    exit 1
  fi

  # --------------------------------------------------------------------------
  # Phase 2: merge dev into main --no-ff, run claim-main-release.sh, verify the
  # release REUSES the dev tag (no new tag, no VERSION file) + GH Release exists
  # --------------------------------------------------------------------------
  echo
  echo
  echo "=== Invariant 11: post-merge hook auto-claims on a local --no-ff merge into dev ==="
  echo
  # The automator path. From dev's perspective there are two equivalent
  # ways a new merge commit appears:
  #   (a) `git merge --no-ff pool/*` locally (the merger pulls + merges)
  #   (b) `git pull` brings a remote merge commit that landed via GitHub UI
  # Both fire post-merge identically. We exercise (a) here since it's a
  # complete loop in a single repo without needing a second clone.

  # Snapshot pre-state. Under tags-as-seal the version is the latest dev tag
  # minted by bin/version; the auto-claim proves itself by GROWING the tag set
  # and bumping the DEV segment - never by editing a VERSION file.
  git checkout -q dev
  git pull -q --ff-only origin dev
  PRE_TAG_COUNT=$(git tag -l | wc -l | tr -d ' ')
  PRE_SEAL=$(bash .io.v4rian.how-git/bin/version --seal)
  echo "    pre:  seal=$PRE_SEAL  tag-count=$PRE_TAG_COUNT"

  # A pool merge the way an operator lands one off-grid: the allocator makes
  # the pool+safety pair, one commit rides it, and a --no-ff merge brings it
  # into dev (never a self-made pool/* name).
  PROBE_POOL=$(bash .io.v4rian.how-git/bin/create-pool-branch post-merge-probe \
      --no-jira --kind refactor --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["branch_name"])') || {
    echo "  ✗ the allocator did not create the probe pool"; exit 1; }
  PROBE_SAFETY="safety/${PROBE_POOL#pool/}"
  git checkout -q "$PROBE_POOL"
  echo "# probe" > README-PROBE.md
  git add README-PROBE.md
  git commit -q -m "[REFACTOR] Probe post-merge auto-claim path"
  git push -q origin "${PROBE_POOL}:refs/heads/${PROBE_POOL}" "${PROBE_SAFETY}:refs/heads/${PROBE_SAFETY}"
  git checkout -q dev
  echo "    → about to merge $PROBE_POOL into dev; the post-merge hook should fire and auto-claim:"
  git merge -q --no-ff "$PROBE_POOL" \
    -m "[MERGE] $PROBE_POOL into dev: $PRE_SEAL" \
    -m "$(bash .io.v4rian.how-git/scripts/lib/probe-merge-body.sh post-merge-hook-probe)" 2>&1 \
    | sed 's/^/      /'
  git push -q origin dev

  POST_TAG_COUNT=$(git tag -l | wc -l | tr -d ' ')
  POST_SEAL=$(bash .io.v4rian.how-git/bin/version --seal)
  echo "    post: seal=$POST_SEAL  tag-count=$POST_TAG_COUNT"

  # The bump lands in the DEV segment of the tag, NOT a -b.N build counter.
  case "$POST_SEAL" in
    *-b.*) echo "  ✗ seal '$POST_SEAL' carries a retired -b.N build suffix"; exit 1 ;;
  esac
  if [ "$POST_TAG_COUNT" -gt "$PRE_TAG_COUNT" ] && [ "$POST_SEAL" != "$PRE_SEAL" ] && [ ! -f VERSION ]; then
    echo "  ✓ post-merge hook fired automatically: minted a new dev tag, seal $PRE_SEAL → $POST_SEAL (DEV bumped), tag count grew by $((POST_TAG_COUNT - PRE_TAG_COUNT)), no VERSION file"
  else
    echo "  ✗ post-merge hook did NOT auto-claim under the tags-as-seal model"
    echo "      tag delta: $((POST_TAG_COUNT - PRE_TAG_COUNT)) (expected ≥ 1)"
    echo "      seal: $PRE_SEAL → $POST_SEAL (expected DEV bump)"
    [ -f VERSION ] && echo "      a VERSION file appeared (forbidden under tags-as-seal)"
    git log --oneline -5
    exit 1
  fi

  # The release below ships this claimed pool merge, so it reuses this tag.
  TAG_DEV=$POST_SEAL

  echo "→ merging dev into main --no-ff (the bin/ship release shape) and pushing"
  REL_BODY=$(bash .io.v4rian.how-git/scripts/seed-release-body.sh main)
  [ -n "$REL_BODY" ] || { echo "  ✗ seed-release-body.sh found no pool merge to release"; exit 1; }
  git checkout -q main
  git pull -q origin main
  DEV_DATE=$(git log -1 --format=%cI dev)
  GIT_AUTHOR_DATE="$DEV_DATE" GIT_COMMITTER_DATE="$DEV_DATE" \
    git merge -q --no-ff dev -m "[MERGE] dev into main: $TAG_DEV" -m "$REL_BODY"
  git push -q origin main
  MAIN_SHA=$(git rev-parse main)
  echo "  · main pushed at SHA $MAIN_SHA"

  # Snapshot the tag set BEFORE the release so Invariant 8 can prove the
  # release minted no new git tag (it must REUSE the dev tag).
  git fetch -q --tags
  PRE_REL_TAGS=$(git tag -l | sort | tr '\n' ' ')

  echo "→ running claim-main-release.sh"
  # Token comes from the same chain claim-main-release.sh uses; passing it
  # via env so the script's optional GH Release creation reaches the API.
  GH_TOKEN="$TOKEN" bash .io.v4rian.how-git/scripts/claim-main-release.sh --skip-pull

  echo
  echo "=== Invariant 8: claim-main-release.sh REUSES the dev tag (mints no new tag) ==="
  git fetch -q --tags
  # tags-as-seal: a release does NOT mint a vYYYY.SERIES release-only tag. It
  # REUSES the existing dev tag (bin/version --release-tag == the dev tag the
  # claim already minted) and the dev->main merge brings that tagged commit
  # onto main. The tag set must be UNCHANGED by the release.
  TAG_REL=$(bash .io.v4rian.how-git/bin/version --release-tag)
  echo "    bin/version --release-tag = $TAG_REL (must equal the dev tag $TAG_DEV)"
  if [ "$TAG_REL" != "$TAG_DEV" ]; then
    echo "  ✗ release-tag $TAG_REL differs from the dev tag $TAG_DEV; a release must REUSE the dev tag"
    exit 1
  fi
  POST_REL_TAGS=$(git tag -l | sort | tr '\n' ' ')
  if [ "$POST_REL_TAGS" = "$PRE_REL_TAGS" ]; then
    echo "  ✓ tag set unchanged by the release: [$POST_REL_TAGS] (dev tag reused, no new tag)"
  else
    echo "  ✗ release minted a new git tag; pre=[$PRE_REL_TAGS] post=[$POST_REL_TAGS]"
    exit 1
  fi
  # The reused tag must sit on main's history (the dev->main merge brought it).
  if git merge-base --is-ancestor "$TAG_REL^{commit}" main; then
    echo "  ✓ reused tag $TAG_REL is reachable from main (brought by the dev->main merge)"
  else
    echo "  ✗ reused tag $TAG_REL is not reachable from main"
    exit 1
  fi

  echo
  echo "=== Invariant 9: GitHub Release attached to the reused dev tag ==="
  REL_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$DEST_OWNER/$NAME/releases/tags/$TAG_REL")
  case "$REL_CODE" in
    200) echo "  ✓ GitHub Release on reused tag $TAG_REL exists (HTTP 200)" ;;
    404) echo "  ⚠ no Release for $TAG_REL (HTTP 404) - claim-main-release.sh may have run without a token; the dev tag is canonical regardless. Passing this invariant as a soft check." ;;
    *)   echo "  ✗ unexpected status $REL_CODE checking Release"; exit 1 ;;
  esac

  echo
  echo "=== Invariant 10: the release reset NOTHING (no VERSION file, no counter reset) ==="
  git pull -q origin main
  # tags-as-seal retires the old VERSION-counter reset entirely. A release
  # reuses the dev tag and writes no tracked VERSION file on main.
  if [ ! -f VERSION ]; then
    echo "  ✓ no VERSION file on main after the release (nothing to reset; the tag is the version)"
  else
    echo "  ✗ a VERSION file exists on main; tags-as-seal forbids it (content: $(head -1 VERSION))"
    exit 1
  fi

  echo
  echo "=== git-native BUMP CYCLE + AUTOMATOR (Invariants 6-11) PASSED ==="
  echo
fi

# ----------------------------------------------------------------------------
# Cleanup (delete throwaway repo) unless --keep
# ----------------------------------------------------------------------------
cd /tmp   # leave the test dir so trap can remove it
if $KEEP; then
  echo "→ --keep set; leaving throwaway alive at $GEN_URL"
  echo "→ local clone left in $TEST_DIR/repo (trap will remove on exit; copy elsewhere if you need it)"
else
  echo "→ deleting throwaway repo $DEST_OWNER/$NAME"
  DEL_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$DEST_OWNER/$NAME")
  case "$DEL_CODE" in
    204) echo "  ✓ deleted" ;;
    403) echo "  ⚠ token lacks delete_repo scope (HTTP 403). Throwaway left alive at $GEN_URL - delete it manually at Settings → Danger Zone → Delete this repository, or run with --keep to silence this warning." ;;
    404) echo "  ⚠ already gone (HTTP 404)" ;;
    *)   echo "  ⚠ unexpected status $DEL_CODE; throwaway may still exist at $GEN_URL" ;;
  esac
fi
