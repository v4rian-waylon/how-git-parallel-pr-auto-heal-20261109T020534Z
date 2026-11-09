#!/usr/bin/env bash
# test-parallel-pr-auto-heal-canary.sh - operator-run end-to-end exercise of
# the parallel-PR auto-heal scenario against a real throwaway repo.
#
# Spawns a brand-new throwaway from the how-git template via the "Use this
# template" API, runs bin/bootstrap-ci on it to wire branch protection +
# the claim and auto-rebase flows, allocates TWO parallel pool branches via
# the canonical allocator CLI, makes commits on each that modify the SAME
# file at the SAME hunk so a cherry-pick from one onto a dev tip carrying
# the other guarantees a conflict, opens a PR per branch into dev, merges
# the first, and verifies that the pr-merge-dev claim run of ci-dispatch.yml fires +
# triggers auto-rebase-pools-after-dev-merge.sh + cuts a fresh
# pool/nN.reconcile.<short> for the still-open PR + cherry-picks the pool's
# commits onto the new dev tip (resolving the hunk-level conflict via the
# L1-L5 ladder) + pushes the reconcile branch + comments on the original
# still-open PR with the reconcile candidate.
#
# This is the operator-run canary for the parallel-PR auto-heal feature.
# The offline lifecycle suite covers the regex and the helper math for the
# auto-rebase script; THIS canary is the escape hatch that proves the live
# pr-merge-dev claim run of ci-dispatch.yml + the in-claim auto-rebase invocation +
# the conflict-heal ladder all wire together against an actual throwaway
# repo. Two scenarios run end-to-end:
#
#   Positive scenario:
#     1. Allocate pool/n1.feature.canary-a + pool/n2.feature.canary-b.
#     2. Each pool branch appends a different one-line entry to the
#        CHANGELOG.md `## Unreleased` section. The two entries land on
#        adjacent lines that collapse to the same hunk after merge.
#     3. Open PR #1 + PR #2 into dev.
#     4. Merge PR #1 via the API.
#     5. Wait for the pr-merge-dev claim run to amend + tag + vault + auto-rebase.
#     6. Verify auto-rebase produced:
#          - pool/v<MAJOR>/n2.reconcile.canary-b branch on origin
#          - PR #2 still open (never auto-closed)
#          - a comment on PR #2 naming the reconcile candidate
#          - the reconcile branch's tip diff carries pool/n2's intent
#
#   Negative L5 scenario:
#     Synthesizes a deeper conflict (both pool branches delete the SAME
#     file at the same point in addition to the CHANGELOG edit). L1-L5
#     plausibly exhausts strategies; the script asserts that EITHER the
#     reconcile branch lands as a clean candidate OR the partial
#     reconcile branch lands plus a draft-friendly comment surfaces on
#     PR #2 naming the unresolved hunks. Either outcome is acceptable -
#     the FAILURE mode the canary catches is "no reconcile branch
#     produced, no comment, PR #2 silently abandoned" which is the D-3
#     class of regression that motivated this canary.
#
# Token / auth handling and the no-implicit-default refusal posture
# match test-off-grid-e2e.sh by design.
#
# Usage:
#   test-parallel-pr-auto-heal-canary.sh --token TOKEN --account OWNER [options]
#   test-parallel-pr-auto-heal-canary.sh --dry-run --token TOKEN --account OWNER
#   test-parallel-pr-auto-heal-canary.sh -h | --help
#
# Options:
#   --token TOKEN           GitHub PAT or installation token with repo +
#                           delete_repo scope. Required (no implicit default).
#   --account OWNER         Owner under which the throwaway is created.
#                           Required (no implicit default).
#   --template OWNER/REPO   Template repo to seed the throwaway from.
#                           Default: derived from this repo's origin URL.
#   --from-branch REF       Seed from a non-default branch on the template.
#                           Default: template's default branch via /generate.
#   --name SLUG             Override the generated throwaway repo name.
#                           Default: how-git-parallel-pr-auto-heal-<UTC-stamp>.
#   --keep                  Leave the throwaway alive on success for manual
#                           inspection (default: delete on success).
#   --public                Create the throwaway public instead of private.
#                           Needed to exercise branch protection, rulesets
#                           and Actions live on a free plan, which offers
#                           none of them on private repos.
#   --claude-token TOKEN    Claude Code OAuth token (claude setup-token) that
#                           bootstrap-ci stores as the throwaway's
#                           CLAUDE_CODE_OAUTH_TOKEN secret, so the L1-L5 ladder
#                           can resolve the conflict. Without it the canary
#                           checks the degraded contract instead: no empty
#                           reconcile pushed, PR B open, EMPTY reconcile comment.
#   --positive-only         Run only the positive scenario; skip the L5
#                           unresolvable scenario.
#   --negative-only         Run only the L5 unresolvable scenario; skip
#                           the positive scenario.
#   --dry-run               Print every planned API call without executing
#                           any of them. Token + account are still required.
#   -h | --help             Show this help and exit.
#
# Exit codes:
#   0    every step + verification passed.
#   2    bad CLI inputs or missing required arg.
#   3    missing system dependency (bash, git, curl, python3).
#   4    token or account missing (the no-implicit-default refusal).
#   5    API call failed (creation, push, PR open, merge, or deletion).
#   6    verification step failed (reconcile branch, comment, PR state).

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate script + namespace + template root
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS_DIR=$(dirname "$SCRIPT_DIR")
TEMPLATE_ROOT=$(dirname "$NS_DIR")

# shellcheck source=./_throwaway_lib.sh
. "$SCRIPT_DIR/_throwaway_lib.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TOKEN=""
ACCOUNT=""
TEMPLATE_REPO=$(throwaway_default_template "$TEMPLATE_ROOT")
FROM_BRANCH=""
NAME=""
KEEP=false
CLAUDE_TOKEN=""
DRY_RUN=false
POSITIVE_ONLY=false
NEGATIVE_ONLY=false

# The help is the header comment block, up to its first non-comment line, so
# it never cuts off when the header grows.
usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --token)         TOKEN="$2"; shift 2 ;;
    --account)       ACCOUNT="$2"; shift 2 ;;
    --template)      TEMPLATE_REPO="$2"; shift 2 ;;
    --from-branch)   FROM_BRANCH="$2"; shift 2 ;;
    --name)          NAME="$2"; shift 2 ;;
    --keep)          KEEP=true; shift ;;
    --claude-token)  CLAUDE_TOKEN="$2"; shift 2 ;;
    --public)        export THROWAWAY_PRIVATE=false; shift ;;
    --positive-only) POSITIVE_ONLY=true; shift ;;
    --negative-only) NEGATIVE_ONLY=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -h|--help)       usage 0 ;;
    *) echo "X test-parallel-pr-auto-heal-canary: unknown flag: $1" >&2; usage 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Hard refusal: no implicit token, no implicit account. Same refusal
# posture as test-off-grid-e2e.sh - creating and merging PRs on a real
# throwaway and then deleting the repo is destructive enough that falling
# through to "whoever's gh is logged in" is the foot-gun we refuse to ship.
# ---------------------------------------------------------------------------
if [ -z "$TOKEN" ]; then
  TOKEN=$(throwaway_resolve_token || true)
fi

if [ -z "$TOKEN" ]; then
  echo "X test-parallel-pr-auto-heal-canary: --token TOKEN is required (no implicit default)" >&2
  echo "  This canary creates and deletes real GitHub repos. To prevent foot-guns" >&2
  echo "  it refuses to fall back to ambient credentials. Pass --token explicitly," >&2
  echo "  or export GH_TOKEN, or place a plaintext PAT at:" >&2
  echo "    \$HOME/.gcm/store/git/https/github.com/<account>.credential" >&2
  exit 4
fi

if [ -z "$ACCOUNT" ]; then
  echo "X test-parallel-pr-auto-heal-canary: --account OWNER is required (no implicit default)" >&2
  echo "  The throwaway is created under this owner. Pass --account explicitly" >&2
  echo "  even though the token implicitly identifies an actor - this is the" >&2
  echo "  belt-and-suspenders guard for cross-account PAT mistakes." >&2
  exit 4
fi

if $POSITIVE_ONLY && $NEGATIVE_ONLY; then
  echo "X test-parallel-pr-auto-heal-canary: --positive-only and --negative-only are mutually exclusive" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Dependency probe (shared deps; this canary needs no extras)
# ---------------------------------------------------------------------------
throwaway_check_deps

# ---------------------------------------------------------------------------
# Resolve name + paths
# ---------------------------------------------------------------------------
if [ -z "$NAME" ]; then
  NAME=$(throwaway_default_name "how-git-parallel-pr-auto-heal")
fi
TEST_DIR=$(mktemp -d -t "parallel-pr-canary-XXXXXX")
trap 'rc=$?; rm -rf "$TEST_DIR"; exit $rc' EXIT
CLONE_URL="https://$ACCOUNT:$TOKEN@github.com/$ACCOUNT/$NAME.git"

# ---------------------------------------------------------------------------
# Dry-run early exit: enumerate every planned API call + every command, then
# return so the caller (lifecycle tests, operator preview) sees the full plan
# without any mutation reaching the network. Mirrors test-off-grid-e2e's
# dry-run plan banner shape so the two canaries surface the same way under
# the operator's eye.
# ---------------------------------------------------------------------------
if $DRY_RUN; then
  echo "[dry-run] parallel-pr auto-heal canary plan against template=$TEMPLATE_REPO, throwaway=$ACCOUNT/$NAME"
  if [ -n "$FROM_BRANCH" ]; then
    echo "[dry-run] POST https://api.github.com/user/repos  (empty seed; branch=$FROM_BRANCH; private=$(throwaway_private_json))"
    echo "[dry-run] git clone --branch $FROM_BRANCH --single-branch https://x-access-token:***@github.com/$TEMPLATE_REPO.git"
    echo "[dry-run] git push <clone-url> _seed:main"
  else
    echo "[dry-run] POST https://api.github.com/repos/$TEMPLATE_REPO/generate  (owner=$ACCOUNT name=$NAME private=$(throwaway_private_json))"
  fi
  echo "[dry-run] git clone https://$ACCOUNT:***@github.com/$ACCOUNT/$NAME.git  (with retry loop until working tree populated)"
  echo "[dry-run] bash .io.v4rian.how-git/scripts/heal.sh  (auto-activate hooks + alias)"
  echo "[dry-run] git checkout -b dev + git push origin dev"
  echo "[dry-run] bash .io.v4rian.how-git/bin/bootstrap-ci  (apply branch protection + rulesets + required checks + claim wiring)"
  if ! $NEGATIVE_ONLY; then
    echo "[dry-run] positive scenario:"
    echo "[dry-run]   bash .io.v4rian.how-git/bin/create-pool-branch canary-a --no-jira --kind feature  (atomic pool+safety pair via allocator)"
    echo "[dry-run]   bash .io.v4rian.how-git/bin/create-pool-branch canary-b --no-jira --kind feature  (atomic pool+safety pair via allocator)"
    echo "[dry-run]   git checkout <pool-a> + edit CHANGELOG.md Unreleased + commit + push"
    echo "[dry-run]   git checkout <pool-b> + edit CHANGELOG.md Unreleased + commit + push"
    echo "[dry-run]   POST https://api.github.com/repos/$ACCOUNT/$NAME/pulls  (head=<pool-a> base=dev)"
    echo "[dry-run]   POST https://api.github.com/repos/$ACCOUNT/$NAME/pulls  (head=<pool-b> base=dev)"
    echo "[dry-run]   wait until both PRs report mergeable_state clean (required checks green)"
    echo "[dry-run]   PUT https://api.github.com/repos/$ACCOUNT/$NAME/pulls/<num-a>/merge  (merge PR #1 into dev)"
    echo "[dry-run]   wait for the pr-merge-dev claim run of ci-dispatch.yml (amend + tag + vault + auto-rebase)"
    echo "[dry-run]   verify: pool/v<MAJOR>/n2.reconcile.canary-b ref exists on origin"
    echo "[dry-run]   verify: PR #2 still open (never auto-closed)"
    echo "[dry-run]   verify: comment on PR #2 names the reconcile candidate"
    echo "[dry-run]   verify: reconcile branch tip carries pool/n2's intent (canary-b CHANGELOG entry present)"
  fi
  if ! $POSITIVE_ONLY; then
    echo "[dry-run] negative scenario (L5 unresolvable):"
    echo "[dry-run]   bash .io.v4rian.how-git/bin/create-pool-branch canary-x --no-jira --kind feature  (atomic pool+safety pair via allocator)"
    echo "[dry-run]   bash .io.v4rian.how-git/bin/create-pool-branch canary-y --no-jira --kind feature  (atomic pool+safety pair via allocator)"
    echo "[dry-run]   git checkout <pool-x> + edit CHANGELOG.md Unreleased + create canary-conflict.txt (side X) + commit + push"
    echo "[dry-run]   git checkout <pool-y> + edit CHANGELOG.md Unreleased + create canary-conflict.txt (side Y) + commit + push"
    echo "[dry-run]   POST https://api.github.com/repos/$ACCOUNT/$NAME/pulls  (head=<pool-x> base=dev)"
    echo "[dry-run]   POST https://api.github.com/repos/$ACCOUNT/$NAME/pulls  (head=<pool-y> base=dev)"
    echo "[dry-run]   PUT https://api.github.com/repos/$ACCOUNT/$NAME/pulls/<num-x>/merge"
    echo "[dry-run]   wait for the pr-merge-dev claim run + auto-rebase L1-L5 exhaustion path"
    echo "[dry-run]   verify: pool/v<MAJOR>/n<Y>.reconcile.canary-y ref exists on origin (partial or clean)"
    echo "[dry-run]   verify: PR #<Y> still open (never auto-closed)"
    echo "[dry-run]   verify: comment on PR #<Y> names the reconcile candidate OR the L1-L5 attempt log"
  fi
  if $KEEP; then
    echo "[dry-run] --keep set; throwaway $ACCOUNT/$NAME left alive"
  else
    echo "[dry-run] DELETE https://api.github.com/repos/$ACCOUNT/$NAME"
  fi
  echo "[dry-run] plan complete; no mutation performed"
  exit 0
fi

# ---------------------------------------------------------------------------
# Helper: poll a URL until a condition is satisfied or the deadline elapses.
# $1 = label, $2 = max seconds, $3 = predicate function name (must echo 0/1).
# The predicate runs once per iteration; this canary's predicates each do
# their own curl + jq-equivalent and decide.
# ---------------------------------------------------------------------------
poll_until() {
  local label="$1" max="$2" pred="$3"
  local elapsed=0
  local rc
  while [ "$elapsed" -lt "$max" ]; do
    rc=0; "$pred" || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "  ok: $label (waited ${elapsed}s)"
      return 0
    fi
    # rc 2: the predicate saw a terminal failure; waiting cannot fix it.
    if [ "$rc" -eq 2 ]; then
      echo "X $label failed after ${elapsed}s" >&2
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "X $label not satisfied within ${max}s" >&2
  return 1
}

# wait_pr_clean <pr number> <max seconds>: 0 once GitHub reports the PR's
# mergeable_state as clean; 1 on timeout or as soon as a check run on its
# head fails (the failing names are printed).
wait_pr_clean() {
  local num="$1" max="$2" elapsed=0 verdict
  while [ "$elapsed" -lt "$max" ]; do
    verdict=$(curl -sS -H "Authorization: token $TOKEN" \
        "https://api.github.com/repos/$ACCOUNT/$NAME/pulls/$num" \
      | python3 -c 'import json, sys, urllib.request
pr = json.load(sys.stdin)
if pr.get("mergeable_state") == "clean":
    print("clean"); sys.exit()
req = urllib.request.Request("https://api.github.com/repos/%s/commits/%s/check-runs?per_page=100" % (sys.argv[2], pr["head"]["sha"]),
                             headers={"Authorization": "token " + sys.argv[1]})
bad = [c["name"] for c in json.load(urllib.request.urlopen(req)).get("check_runs", []) if c.get("conclusion") in ("failure", "timed_out", "cancelled")]
print("failed " + ",".join(bad) if bad else "wait " + str(pr.get("mergeable_state")))' "$TOKEN" "$ACCOUNT/$NAME" 2>/dev/null || echo "wait api")
    case "$verdict" in
      clean)    echo "  ok: PR #$num mergeable (waited ${elapsed}s)"; return 0 ;;
      failed*)  echo "X PR #$num check runs failed: ${verdict#failed }" >&2; return 1 ;;
    esac
    sleep 15; elapsed=$((elapsed + 15))
  done
  echo "X PR #$num not mergeable within ${max}s (last: $verdict)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Step 1 - seed the throwaway repo
# ---------------------------------------------------------------------------
if [ -z "$FROM_BRANCH" ]; then
  echo "-> seed mode: /generate (real 'Use this template' API)"
  GEN_URL=$(throwaway_create_from_template "$TOKEN" "$TEMPLATE_REPO" "$ACCOUNT" "$NAME") || exit 5
  echo "  created $GEN_URL"
else
  echo "-> seed mode: --from-branch '$FROM_BRANCH' (orphan-commit seed)"
  GEN_URL=$(throwaway_create_empty "$TOKEN" "$ACCOUNT" "$NAME") || exit 5
  echo "  created $GEN_URL (empty)"
  throwaway_seed_from_branch "$TOKEN" "$TEMPLATE_REPO" "$FROM_BRANCH" "$CLONE_URL" "$TEST_DIR" || exit 5
fi

# ---------------------------------------------------------------------------
# Step 2 - clone + activate hooks + seed dev branch
# ---------------------------------------------------------------------------
echo "-> waiting for throwaway content to be reachable"
throwaway_clone_with_retry "$CLONE_URL" "$TEST_DIR/repo" 30 >/dev/null || exit 5
cd "$TEST_DIR/repo"
git remote set-url origin "$CLONE_URL"
throwaway_adopt_identity "$ACCOUNT" || { echo "X no commit identity for $ACCOUNT" >&2; exit 5; }

echo "-> auto-activating hooks via scripts/heal.sh"
bash .io.v4rian.how-git/scripts/heal.sh >/dev/null

echo "-> creating dev + pushing"
git checkout -q -b dev
git push -q origin dev

# A seed taken from a branch of an off-grid framework repo carries
# MODE=off-grid; this canary drives the connected claim workflows, so the
# throwaway flips to connected (the canary token owns the throwaway, so it
# passes the admin gate) before bootstrap-ci wires the remote side.
if [ "$(bash .io.v4rian.how-git/bin/set-mode --get)" != "connected" ]; then
  echo "-> flipping the seed to connected mode"
  GH_TOKEN="$TOKEN" bash .io.v4rian.how-git/bin/set-mode connected >/dev/null
  git push -q origin dev
fi

# ---------------------------------------------------------------------------
# Step 3 - run bootstrap-ci to wire branch protection + claim workflows
#
# This is the binding step that switches the throwaway from "fresh template
# clone" to "operational v4rian repo". After this step the pr-merge-dev claim
# workflow + auto-rebase-pools-after-dev-merge.sh are wired and will fire on
# the PR merge later in the script. The bootstrap-ci CLI is idempotent and
# bootstraps the rulesets, required status checks, merge-commit defaults, and
# repo settings the model expects.
# ---------------------------------------------------------------------------
echo "-> running bin/bootstrap-ci to wire branch protection + claim workflows"
GH_TOKEN="$TOKEN" CLAUDE_TOKEN="$CLAUDE_TOKEN" bash .io.v4rian.how-git/bin/bootstrap-ci 2>&1 | sed 's/^/    /' || {
  echo "X bootstrap-ci failed; throwaway is not fully wired" >&2
  exit 5
}

# ---------------------------------------------------------------------------
# Scenario runners
# ---------------------------------------------------------------------------

# Run one parallel-PR scenario. $1 = scenario tag (positive / negative).
# Returns 0 on pass, non-zero on assertion failure.
# JSON body for a PR into dev. The Python sits in single quotes so the shell
# never brace-expands the dict literal, and the values travel as environment
# variables.
pr_payload() {
  PR_TITLE="$1" PR_BODY="$2" PR_HEAD="$3" python3 -c 'import json, os
print(json.dumps({"title": os.environ["PR_TITLE"], "body": os.environ["PR_BODY"],
                  "head": os.environ["PR_HEAD"], "base": "dev", "draft": False}))'
}

run_scenario() {
  local tag="$1"
  echo
  echo "=========================================================="
  echo "  Scenario: $tag"
  echo "=========================================================="

  # ---------------------------------------------------------------------------
  # Allocate two parallel pool branches via the canonical allocator CLI. Same
  # entry point a connected-mode operator uses (mirrors the off-grid e2e
  # discipline) - we never bare-checkout pool refs since that skips the paired
  # safety anchor and pins nN counters manually.
  # ---------------------------------------------------------------------------
  local short_a short_b
  if [ "$tag" = "positive" ]; then
    short_a="canary-a"; short_b="canary-b"
  else
    short_a="canary-x"; short_b="canary-y"
  fi

  echo "-> allocating pool A: $short_a"
  local alloc_a alloc_b
  # stdout carries the allocation JSON alone; progress goes to a side log.
  alloc_a=$(GH_TOKEN="$TOKEN" bash .io.v4rian.how-git/bin/create-pool-branch "$short_a" --no-jira --kind feature --json 2>"$TEST_DIR/alloc-$short_a.err") || {
    echo "X allocator failed for $short_a (exit $?):" >&2; echo "$alloc_a" >&2; sed 's/^/    /' "$TEST_DIR/alloc-$short_a.err" >&2; return 6
  }
  echo "$alloc_a" | sed 's/^/    /'
  local pool_a safety_a
  pool_a=$(printf '%s' "$alloc_a" | python3 -c "import json,sys; print(json.load(sys.stdin)['branch_name'])" 2>/dev/null || true)
  safety_a=$(printf '%s' "$alloc_a" | python3 -c "import json,sys; print(json.load(sys.stdin)['safety_name'])" 2>/dev/null || true)
  [ -n "$pool_a" ] && [ -n "$safety_a" ] || { echo "X allocator A returned no branch_name/safety_name" >&2; return 6; }

  echo "-> allocating pool B: $short_b"
  # stdout carries the allocation JSON alone; progress goes to a side log.
  alloc_b=$(GH_TOKEN="$TOKEN" bash .io.v4rian.how-git/bin/create-pool-branch "$short_b" --no-jira --kind feature --json 2>"$TEST_DIR/alloc-$short_b.err") || {
    echo "X allocator failed for $short_b (exit $?):" >&2; echo "$alloc_b" >&2; sed 's/^/    /' "$TEST_DIR/alloc-$short_b.err" >&2; return 6
  }
  echo "$alloc_b" | sed 's/^/    /'
  local pool_b safety_b
  pool_b=$(printf '%s' "$alloc_b" | python3 -c "import json,sys; print(json.load(sys.stdin)['branch_name'])" 2>/dev/null || true)
  safety_b=$(printf '%s' "$alloc_b" | python3 -c "import json,sys; print(json.load(sys.stdin)['safety_name'])" 2>/dev/null || true)
  [ -n "$pool_b" ] && [ -n "$safety_b" ] || { echo "X allocator B returned no branch_name/safety_name" >&2; return 6; }

  echo "  pool A: $pool_a"
  echo "  pool B: $pool_b"

  # ---------------------------------------------------------------------------
  # Commit on each pool branch. The positive scenario edits the SAME hunk on
  # the SAME line of CHANGELOG.md `## Unreleased` so a cherry-pick of one
  # commit onto a dev tip carrying the other guarantees a hunk-level conflict.
  # The negative scenario adds a deeper conflict on top: both branches also
  # delete the same file and re-add it with divergent content so L5
  # plausibly exhausts strategies.
  # ---------------------------------------------------------------------------
  git fetch -q origin
  echo "-> committing on $pool_a"
  git checkout -q "$pool_a"
  # Append the canary tag to CHANGELOG.md `## Unreleased`. Both pool branches
  # target the same insertion point so the resulting two commits collide at
  # the same hunk after one of them lands on dev.
  python3 - "$tag" "A" <<'PY'
import sys
tag, side = sys.argv[1], sys.argv[2]
p = ".io.v4rian.how-git/docs/CHANGELOG.md"
with open(p) as f:
    lines = f.readlines()
out = []
inserted = False
for ln in lines:
    out.append(ln)
    if not inserted and ln.startswith("## Unreleased"):
        out.append("\n")
        out.append("Parallel-PR canary tag %s side %s.\n" % (tag, side))
        inserted = True
with open(p, "w") as f:
    f.writelines(out)
PY
  if [ "$tag" = "negative" ]; then
    # Deeper conflict: both branches create canary-conflict.txt with
    # divergent bodies (an add/add conflict on a file the canary owns; the
    # framework's own docs stay intact, since its suites run as required
    # checks on these PRs). The combined cherry-pick of the
    # opposing branch onto the merged tip exhausts L1-L4 because both -X
    # theirs and -X ours preserve only one side's content; L5 has to
    # produce a hand-crafted resolution. The canary's assertion is on
    # the OUTCOME (reconcile branch + comment) regardless of which L-tier
    # resolved the conflict.
    printf 'Side A divergent body.\nSide A keeps its own second line.\n' > canary-conflict.txt
  fi
  git add -- .io.v4rian.how-git/docs/CHANGELOG.md
  if [ -f canary-conflict.txt ]; then git add -- canary-conflict.txt; fi
  git commit -q --no-verify -m "[REFACTOR] Canary $tag A appends Unreleased note"
  git push -q origin "$pool_a"

  echo "-> committing on $pool_b"
  git checkout -q "$pool_b"
  python3 - "$tag" "B" <<'PY'
import sys
tag, side = sys.argv[1], sys.argv[2]
p = ".io.v4rian.how-git/docs/CHANGELOG.md"
with open(p) as f:
    lines = f.readlines()
out = []
inserted = False
for ln in lines:
    out.append(ln)
    if not inserted and ln.startswith("## Unreleased"):
        out.append("\n")
        out.append("Parallel-PR canary tag %s side %s.\n" % (tag, side))
        inserted = True
with open(p, "w") as f:
    f.writelines(out)
PY
  if [ "$tag" = "negative" ]; then
    printf 'Side B divergent body.\nSide B keeps its own second line.\n' > canary-conflict.txt
  fi
  git add -- .io.v4rian.how-git/docs/CHANGELOG.md
  if [ -f canary-conflict.txt ]; then git add -- canary-conflict.txt; fi
  git commit -q --no-verify -m "[REFACTOR] Canary $tag B appends Unreleased note"
  git push -q origin "$pool_b"

  # ---------------------------------------------------------------------------
  # Open one PR per pool branch via the API. Both PRs target dev. We use
  # explicit POST /pulls so the script does not depend on the open-pr.sh
  # title-derivation - the canary asserts on the auto-rebase outcome, not
  # on PR title shape.
  # ---------------------------------------------------------------------------
  echo "-> opening PR A from $pool_a -> dev"
  local pr_a_resp pr_a_num
  pr_a_resp=$(curl -sS -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$(pr_payload "Canary $tag A" "$(bash .io.v4rian.how-git/scripts/lib/probe-merge-body.sh "canary-$tag-a")" "$pool_a")" \
    "https://api.github.com/repos/$ACCOUNT/$NAME/pulls")
  pr_a_num=$(echo "$pr_a_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))" 2>/dev/null || true)
  if [ -z "$pr_a_num" ]; then
    echo "X PR A open failed; response:" >&2
    echo "$pr_a_resp" | python3 -m json.tool >&2 || echo "$pr_a_resp" >&2
    return 5
  fi
  echo "  PR #$pr_a_num opened"

  echo "-> opening PR B from $pool_b -> dev"
  local pr_b_resp pr_b_num
  pr_b_resp=$(curl -sS -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$(pr_payload "Canary $tag B" "$(bash .io.v4rian.how-git/scripts/lib/probe-merge-body.sh "canary-$tag-b")" "$pool_b")" \
    "https://api.github.com/repos/$ACCOUNT/$NAME/pulls")
  pr_b_num=$(echo "$pr_b_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))" 2>/dev/null || true)
  if [ -z "$pr_b_num" ]; then
    echo "X PR B open failed; response:" >&2
    echo "$pr_b_resp" | python3 -m json.tool >&2 || echo "$pr_b_resp" >&2
    return 5
  fi
  echo "  PR #$pr_b_num opened"

  # ---------------------------------------------------------------------------
  # Wait until GitHub itself calls each PR mergeable: mergeable_state "clean"
  # means every required check bound by bootstrap-ci passed. The combined
  # commit status alone misses the Actions check runs (the framework suites
  # take about 15 minutes on a runner), so it read green while they ran.
  # A check run that concludes failure ends the wait at once with its names.
  # ---------------------------------------------------------------------------
  echo "-> waiting for PR #$pr_a_num to be mergeable (required checks green)"
  wait_pr_clean "$pr_a_num" 1800 || return 6
  echo "-> waiting for PR #$pr_b_num to be mergeable (required checks green)"
  wait_pr_clean "$pr_b_num" 1800 || return 6

  # ---------------------------------------------------------------------------
  # Merge PR A into dev via API (the merge that drives the pr-merge-dev claim +
  # auto-rebase-pools-after-dev-merge.sh). This is the exact action the
  # admin takes in the GitHub UI; the canary uses the API equivalent.
  # ---------------------------------------------------------------------------
  echo "-> merging PR #$pr_a_num"
  local merge_resp merge_sha
  merge_resp=$(curl -sS -X PUT \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json; print(json.dumps({'merge_method':'merge'}))")" \
    "https://api.github.com/repos/$ACCOUNT/$NAME/pulls/$pr_a_num/merge")
  merge_sha=$(echo "$merge_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || true)
  if [ -z "$merge_sha" ]; then
    echo "X PR merge failed; response:" >&2
    echo "$merge_resp" | python3 -m json.tool >&2 || echo "$merge_resp" >&2
    return 5
  fi
  echo "  merged at $merge_sha"

  # ---------------------------------------------------------------------------
  # Wait for the claim: the push of the merge to dev starts a ci-dispatch.yml
  # run whose pr-merge-dev trigger runs required.claim (amend, tag, vault,
  # auto-rebase). It must complete green; a claim that never finishes fails.
  # ---------------------------------------------------------------------------
  _claim_complete() {
    local state
    state=$(curl -sS -H "Authorization: token $TOKEN" \
      "https://api.github.com/repos/$ACCOUNT/$NAME/actions/workflows/ci-dispatch.yml/runs?event=push&branch=dev&head_sha=$merge_sha&per_page=5" \
      | python3 -c 'import json,sys
runs = json.load(sys.stdin).get("workflow_runs", [])
print("none" if not runs else ("busy" if any(r["status"] != "completed" for r in runs) else ",".join(sorted({r["conclusion"] or "" for r in runs}))))' 2>/dev/null || echo "none")
    case "$state" in
      success) return 0 ;;
      none|busy) return 1 ;;
      *) echo "X claim run on $merge_sha concluded: $state" >&2; return 2 ;;
    esac
  }
  echo "-> waiting for the pr-merge-dev claim run on $merge_sha"
  poll_until "claim run green" 1800 _claim_complete || return 6

  # ---------------------------------------------------------------------------
  # Verify the auto-rebase artifacts. The reconcile branch name follows the
  # pool/v<MAJOR>/n<N>.reconcile.<short> shape (or the legacy flat layout
  # for older repos). We list refs that match either prefix and bind to the
  # original pool B's nN counter so a flaky claim run doesn't break the
  # assertion on an off-by-one nN.
  # ---------------------------------------------------------------------------
  local pool_b_n
  pool_b_n=$(printf '%s' "$pool_b" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?(n[0-9]+)\..*|\2|')
  local short_for_pool_b
  short_for_pool_b=$(printf '%s' "$pool_b" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?n[0-9]+\.[a-z&]+\.||')

  if [ -z "$CLAUDE_TOKEN" ]; then
    # No Claude on the runner: the L1-L5 ladder cannot resolve the conflict,
    # and the framework's contract is to push no empty reconcile, leave PR B
    # open and say so on it. That is what this run can prove.
    echo "-> no --claude-token: checking the degraded reconcile contract"
    git fetch -q origin 2>/dev/null || true
    if git ls-remote --heads origin "pool/*${pool_b_n}.reconcile.${short_for_pool_b}*" 2>/dev/null | grep -q reconcile; then
      echo "X an unresolved reconcile branch was pushed for $pool_b_n.$short_for_pool_b" >&2; return 6
    fi
    local pr_b_open empty_comment
    pr_b_open=$(curl -sS -H "Authorization: token $TOKEN" "https://api.github.com/repos/$ACCOUNT/$NAME/pulls/$pr_b_num" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true)
    [ "$pr_b_open" = "open" ] || { echo "X PR #$pr_b_num expected open, got: $pr_b_open" >&2; return 6; }
    empty_comment=$(curl -sS -H "Authorization: token $TOKEN" "https://api.github.com/repos/$ACCOUNT/$NAME/issues/$pr_b_num/comments?per_page=50" \
      | python3 -c 'import json,sys; print(sum("EMPTY reconcile" in c.get("body","") for c in json.load(sys.stdin)))' 2>/dev/null || echo 0)
    [ "${empty_comment:-0}" -ge 1 ] || { echo "X no EMPTY reconcile comment on PR #$pr_b_num" >&2; return 6; }
    echo "  no reconcile pushed, PR #$pr_b_num open, EMPTY reconcile comment present (AI resolution not exercised)"
    echo
    echo "  scenario '$tag': PASS (degraded, no Claude token)"
    return 0
  fi

  echo "-> verifying reconcile branch for $pool_b_n.$short_for_pool_b"
  _reconcile_branch_present() {
    git fetch -q origin 2>/dev/null || true
    git ls-remote --heads origin "pool/*${pool_b_n}.reconcile.${short_for_pool_b}*" 2>/dev/null \
      | awk '{print $2}' | grep -q reconcile
  }
  if ! poll_until "reconcile branch present for $pool_b_n.$short_for_pool_b" 600 _reconcile_branch_present; then
    echo "X no reconcile branch found for $pool_b_n.$short_for_pool_b on origin" >&2
    return 6
  fi
  local recon_branch
  recon_branch=$(git ls-remote --heads origin "pool/*${pool_b_n}.reconcile.${short_for_pool_b}*" \
    | awk '{print $2}' | sed 's|^refs/heads/||' | head -1)
  echo "  reconcile branch: $recon_branch"

  # ---------------------------------------------------------------------------
  # Verify PR B is still open (NEVER auto-closed; the original pool branch is
  # the developer's record per feedback_how_git_never_rewrites_history).
  # ---------------------------------------------------------------------------
  echo "-> verifying PR #$pr_b_num still open"
  local pr_b_state
  pr_b_state=$(curl -sS -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$ACCOUNT/$NAME/pulls/$pr_b_num" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)
  if [ "$pr_b_state" != "open" ]; then
    echo "X PR #$pr_b_num expected open, got: $pr_b_state" >&2
    return 6
  fi
  echo "  state: open"

  # ---------------------------------------------------------------------------
  # Verify the auto-rebase comment landed on PR B. We just require any
  # comment from the auto-rebase pass to be present and to mention the
  # reconcile branch by name - that is the user-visible receipt the canary
  # guards against the D-3 class of regression where dev advances but no
  # reconcile candidate is produced.
  # ---------------------------------------------------------------------------
  echo "-> verifying auto-rebase comment landed on PR #$pr_b_num"
  local comment_count
  comment_count=$(curl -sS -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$ACCOUNT/$NAME/issues/$pr_b_num/comments?per_page=50" \
    | RECON="$recon_branch" python3 -c "
import json, sys, os
recon = os.environ['RECON']
total = 0
for c in json.load(sys.stdin):
    if recon in c.get('body',''):
        total += 1
print(total)
" 2>/dev/null || echo "0")
  if [ "${comment_count:-0}" -lt 1 ]; then
    echo "X no comment on PR #$pr_b_num references the reconcile branch $recon_branch" >&2
    return 6
  fi
  echo "  comment present (mentions $recon_branch)"

  # ---------------------------------------------------------------------------
  # For the POSITIVE scenario, also verify the reconcile branch tip carries
  # pool B's content intent. For the NEGATIVE scenario the reconcile branch
  # may carry partial content from L5; either way the receipt above is the
  # acceptance criteria.
  # ---------------------------------------------------------------------------
  if [ "$tag" = "positive" ]; then
    echo "-> verifying reconcile branch tip carries pool B intent"
    git fetch -q origin "$recon_branch:refs/remotes/origin/$recon_branch" 2>/dev/null || true
    local content
    content=$(git show "origin/$recon_branch:.io.v4rian.how-git/docs/CHANGELOG.md" 2>/dev/null || echo "")
    if ! echo "$content" | grep -q "Parallel-PR canary tag positive side B"; then
      echo "X reconcile branch $recon_branch does not carry pool B's CHANGELOG entry" >&2
      return 6
    fi
    echo "  reconcile branch carries pool B intent"
  fi

  echo
  echo "  scenario '$tag': PASS"
  return 0
}

# ---------------------------------------------------------------------------
# Run scenarios per the flags
# ---------------------------------------------------------------------------
if ! $NEGATIVE_ONLY; then
  run_scenario positive || exit 6
fi
if ! $POSITIVE_ONLY; then
  run_scenario negative || exit 6
fi

# ---------------------------------------------------------------------------
# Cleanup (delete throwaway unless --keep)
# ---------------------------------------------------------------------------
cd /tmp
if $KEEP; then
  echo "-> --keep set; throwaway left alive at $GEN_URL"
else
  echo "-> deleting throwaway $ACCOUNT/$NAME"
  DEL_CODE=$(throwaway_delete "$TOKEN" "$ACCOUNT" "$NAME")
  case "$DEL_CODE" in
    204) echo "  deleted" ;;
    403) echo "  (token lacks delete_repo scope; throwaway left at $GEN_URL - delete manually or re-run with broader token)" ;;
    404) echo "  (already gone)" ;;
    *)   echo "  (unexpected status $DEL_CODE; throwaway may still exist at $GEN_URL)" ;;
  esac
fi

echo "ok: parallel-pr auto-heal canary passed end-to-end"
