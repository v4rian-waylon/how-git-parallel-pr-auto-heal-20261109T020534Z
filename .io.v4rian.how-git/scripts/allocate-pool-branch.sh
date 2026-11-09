#!/usr/bin/env bash
# allocate-pool-branch.sh - canonical v4rian pool branch allocator.
#
# Single source of truth for atomic creation of a pool/nN.kind.* branch
# and its paired safety/nN.kind.* anchor. Invoked from:
#
#   - .github/workflows/allocate-pool-branch.yml (repository_dispatch
#     from JIRA Automation, or workflow_dispatch from a human admin)
#   - bin/create-pool-branch (local CLI wrapper: in connected mode it
#     triggers the workflow above via `gh workflow run`; in off-grid mode
#     it runs this script locally with ALLOC_MODE=off-grid)
#
# Behavior:
#
#   1. Parses inputs (kind, short_name, jira_key, sprint). kind is
#      optional; when absent it is classified via the Claude API from
#      the JIRA payload. short_name and jira_key are required.
#   2. Idempotency: scans existing pool/*, safety/*, vault/* refs for
#      the JIRA key (both flat and vYYYY.MAIN/-prefixed layouts). If
#      found, prints the existing branch URL on stdout (as JSON) and
#      exits 0 with no mutation.
#   3. Allocates the next nN as 1 + the highest number already spent,
#      across both layouts, so a number is never handed out twice. Spent
#      means any of: a pool/, safety/ or vault/ ref (local heads, plus the
#      remote-tracking refs of the remote dev tracks: branch.dev.remote,
#      else origin, else the only remote, with a notice whenever the
#      choice is not branch.dev.remote; other remotes are ignored, and
#      several remotes without origin count local refs only, said so on
#      stderr); a landing subject
#      "[MERGE] pool/.../nN. ..." anywhere in local branches, tags, that
#      remote and HEAD; an off-grid reservation refs/how-git/allocated/nN.
#      Ids are contiguous within the active claim series (bin/version
#      --seal, vYYYY.S): a landing subject sealed ": vYYYY.S.D" in another
#      series is not counted, and preflight-bak* backup branches (local or
#      on the remote) land nothing, so their subjects are not counted.
#      Connected mode lists refs through the API and reads the
#      landing subjects from the workflow's full history checkout.
#      Off-grid only, before counting:
#        - refuses (exit 2) a shallow clone or a single-branch clone,
#          printing every repair in one message (`git fetch --unshallow`,
#          `git remote set-branches`);
#        - fetches the tracked remote under a watchdog that ends the
#          fetch process group after ALLOC_FETCH_TIMEOUT seconds (30 by
#          default; perl, present with git on every platform); when the
#          fetch fails or times out (or with --no-fetch) it still
#          allocates and prints how old its view is (last fetch, the
#          clone, or unknown), since another clone may have spent the
#          number;
#        - creates refs/how-git/allocated/nN in the same update-ref
#          transaction as the pair, so two allocations racing in one
#          clone (lanes are worktrees sharing refs) never get the same
#          number: the loser recounts and retries, and a racer that
#          meets the winner's lock mid-commit waits up to
#          ALLOC_LOCK_WAIT_SECONDS before retrying. Two separate clones
#          are serialized only by the fetch, so a window remains between
#          one clone's fetch and the other's push.
#      Reservations are names, not snapshots: each points at dev's root
#      commit, which dev keeps alive until a rewrite that changes the
#      root; then the reservation keeps that one old root (a few objects,
#      never a history) until it is pruned. They live outside refs/heads, so a normal push or fetch
#      never carries them, and the pre-push hook refuses any push that
#      would (explicit refspec or --mirror). After each off-grid
#      allocation, reservations below the highest number the tracked
#      remote or a local vault ref records are pruned.
#   4. Derives the vYYYY.MAIN major-version prefix from bin/version
#      --seal at allocation time (e.g. v2026.0.47 -> v2026.0) so the
#      same release-line classification that the vault and archived
#      safety paths carry applies from allocation onward. When the
#      seal is unreachable or unparseable, falls back to the legacy
#      flat layout for offline-test and bootstrap scenarios.
#   5. Composes the branch name as
#      pool/<vYYYY.MAIN>/nN.{kind}.[sprintX-]JIRA-NNN-{slug} (or the
#      legacy flat pool/nN.* when the prefix could not be derived),
#      then validates max ref length (255 chars).
#   6. Resolves current dev HEAD SHA via the Git Data API.
#   7. Creates pool/* and safety/* at that SHA atomically via POST
#      /repos/{owner}/{repo}/git/refs. If safety creation fails after
#      pool was already created, the pool is deleted and the operation
#      reported as partial_pair_rollback.
#   8. Prints JSON {branch_name, safety_name, branch_url, safety_url,
#      sha, kind, jira_key, major_prefix} to stdout for caller
#      consumption.
#
# All claude classification requests use aggressive exponential backoff
# capped at 5 minutes between attempts; the workflow timeout (4320
# minutes) is the only ceiling. The expected real-world finish is
# seconds.
#
# Required environment:
#
#   GITHUB_REPOSITORY  owner/repo (auto-set in GitHub Actions; pass
#                      explicitly when running locally). REQUIRED in
#                      connected mode; IGNORED in off-grid mode.
#   GH_TOKEN           token with contents:write on the repo. REQUIRED
#                      in connected mode; IGNORED in off-grid mode.
#   ANTHROPIC_API_KEY  required only if kind classification is needed
#                      (kind input is empty)
#
# Required input env (or --flag form when invoked directly):
#
#   ALLOC_SHORT_NAME                      required
#   ALLOC_JIRA_KEY                        required UNLESS ALLOC_NO_JIRA=1
#                                         (or --no-jira). Both modes
#                                         (connected + off-grid) accept
#                                         the no-jira path; in connected
#                                         mode the workflow's admin gate
#                                         is the authorization.
#   ALLOC_NO_JIRA                         optional, set to "1" to omit
#                                         the JIRA segment from the branch
#                                         name. Idempotency-by-JIRA is
#                                         skipped when no JIRA key is
#                                         supplied. Works in both modes.
#   ALLOC_KIND                            optional (classified if absent)
#   ALLOC_SPRINT                          optional
#   ALLOC_JIRA_TITLE, ALLOC_JIRA_DESC     optional, used as classification
#                                         context when ALLOC_KIND is absent
#   ALLOC_MODE                            optional, "connected" (default)
#                                         or "off-grid". In off-grid mode
#                                         the allocator skips the GitHub
#                                         Git Data API entirely and creates
#                                         the pool+safety pair atomically
#                                         via `git update-ref --stdin` in
#                                         the local repo. The requirement
#                                         commit (when supplied) is built
#                                         via local git plumbing
#                                         (hash-object, mktree, commit-tree).
#                                         Off-grid replicates the connected
#                                         operator workflow exactly; only
#                                         the under-the-hood implementation
#                                         differs.
#   ALLOC_REQUIREMENT                     optional, the active-requirement
#                                         text for the branch (verbatim).
#                                         When supplied, the allocator
#                                         writes it to
#                                         .io.v4rian.how-git/requirements/<pool ref, / as __>
#                                         and creates the initial [REQ]
#                                         commit on the pool branch with the
#                                         requirement text as the body. The
#                                         safety anchor stays at the dev
#                                         tip (no requirement commit) so it
#                                         remains the pristine fork point.
#   ALLOC_REQUIREMENT_FILE                optional, path to a file whose
#                                         content is the requirement text.
#                                         Overrides ALLOC_REQUIREMENT when
#                                         both are set.
#   ALLOC_FETCH_TIMEOUT                   optional, seconds before the
#                                         off-grid fetch is stopped and the
#                                         allocation goes offline (30).
#   ALLOC_LOCK_WAIT_SECONDS               optional, seconds an off-grid
#                                         allocation keeps retrying while
#                                         another git process holds a ref
#                                         lock it needs (default 20)
#   ALLOC_NO_FETCH                        optional, set to "1" (or pass
#                                         --no-fetch) to skip the off-grid
#                                         fetch of the tracked remote, for
#                                         an air-gapped clone; the
#                                         staleness notice still prints.

set -euo pipefail

# Shared helpers: the kind set (HG_BRANCH_KINDS), the per-lane requirement
# path, and the message scrub. _lib.sh defines functions and constants only.
# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
KINDS_TEXT=$(printf '%s' "$HG_BRANCH_KINDS" | sed 's/|/, /g')

# ---------------------------------------------------------------------------
# Argument parsing - accept env vars (workflow path) or --flags (direct path)
# ---------------------------------------------------------------------------
KIND="${ALLOC_KIND:-}"
SHORT="${ALLOC_SHORT_NAME:-}"
JIRA="${ALLOC_JIRA_KEY:-}"
SPRINT="${ALLOC_SPRINT:-}"
JIRA_TITLE="${ALLOC_JIRA_TITLE:-}"
JIRA_DESC="${ALLOC_JIRA_DESC:-}"
REQUIREMENT="${ALLOC_REQUIREMENT:-}"
REQUIREMENT_FILE="${ALLOC_REQUIREMENT_FILE:-}"
REPO_FULL="${GITHUB_REPOSITORY:-}"
MODE="${ALLOC_MODE:-connected}"
NO_JIRA="${ALLOC_NO_JIRA:-0}"
NO_FETCH="${ALLOC_NO_FETCH:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --kind)              KIND="$2"; shift 2 ;;
    --short-name)        SHORT="$2"; shift 2 ;;
    --jira)              JIRA="$2"; shift 2 ;;
    --sprint)            SPRINT="$2"; shift 2 ;;
    --jira-title)        JIRA_TITLE="$2"; shift 2 ;;
    --jira-desc)         JIRA_DESC="$2"; shift 2 ;;
    --requirement)       REQUIREMENT="$2"; shift 2 ;;
    --requirement-file)  REQUIREMENT_FILE="$2"; shift 2 ;;
    --repo)              REPO_FULL="$2"; shift 2 ;;
    --mode)              MODE="$2"; shift 2 ;;
    --no-jira)           NO_JIRA="1"; shift ;;
    --no-fetch)          NO_FETCH="1"; shift ;;
    -h|--help)
      # The whole leading comment block, however long it grows.
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) echo "allocate-pool-branch: unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$MODE" in
  connected|off-grid) ;;
  *) echo "allocate-pool-branch: invalid mode '$MODE' (expected: connected or off-grid)" >&2; exit 2 ;;
esac

# --requirement-file (if supplied) overrides --requirement.
if [ -n "$REQUIREMENT_FILE" ]; then
  if [ ! -f "$REQUIREMENT_FILE" ]; then
    echo "allocate-pool-branch: requirement file '$REQUIREMENT_FILE' does not exist" >&2
    exit 2
  fi
  REQUIREMENT=$(cat "$REQUIREMENT_FILE")
fi

# ---------------------------------------------------------------------------
# Required input validation. The GitHub API inputs (GITHUB_REPOSITORY,
# GH_TOKEN) are connected-mode requirements only; off-grid mutates local
# refs and needs neither. JIRA is required by default in both modes
# because the connected path always carries a key (JIRA Automation
# supplies it; admin workflow_dispatch enforces it). The --no-jira escape
# hatch is off-grid-only: JIRA Automation does not exist in off-grid so
# the key has no upstream source. When --no-jira is set the branch name
# omits the JIRA segment entirely (per the optional ([A-Z]+-[0-9]+-)?
# group in the pre-push regex); idempotency-by-JIRA is also skipped.
# ---------------------------------------------------------------------------
if [ "$MODE" = "connected" ]; then
  if [ -z "$REPO_FULL" ]; then
    echo "allocate-pool-branch: GITHUB_REPOSITORY (or --repo) is required in connected mode" >&2
    exit 2
  fi
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "allocate-pool-branch: GH_TOKEN is required in connected mode" >&2
    exit 2
  fi
  # NO_JIRA is allowed in both modes - connected-mode authorization for
  # the no-jira path is the workflow's admin gate (the JIRA Automation
  # entry point always carries a key; the workflow_dispatch entry point
  # is admin-only and accepts the no_jira input).
fi
if [ -z "$SHORT" ]; then
  echo "allocate-pool-branch: short_name is required" >&2
  exit 2
fi
if [ "$NO_JIRA" != "1" ]; then
  if [ -z "$JIRA" ]; then
    echo "allocate-pool-branch: jira_key is required (or pass --no-jira to omit the JIRA segment)" >&2
    exit 2
  fi
  if ! [[ "$JIRA" =~ ^[A-Z]+-[0-9]+$ ]]; then
    echo "allocate-pool-branch: jira_key '$JIRA' must match PROJ-NNN" >&2
    exit 2
  fi
fi
if [ -n "$SPRINT" ] && ! [[ "$SPRINT" =~ ^[0-9]+$ ]]; then
  echo "allocate-pool-branch: sprint '$SPRINT' must be a positive integer" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Slug the short_name into branch-name safe form (lowercase, hyphens only)
# ---------------------------------------------------------------------------
slug_short() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | sed -E 's/-+/-/g'
}
SHORT_SLUG=$(slug_short "$SHORT")
if [ -z "$SHORT_SLUG" ]; then
  echo "allocate-pool-branch: short_name slugs to empty" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Mode-dispatched ref-listing helpers. Connected mode queries the GitHub
# Git Data API; off-grid mode reads local refs via git for-each-ref. Both
# emit the same one-ref-per-line stream so downstream consumers
# (next_n, idempotency scan) stay layout-agnostic.
# ---------------------------------------------------------------------------
api() {
  curl -sS \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

# The remote dev tracks (branch.dev.remote) is this repository's shared
# record. Other remotes (the framework, a fork, a colleague's clone) carry
# their own sequences, so neither their refs nor their landing subjects are
# counted. When branch.dev.remote is unset or not a configured remote (git
# writes "." when dev tracks a LOCAL branch), the counter falls back to
# origin, else to the only remote; with several remotes and no origin there
# is no safe choice. Every fallback but the plain unset-to-origin one says
# so on stderr (off-grid), because a silently dropped remote reissues
# numbers. Empty when no remote is chosen.
DEV_REMOTE=$(git config --get branch.dev.remote 2>/dev/null || true)
TRACKED_REMOTE=""
REMOTE_NOTICE=""
if [ -n "$DEV_REMOTE" ] && git remote get-url "$DEV_REMOTE" >/dev/null 2>&1; then
  TRACKED_REMOTE="$DEV_REMOTE"
else
  ALL_REMOTES=$(git remote 2>/dev/null || true)
  REMOTE_COUNT=$(printf '%s\n' "$ALL_REMOTES" | grep -c . || true)
  if git remote get-url origin >/dev/null 2>&1; then
    TRACKED_REMOTE=origin
  elif [ "$REMOTE_COUNT" = "1" ]; then
    TRACKED_REMOTE="$ALL_REMOTES"
  fi
  if [ -n "$TRACKED_REMOTE" ] && [ -n "$DEV_REMOTE" ]; then
    REMOTE_NOTICE="dev tracks '$DEV_REMOTE', not a remote; counting remote '$TRACKED_REMOTE'"
  elif [ -n "$TRACKED_REMOTE" ] && [ "$TRACKED_REMOTE" != "origin" ]; then
    REMOTE_NOTICE="dev tracks no remote and there is no origin; counting remote '$TRACKED_REMOTE', the only one"
  elif [ -z "$TRACKED_REMOTE" ] && [ "${REMOTE_COUNT:-0}" -gt 1 ]; then
    REMOTE_NOTICE="dev tracks no remote and the remotes ($(printf '%s' "$ALL_REMOTES" | tr '\n' ' ' | sed 's/ *$//')) include no origin; counting local refs and history only. Set branch.dev.remote to the shared remote."
  fi
fi
if [ "$MODE" = "off-grid" ] && [ -n "$REMOTE_NOTICE" ]; then
  echo "allocate-pool-branch: $REMOTE_NOTICE" >&2
fi

# ---------------------------------------------------------------------------
# Off-grid visibility gate. The off-grid counter is only as good as what the
# clone can see: a shallow clone hides every landing below its boundary and a
# single-branch clone never receives the pool, safety and vault refs, and both
# used to hand out n1 with exit 0. Refuse instead of guessing, and name the
# command that repairs the clone.
# ---------------------------------------------------------------------------
if [ "$MODE" = "off-grid" ]; then
  IS_SHALLOW=0
  IS_PARTIAL=0
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] && IS_SHALLOW=1
  if [ -n "$TRACKED_REMOTE" ] && ! git config --get-all "remote.$TRACKED_REMOTE.fetch" 2>/dev/null \
       | grep -qE '^\+?refs/(heads/)?\*:'; then
    IS_PARTIAL=1
  fi
  # Both are checked before refusing, so a --depth clone (which is also
  # single-branch) gets every repair in one message.
  if [ "$IS_SHALLOW" = "1" ]; then
    echo "allocate-pool-branch: refusing to allocate off-grid from a shallow clone: landings below the shallow boundary are invisible, so a spent number could be reissued." >&2
  fi
  if [ "$IS_PARTIAL" = "1" ]; then
    echo "allocate-pool-branch: refusing to allocate off-grid: remote '$TRACKED_REMOTE' fetches only some branches (single-branch clone), so its pool, safety and vault refs are invisible." >&2
  fi
  if [ "$IS_SHALLOW" = "1" ] && [ "$IS_PARTIAL" = "1" ]; then
    echo "  Run: git remote set-branches $TRACKED_REMOTE '*' && git fetch --unshallow $TRACKED_REMOTE" >&2
  elif [ "$IS_SHALLOW" = "1" ]; then
    echo "  Run: git fetch --unshallow ${TRACKED_REMOTE:-origin}" >&2
  elif [ "$IS_PARTIAL" = "1" ]; then
    echo "  Run: git remote set-branches $TRACKED_REMOTE '*' && git fetch $TRACKED_REMOTE" >&2
  fi
  [ "$IS_SHALLOW" = "1" ] || [ "$IS_PARTIAL" = "1" ] && exit 2
fi

# ---------------------------------------------------------------------------
# Off-grid freshness. Remote-tracking refs are only as new as the last fetch,
# so a clone that has not fetched since another clone pushed nN would hand
# out nN again. Fetch the tracked remote first (no prune: a stale tracking
# ref is extra evidence of a spent number, never a reason to forget one).
# Offline, or with --no-fetch, allocation still runs and says how old its
# view of the remote is. No terminal prompt and the run_bounded watchdog keep
# an unreachable remote from hanging the allocation.
# ---------------------------------------------------------------------------
# view_age: how old this clone's view of the tracked remote is, as a phrase
# for "counting refs as of <phrase>". A successful fetch writes FETCH_HEAD;
# a failed one leaves it empty; a clone that never fetched has none, and its
# view is dated by the clone (packed-refs, written by git clone).
file_time() {
  stat -c '%y' "$1" 2>/dev/null || stat -f '%Sm' "$1" 2>/dev/null || echo "unknown time"
}
view_age() {
  local f p
  f=$(git rev-parse --git-path FETCH_HEAD 2>/dev/null)
  if [ -n "$f" ] && [ -s "$f" ]; then
    echo "the last fetch ($(file_time "$f"))"
  elif [ -n "$f" ] && [ -e "$f" ]; then
    echo "an unknown time (the last fetch attempt failed)"
  else
    p=$(git rev-parse --git-path packed-refs 2>/dev/null)
    if [ -n "$p" ] && [ -f "$p" ]; then
      echo "the clone ($(file_time "$p"))"
    else
      echo "an unknown time (no fetch recorded)"
    fi
  fi
}
# run_bounded SECONDS CMD...: run CMD in its own process group and end the
# whole group (TERM, then KILL after 2 s) when it outlives SECONDS; exit 124
# then. git has no connect timeout for http, so a black-holed https remote
# otherwise waits for the OS TCP timeout and a remote that never answers
# waits forever. Perl does the watchdog because it ships with macOS and with
# git on every platform, while timeout(1) is GNU only. Without perl the
# command runs unbounded and the caller is told.
run_bounded() {
  local secs="$1"; shift
  if ! command -v perl >/dev/null 2>&1; then
    echo "allocate-pool-branch: perl not found; the fetch runs without a time bound" >&2
    "$@"
    return
  fi
  perl -e '
    my $t = shift @ARGV;
    my $pid = fork;
    exit 127 unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
    setpgrp($pid, $pid);
    my $stop = sub {
      kill "TERM", -$pid;
      for (1 .. 20) { last unless kill 0, -$pid; select(undef, undef, undef, 0.1); }
      kill "KILL", -$pid;
      waitpid $pid, 0;
      exit $_[0];
    };
    $SIG{ALRM} = sub { $stop->(124) };
    $SIG{INT}  = sub { $stop->(130) };
    $SIG{TERM} = sub { $stop->(143) };
    alarm $t;
    waitpid $pid, 0;
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' "$secs" "$@"
}
FETCH_TIMEOUT="${ALLOC_FETCH_TIMEOUT:-30}"
case "$FETCH_TIMEOUT" in
  ''|*[!0-9]*|0) echo "allocate-pool-branch: ALLOC_FETCH_TIMEOUT must be a positive integer (seconds)" >&2; exit 2 ;;
esac

if [ "$MODE" = "off-grid" ] && [ -n "$TRACKED_REMOTE" ]; then
  # Read before fetching: a failed fetch rewrites FETCH_HEAD too.
  LAST_FETCH=$(view_age)
  if [ "$NO_FETCH" = "1" ]; then
    echo "allocate-pool-branch: fetch skipped (--no-fetch); counting refs of '$TRACKED_REMOTE' as of $LAST_FETCH" >&2
  else
    # An operator's own GIT_SSH_COMMAND or core.sshCommand wins untouched.
    if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "$(git config --get core.sshCommand 2>/dev/null || true)" ]; then
      export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
    fi
    FETCH_RC=0
    FETCH_ERR=$(GIT_TERMINAL_PROMPT=0 run_bounded "$FETCH_TIMEOUT" \
          git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
          fetch --quiet --no-prune "$TRACKED_REMOTE" 2>&1) || FETCH_RC=$?
    if [ "$FETCH_RC" = "0" ]; then
      echo "→ fetched '$TRACKED_REMOTE' before counting" >&2
    else
      [ "$FETCH_RC" = "124" ] && FETCH_ERR="fetch stopped after ${FETCH_TIMEOUT}s (ALLOC_FETCH_TIMEOUT)"
      echo "allocate-pool-branch: offline: could not fetch '$TRACKED_REMOTE'; counting refs as of $LAST_FETCH. Another clone may have spent the next number since." >&2
      printf '%s\n' "$FETCH_ERR" | grep -v '^[[:space:]]*$' | head -3 | sed 's/^/    /' >&2 || true
    fi
  fi
fi

list_refs_for_prefix() {
  local prefix="$1"
  if [ "$MODE" = "off-grid" ]; then
    # ** is required (not *) so the glob traverses the optional
    # vYYYY.MAIN/ segment introduced by the prefixed layout. A bare *
    # only matches a single path segment and silently misses
    # pool/v2026.0/n3.* style refs.
    #
    # Remote-tracking refs are walked alongside the local heads, and must be:
    # a fresh clone has every pool branch under refs/remotes/origin/ and NONE
    # under refs/heads/, so a local-only scan finds nothing and hands out n1
    # again, colliding with a counter the repository has already spent. The
    # remote name is stripped so both sets compare as the same shape, and the
    # scan stays offline (no API call) either way.
    { git for-each-ref --format='%(refname:short)' "refs/heads/$prefix**" 2>/dev/null || true
      if [ -n "$TRACKED_REMOTE" ]; then
        git for-each-ref --format='%(refname)' "refs/remotes/$TRACKED_REMOTE/$prefix**" 2>/dev/null \
          | sed "s|^refs/remotes/$TRACKED_REMOTE/||" || true
      fi
    } | sort -u
  else
    api "https://api.github.com/repos/$REPO_FULL/git/matching-refs/heads/$prefix" \
      | grep -oE '"ref":[[:space:]]*"refs/heads/[^"]+"' \
      | sed -E 's|.*"refs/heads/([^"]+)".*|\1|'
  fi
}

existing_with_jira() {
  local jira="$1"
  { list_refs_for_prefix "pool/"
    list_refs_for_prefix "safety/"
    list_refs_for_prefix "vault/"
  } | grep -E "(^|[^A-Z0-9])${jira}([^0-9]|$)" || true
}

# Skip idempotency-by-JIRA when --no-jira is set (no key to match against).
if [ "$NO_JIRA" = "1" ]; then
  EXISTING=""
else
  EXISTING=$(existing_with_jira "$JIRA")
fi
if [ -n "$EXISTING" ]; then
  echo "→ idempotent no-op: refs containing $JIRA already exist" >&2
  echo "$EXISTING" | sed 's/^/    /' >&2
  EXISTING_POOL=$(printf '%s\n' "$EXISTING" | grep '^pool/' | head -1 || true)
  if [ -n "$EXISTING_POOL" ]; then
    if [ "$MODE" = "off-grid" ]; then
      EXISTING_URL="file://$(git rev-parse --show-toplevel)#$EXISTING_POOL"
    else
      EXISTING_URL="https://github.com/$REPO_FULL/tree/$EXISTING_POOL"
    fi
    cat <<JSON
{
  "status": "no-op",
  "branch_name": "$EXISTING_POOL",
  "branch_url": "$EXISTING_URL",
  "jira_key": "$JIRA",
  "reason": "ref containing JIRA key already exists"
}
JSON
  else
    cat <<JSON
{
  "status": "no-op",
  "branch_name": null,
  "branch_url": null,
  "jira_key": "$JIRA",
  "reason": "ref containing JIRA key already exists (no pool match; safety or vault)"
}
JSON
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Kind classification via Claude API when --kind was not supplied
# ---------------------------------------------------------------------------
classify_kind_via_claude() {
  local title="$1"
  local desc="$2"
  local key="${ANTHROPIC_API_KEY:-}"
  if [ -z "$key" ]; then
    echo "allocate-pool-branch: ANTHROPIC_API_KEY required to classify kind" >&2
    return 1
  fi
  local prompt
  prompt=$(printf '%s\n\n%s\n\n%s\n\n%s' \
    "Classify the following JIRA ticket into exactly one of: ${KINDS_TEXT}." \
    "Title: ${title:-(none)}" \
    "Description: ${desc:-(none)}" \
    "Reply with ONLY the single classification token, lowercase, no other text.")
  local body
  body=$(printf '{"model":"claude-opus-4-5","max_tokens":32,"messages":[{"role":"user","content":%s}]}' \
    "$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
  local attempt=1
  local delay=2
  local cap=300
  while true; do
    local resp
    resp=$(curl -sS \
      -H "x-api-key: $key" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      --data "$body" \
      https://api.anthropic.com/v1/messages 2>&1) || resp=""
    local extracted
    extracted=$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    parts = d.get("content", [])
    text = "".join(p.get("text","") for p in parts if p.get("type")=="text").strip().lower()
    print(text)
except Exception:
    pass
' 2>/dev/null || true)
    if hg_kind_ok "$extracted"; then
      printf '%s' "$extracted"
      return 0
    fi
    echo "  · claude classification attempt $attempt failed (got: ${extracted:-<empty>}); backing off ${delay}s" >&2
    sleep "$delay"
    delay=$(( delay * 2 ))
    [ "$delay" -gt "$cap" ] && delay=$cap
    attempt=$(( attempt + 1 ))
  done
}

if [ -z "$KIND" ]; then
  echo "→ kind not supplied; classifying via Claude from JIRA payload" >&2
  KIND=$(classify_kind_via_claude "$JIRA_TITLE" "$JIRA_DESC")
fi

if ! hg_kind_ok "$KIND"; then
  echo "allocate-pool-branch: invalid kind '$KIND' (must be $HG_BRANCH_KINDS)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Derive the vYYYY.MAIN major-version prefix from bin/version --seal so the
# branch lands under the same release-line classification that vault/* and
# archived safety/* already carry. The seal output is vYYYY.MAIN.DEV; trim
# the trailing .DEV segment via parameter expansion. When the seal binary
# is unreachable (running outside a repo clone, offline tests, bootstrap
# scenarios) or returns an unparseable value, the script falls back to the
# legacy flat layout so existing tooling keeps working.
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")
VERSION_BIN=""
if [ -n "$SCRIPT_DIR" ] && [ -x "$SCRIPT_DIR/../bin/version" ]; then
  VERSION_BIN="$SCRIPT_DIR/../bin/version"
fi
MAJOR_PREFIX=""
if [ -n "$VERSION_BIN" ]; then
  SEAL=$("$VERSION_BIN" --seal 2>/dev/null | tr -d '\r\n')
  if [[ "$SEAL" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    MAJOR_PREFIX="${SEAL%.*}"
  fi
fi

# ---------------------------------------------------------------------------
# Allocate next nN - max(existing pool/n*, safety/n*) + 1, walking BOTH the
# legacy flat layout (pool/nN.kind.suffix) and the prefixed layout
# (pool/<vYYYY.MAIN>/nN.kind.suffix). The sed expression strips the optional
# major-version segment before extracting the n-counter so the scan is
# layout-agnostic and the counter remains globally unique across cycles.
# ---------------------------------------------------------------------------
# One ref per number handed out off-grid, created in the same transaction as
# the pool and safety pair; see the ref creation below.
RESERVE_NS="refs/how-git/allocated"

# max_spent_number: read lines on stdin, print the highest nN they name as a
# pool/, safety/ or vault/ branch (anchored, so prose never counts), 0 when
# none. awk compares in decimal, so a zero padded n08 never reads as octal.
max_spent_number() {
  { grep -oE '(^|[[:space:]])(pool|safety|vault)/(v[0-9]+\.[0-9]+/)?n[0-9]+\.' \
      | grep -oE 'n[0-9]+\.$' | tr -d 'n.' || true
  } | awk '{ v = $0 + 0; if (v > m) m = v } END { print m + 0 }'
}

# The history is walked once, in two disjoint parts: the tracked remote's
# history (remote_landing_max, run once; the retention prune below trusts
# the same number) and the commits local branches, tags and HEAD add on top
# of it (history_subjects, which stops at the remote's boundary).
# active_series_subjects: drop every subject sealed in another claim series.
# Pool ids are contiguous within the active series (MAJOR_PREFIX, from
# bin/version --seal); a landing subject ending ": vYYYY.S.D" whose vYYYY.S
# differs (the v2026.120.x proof fixtures how-git carried in its tags) spent
# its number in that series, not this one. Subjects without a version and
# every subject when the series is unknown pass through.
active_series_subjects() {
  if [ -z "$MAJOR_PREFIX" ]; then cat; return 0; fi
  awk -v want="$MAJOR_PREFIX" '{
    if (match($0, /: v[0-9]+\.[0-9]+\.[0-9]+/)) {
      v = substr($0, RSTART + 2, RLENGTH - 2); sub(/\.[0-9]+$/, "", v)
      if (v != want) next
    }
    print
  }'
}

# Preflight backups (preflight-bak-*) copy history before a destructive
# operation; they land nothing, so their subjects never spend a number.
history_subjects() {
  local revs="--exclude=preflight-bak* --branches --tags"
  git rev-parse -q --verify HEAD >/dev/null 2>&1 && revs="$revs HEAD"
  # The boundary is the same remote view remote_landing_max reads, backups
  # excluded, so a landing a backup branch also carries is still counted once.
  [ -n "$TRACKED_REMOTE" ] && revs="$revs --not --exclude=$TRACKED_REMOTE/preflight-bak* --remotes=$TRACKED_REMOTE"
  # shellcheck disable=SC2086
  git log $revs --format='%s' 2>/dev/null || true
}
remote_landing_max() {
  if [ -n "$TRACKED_REMOTE" ]; then
    { git log --exclude="$TRACKED_REMOTE/preflight-bak*" --remotes="$TRACKED_REMOTE" --format='%s' 2>/dev/null \
        | grep -F '[MERGE]' || true; } \
      | active_series_subjects | max_spent_number
  else
    echo 0
  fi
}

next_n() {
  # vault/ counts too: a merged pool branch is ARCHIVED there and its pool ref
  # deleted, so a scan of pool/ and safety/ alone forgets every number that
  # completed its lifecycle and hands the next allocation a spent one.
  #
  # Merge subjects are the last record of a number whose branches are all
  # gone. A repository that deletes its pool and safety refs after merging,
  # and keeps no vault, retains the evidence ONLY as "[MERGE] pool/<...>/nN.
  # ... into dev" in its own history - and without reading that, every
  # allocation in such a repository hands out the same number forever. inflx
  # had four different branches all called n1 for exactly this reason.
  #
  # Every commit subject is read, not merge commits alone: a squashed landing
  # keeps the subject while being an ordinary commit, and it spends the number
  # just the same.
  #
  # Every local branch, every tag and the tracked remote, never HEAD alone:
  # landings happen on dev while the operator allocates from a topic branch,
  # a lane worktree or a detached HEAD, and a landing whose branch was
  # rewritten away survives only through its tag. A foreign remote's history
  # is left out for the same reason its refs are.
  #
  # The match is anchored on a branch name (pool/, safety/ or vault/, optional
  # vYYYY.MAIN/ segment, then nN.) so a path such as docs/n9000.md in a release
  # subject never spends a number. Ref names and subjects run through ONE
  # pipeline (a fixed handful of processes, not three per line: 3000 landings
  # took 33 s with a loop) and awk takes the maximum in decimal, so a
  # zero-padded n08 never reads as octal.
  #
  # Off-grid reservations (see the ref creation below) count as spent too.
  local maxn
  maxn=$( { { list_refs_for_prefix "pool/"
              list_refs_for_prefix "safety/"
              list_refs_for_prefix "vault/"
              history_subjects | grep -F '[MERGE]' | active_series_subjects
            } | grep -oE '(^|[[:space:]])(pool|safety|vault)/(v[0-9]+\.[0-9]+/)?n[0-9]+\.' \
              | grep -oE 'n[0-9]+\.$' | tr -d 'n.' || true
            echo "${REMOTE_LANDING_MAX:-0}"
            if [ "$MODE" = "off-grid" ]; then
              git for-each-ref --format='%(refname:lstrip=3)' "$RESERVE_NS/" 2>/dev/null | tr -d 'n' || true
            fi
          } | awk '{ v = $0 + 0; if (v > m) m = v } END { print m + 0 }' || true)
  echo $(( ${maxn:-0} + 1 ))
}
REMOTE_LANDING_MAX=$(remote_landing_max || echo 0)
N=$(next_n)

# ---------------------------------------------------------------------------
# Compose branch name. Prefixed layout when MAJOR_PREFIX resolved; legacy
# flat layout otherwise. Both shapes round-trip cleanly through the pre-push
# regex, the rulesets, the archive flow, and the auto-rebase reconcile path.
# When --no-jira is set the JIRA segment is omitted from the suffix (the
# pre-push regex accepts both shapes because ([A-Z]+-[0-9]+-)? is optional).
# ---------------------------------------------------------------------------
SPRINT_PREFIX=""
[ -n "$SPRINT" ] && SPRINT_PREFIX="sprint${SPRINT}-"
compose_refs() {
  if [ "$NO_JIRA" = "1" ]; then
    SUFFIX="n${N}.${KIND}.${SPRINT_PREFIX}${SHORT_SLUG}"
  else
    SUFFIX="n${N}.${KIND}.${SPRINT_PREFIX}${JIRA}-${SHORT_SLUG}"
  fi
  if [ -n "$MAJOR_PREFIX" ]; then
    POOL_REF="pool/$MAJOR_PREFIX/$SUFFIX"
    SAFETY_REF="safety/$MAJOR_PREFIX/$SUFFIX"
  else
    POOL_REF="pool/$SUFFIX"
    SAFETY_REF="safety/$SUFFIX"
  fi
  if [ ${#POOL_REF} -gt 255 ] || [ ${#SAFETY_REF} -gt 255 ]; then
    echo "allocate-pool-branch: composed ref exceeds 255 chars (pool=${#POOL_REF}, safety=${#SAFETY_REF})" >&2
    exit 2
  fi
}
compose_refs

# ---------------------------------------------------------------------------
# Resolve dev HEAD SHA. Connected mode queries the Git Data API; off-grid
# reads the local ref via git rev-parse. Both modes refuse to proceed if
# dev does not exist or cannot be resolved.
# ---------------------------------------------------------------------------
if [ "$MODE" = "off-grid" ]; then
  DEV_SHA=$(git rev-parse --verify refs/heads/dev 2>/dev/null || true)
else
  DEV_SHA=$(api "https://api.github.com/repos/$REPO_FULL/git/refs/heads/dev" \
    | grep -oE '"sha":[[:space:]]*"[^"]+"' | head -1 | sed -E 's|.*"sha":[[:space:]]*"([^"]+)".*|\1|')
fi

if [ -z "$DEV_SHA" ]; then
  echo "allocate-pool-branch: failed to resolve dev HEAD SHA" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Create both refs atomically.
#
# Connected mode: POST /git/refs twice in sequence (pool first, safety
# second); on partial failure, DELETE the pool to roll back.
#
# Off-grid mode: feed both ref creations to `git update-ref --stdin` as a
# single transaction. git applies the transaction atomically -- either
# both refs land at the dev SHA, or neither does. The transaction also
# enforces that neither ref already exists (the "create" verb requires
# the old-value to be the zero SHA), so a stale local ref blocks the
# allocation instead of silently overwriting it.
# ---------------------------------------------------------------------------
# Ref creations run under ALLOC_PUSH_TOKEN when the dispatch supplied one.
# GitHub refuses the github-actions Integration as a ruleset bypass actor
# unless the ruleset's source is a workflow (which cannot manage rulesets),
# so on consumers the workflow GITHUB_TOKEN holds no bypass and these POSTs
# 422 with "Reference update failed". The dispatching admin's token carries
# the RepositoryRole bypass every v4rian ruleset retains - same authorization
# that gated the dispatch in the first place.
ref_api() {
  if [ -n "${ALLOC_PUSH_TOKEN:-}" ]; then
    curl -sS -H "Authorization: token $ALLOC_PUSH_TOKEN" \
      -H "Accept: application/vnd.github+json" "$@"
  else
    api "$@"
  fi
}

create_ref() {
  local ref="$1"
  local sha="$2"
  ref_api -X POST "https://api.github.com/repos/$REPO_FULL/git/refs" \
    --data "$(printf '{"ref":"refs/heads/%s","sha":"%s"}' "$ref" "$sha")"
}

delete_ref() {
  local ref="$1"
  ref_api -X DELETE "https://api.github.com/repos/$REPO_FULL/git/refs/heads/$ref" >/dev/null || true
}

if [ "$MODE" = "off-grid" ]; then
  # Atomic local pair creation via update-ref transaction. The transaction
  # uses the `--no-deref` flag implicitly (refnames are taken literally)
  # and the `create` verb fails the whole transaction if any ref already
  # exists, so a stale local ref aborts the allocation instead of silently
  # overwriting it. Status output from --stdin goes to stderr so the
  # success JSON on stdout stays clean for downstream consumers.
  #
  # The number itself is claimed in the same transaction as
  # $RESERVE_NS/nN. Scanning and creating are two steps, and two lanes
  # (worktrees of one clone share refs) that scan at the same moment read
  # the same maximum; the pool names differ by short name, so only a ref
  # named after the NUMBER makes one of them lose. The loser's transaction
  # fails as a whole, it recounts (the winner's reservation is now part of
  # the scan) and tries the next number. Reservations are kept: they record
  # numbers already spent even after every branch of them is gone, they
  # live outside refs/heads (no normal push or fetch carries them, and the
  # pre-push hook refuses any push that would), and retention below prunes
  # the ones the tracked remote or the vault already records.
  #
  # A failed transaction leaves nothing behind, so there is no cleanup: a
  # delete here could only hit refs a concurrent allocation just created.
  # The reservation is a name, not a snapshot: it points at dev's root
  # commit, which dev keeps alive until a rewrite that changes the root;
  # after one, it keeps that old root alone (a few objects, never a
  # history) until retention prunes it, never the dev tip of its day.
  RESERVE_TARGET=$(git rev-list --max-parents=0 "$DEV_SHA" 2>/dev/null | tail -1)
  RESERVE_TARGET=${RESERVE_TARGET:-$DEV_SHA}
  #
  # A racer can also meet the winner between its prepare and commit: the
  # winner holds <ref>.lock and the reservation is not visible yet, so the
  # transaction fails on the lock alone. That is contention, not a spent
  # number: wait a moment, recount and retry, for at most
  # ALLOC_LOCK_WAIT_SECONDS (default 20). A lock that outlives the budget
  # (a crashed git) ends the allocation with git's message naming it.
  ALLOC_ATTEMPT=1
  ALLOC_LOCK_DEADLINE=$(( SECONDS + ${ALLOC_LOCK_WAIT_SECONDS:-20} ))
  while :; do
    RESERVATION="$RESERVE_NS/n$N"
    if UPDATE_REFS_OUT=$(printf 'start\ncreate refs/heads/%s %s\ncreate refs/heads/%s %s\ncreate %s %s\nprepare\ncommit\n' \
          "$POOL_REF" "$DEV_SHA" "$SAFETY_REF" "$DEV_SHA" "$RESERVATION" "$RESERVE_TARGET" \
        | git update-ref --stdin 2>&1); then
      break
    fi
    if git rev-parse -q --verify "$RESERVATION" >/dev/null 2>&1 && [ "$ALLOC_ATTEMPT" -lt 50 ]; then
      echo "→ n$N was claimed by a concurrent allocation; recounting" >&2
      ALLOC_ATTEMPT=$(( ALLOC_ATTEMPT + 1 ))
      N=$(next_n)
      compose_refs
      continue
    fi
    if printf '%s' "$UPDATE_REFS_OUT" | grep -q '\.lock' && [ "$SECONDS" -lt "$ALLOC_LOCK_DEADLINE" ]; then
      [ "$ALLOC_ATTEMPT" -gt 1 ] || echo "→ a ref this allocation needs is locked by another git process; waiting" >&2
      ALLOC_ATTEMPT=$(( ALLOC_ATTEMPT + 1 ))
      sleep "0.$(( (RANDOM % 4) + 1 ))"
      N=$(next_n)
      compose_refs
      continue
    fi
    echo "allocate-pool-branch: atomic local ref creation failed (pool=$POOL_REF safety=$SAFETY_REF reservation=$RESERVATION)" >&2
    [ -n "$UPDATE_REFS_OUT" ] && echo "$UPDATE_REFS_OUT" >&2
    exit 1
  done
  [ -n "$UPDATE_REFS_OUT" ] && echo "$UPDATE_REFS_OUT" >&2

  # Bounded retention. A reservation is needed only until its number is
  # safely recorded where every clone looks: on the tracked remote (its
  # pool, safety and vault refs and the landing subjects in its history) or
  # in a local vault ref. Reservations strictly below the highest such
  # number are deleted, each guarded by its old value; the rest stay, and
  # so does the one this run just made: a lane's fetch can land a higher
  # remote number between this run's count and this prune.
  SAFE_MAX=$( { if [ -n "$TRACKED_REMOTE" ]; then
                  git for-each-ref --format='%(refname)' \
                    "refs/remotes/$TRACKED_REMOTE/pool/**" "refs/remotes/$TRACKED_REMOTE/safety/**" \
                    "refs/remotes/$TRACKED_REMOTE/vault/**" 2>/dev/null \
                    | sed "s|^refs/remotes/$TRACKED_REMOTE/||"
                fi
                git for-each-ref --format='%(refname:short)' 'refs/heads/vault/**' 2>/dev/null
                echo "vault/n${REMOTE_LANDING_MAX:-0}."
              } | max_spent_number || true)
  if [ "${SAFE_MAX:-0}" -gt 0 ]; then
    PRUNE=$(git for-each-ref --format='%(refname) %(objectname)' "$RESERVE_NS/" 2>/dev/null \
      | awk -v safe="$SAFE_MAX" -v own="$N" '{ n = $1; sub(/.*\/n/, "", n); if (n ~ /^[0-9]+$/ && n + 0 < safe && n + 0 != own + 0) print "delete " $1 " " $2 }' || true)
    if [ -n "$PRUNE" ]; then
      if printf '%s\n' "$PRUNE" | git update-ref --stdin >/dev/null 2>&1; then
        echo "→ pruned $(printf '%s\n' "$PRUNE" | grep -c .) reservation(s) below n$SAFE_MAX, which the tracked remote or the vault records" >&2
      fi
    fi
  fi
else
  POOL_RESP=$(create_ref "$POOL_REF" "$DEV_SHA")
  if ! echo "$POOL_RESP" | grep -q '"ref":[[:space:]]*"refs/heads/'; then
    echo "allocate-pool-branch: pool ref creation failed" >&2
    echo "$POOL_RESP" >&2
    exit 1
  fi

  SAFETY_RESP=$(create_ref "$SAFETY_REF" "$DEV_SHA")
  if ! echo "$SAFETY_RESP" | grep -q '"ref":[[:space:]]*"refs/heads/'; then
    echo "allocate-pool-branch: safety ref creation failed; rolling back pool ref" >&2
    echo "$SAFETY_RESP" >&2
    delete_ref "$POOL_REF"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Optional initial [REQ] active-requirement commit on the pool branch.
#
# When ALLOC_REQUIREMENT (or --requirement / --requirement-file) is set,
# the allocator writes the requirement text to a tracked file at
# .io.v4rian.how-git/requirements/<lane key> and creates the initial commit on
# the pool branch with the requirement text as the body. The safety
# anchor stays at the dev tip (the pristine fork point); only the pool
# branch advances by one commit.
#
# This commit is the canonical "active requirement for this branch"
# document: auditors and the smart-commit tool fetch its body via
# .io.v4rian.how-git/scripts/get-active-requirement.sh to give claude
# the branch's intent before it acts.
#
# Mechanics: blob -> tree (overlay of dev-tip tree + new file) -> commit
# (parent = dev tip) -> patch pool ref to the new commit SHA. The
# feedback_no_empty_commits rule is honored because the commit always
# touches a real file (the active-requirement file itself).
# ---------------------------------------------------------------------------
REQUIREMENT_COMMIT_SHA=""
if [ -n "$REQUIREMENT" ]; then
  echo "→ writing active-requirement commit on $POOL_REF" >&2

  REQ_COMMIT_TITLE="[REQ] active-requirement: $POOL_REF"
  # One requirement file per lane (hg_requirement_path in _lib.sh): lanes
  # never add the same path, so their merges cannot collide anywhere.
  REQ_PATH=$(hg_requirement_path "$POOL_REF")
  # Lane files inherited from dev belong to lanes already merged: the new
  # lane's [REQ] commit drops them, so merging it removes them from dev and
  # lane files never pile up (dev carries only lanes merged since). Read
  # from the local object store; skipped when the dev tree is not local.
  STALE_REQ_PATHS=$(git ls-tree -r --name-only "$DEV_SHA" -- "$HG_REQUIREMENTS_DIR" 2>/dev/null || true)
  # The legacy shared file an older merged lane left on dev is stale text
  # at a path the readers still fall back to: drop it the same way.
  if git cat-file -e "$DEV_SHA:$HG_LEGACY_REQUIREMENT" 2>/dev/null; then
    STALE_REQ_PATHS="$STALE_REQ_PATHS $HG_LEGACY_REQUIREMENT"
  fi
  REQ_COMMIT_MESSAGE=$(printf '%s\n\n%s' "$REQ_COMMIT_TITLE" "$REQUIREMENT")
  # The [REQ] message obeys the message rules like every other commit (the
  # hooks never run on this plumbing commit), so its text is scrubbed here;
  # the requirement file keeps the verbatim text.
  REQ_MSG_TMP=$(mktemp -t alloc-req-msg.XXXXXX)
  printf '%s' "$REQ_COMMIT_MESSAGE" > "$REQ_MSG_TMP"
  hg_scrub_message_file "$REQ_MSG_TMP"
  REQ_COMMIT_MESSAGE=$(cat "$REQ_MSG_TMP")
  rm -f "$REQ_MSG_TMP"

  rollback_pair() {
    if [ "$MODE" = "off-grid" ]; then
      git update-ref -d "refs/heads/$POOL_REF" 2>/dev/null || true
      git update-ref -d "refs/heads/$SAFETY_REF" 2>/dev/null || true
    else
      delete_ref "$POOL_REF"
      delete_ref "$SAFETY_REF"
    fi
  }

  if [ "$MODE" = "off-grid" ]; then
    # Local plumbing path: hash-object for the blob, read dev's tree into
    # the index overlay, write-tree for the new tree, commit-tree for the
    # commit, update-ref to advance the pool branch.
    REQ_BLOB_SHA=$(printf '%s' "$REQUIREMENT" | git hash-object -w --stdin 2>/dev/null || true)
    if [ -z "$REQ_BLOB_SHA" ]; then
      echo "allocate-pool-branch: failed to write blob for active-requirement (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi

    # Stage the dev-tip tree into a scratch index, overlay the requirement
    # file, then write the new tree. The scratch index keeps the operator's
    # working index untouched.
    SCRATCH_INDEX=$(mktemp -t alloc-pool-idx-XXXXXX)
    trap 'rm -f "$SCRATCH_INDEX"' EXIT
    if ! GIT_INDEX_FILE="$SCRATCH_INDEX" git read-tree "$DEV_SHA" 2>/dev/null; then
      echo "allocate-pool-branch: failed to read dev tree into scratch index (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi
    if ! GIT_INDEX_FILE="$SCRATCH_INDEX" git update-index --add --cacheinfo \
          100644 "$REQ_BLOB_SHA" "$REQ_PATH" 2>/dev/null; then
      echo "allocate-pool-branch: failed to stage active-requirement (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi
    for stale in $STALE_REQ_PATHS; do
      GIT_INDEX_FILE="$SCRATCH_INDEX" git update-index --force-remove "$stale" 2>/dev/null || true
    done
    REQ_TREE_SHA=$(GIT_INDEX_FILE="$SCRATCH_INDEX" git write-tree 2>/dev/null || true)
    if [ -z "$REQ_TREE_SHA" ]; then
      echo "allocate-pool-branch: failed to write requirement tree (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi

    REQUIREMENT_COMMIT_SHA=$(printf '%s' "$REQ_COMMIT_MESSAGE" \
      | git commit-tree "$REQ_TREE_SHA" -p "$DEV_SHA" 2>/dev/null || true)
    if [ -z "$REQUIREMENT_COMMIT_SHA" ]; then
      echo "allocate-pool-branch: failed to create requirement commit (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi

    if ! git update-ref "refs/heads/$POOL_REF" "$REQUIREMENT_COMMIT_SHA" "$DEV_SHA" 2>/dev/null; then
      echo "allocate-pool-branch: failed to advance pool ref to requirement commit (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi
  else
    py_json_str() {
      python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
    }

    REQ_BLOB_BODY=$(printf '{"content":%s,"encoding":"utf-8"}' \
      "$(printf '%s' "$REQUIREMENT" | py_json_str)")
    REQ_BLOB_RESP=$(api -X POST "https://api.github.com/repos/$REPO_FULL/git/blobs" --data "$REQ_BLOB_BODY")
    REQ_BLOB_SHA=$(printf '%s' "$REQ_BLOB_RESP" \
      | grep -oE '"sha":[[:space:]]*"[^"]+"' | head -1 \
      | sed -E 's|.*"sha":[[:space:]]*"([^"]+)".*|\1|')
    if [ -z "$REQ_BLOB_SHA" ]; then
      echo "allocate-pool-branch: failed to create blob for active-requirement; rolling back" >&2
      echo "$REQ_BLOB_RESP" >&2
      rollback_pair
      exit 1
    fi

    # Tree overlay: base_tree = dev tip commit's tree, add one entry.
    STALE_ENTRIES=""
    for stale in $STALE_REQ_PATHS; do
      STALE_ENTRIES="$STALE_ENTRIES$(printf ',{"path":"%s","mode":"100644","type":"blob","sha":null}' "$stale")"
    done
    REQ_TREE_BODY=$(printf '{"base_tree":"%s","tree":[{"path":"%s","mode":"100644","type":"blob","sha":"%s"}%s]}' \
      "$DEV_SHA" "$REQ_PATH" "$REQ_BLOB_SHA" "$STALE_ENTRIES")
    REQ_TREE_RESP=$(api -X POST "https://api.github.com/repos/$REPO_FULL/git/trees" --data "$REQ_TREE_BODY")
    REQ_TREE_SHA=$(printf '%s' "$REQ_TREE_RESP" \
      | grep -oE '"sha":[[:space:]]*"[^"]+"' | head -1 \
      | sed -E 's|.*"sha":[[:space:]]*"([^"]+)".*|\1|')
    if [ -z "$REQ_TREE_SHA" ]; then
      echo "allocate-pool-branch: failed to create tree for active-requirement; rolling back" >&2
      echo "$REQ_TREE_RESP" >&2
      rollback_pair
      exit 1
    fi

    REQ_COMMIT_BODY=$(printf '{"message":%s,"tree":"%s","parents":["%s"]}' \
      "$(printf '%s' "$REQ_COMMIT_MESSAGE" | py_json_str)" "$REQ_TREE_SHA" "$DEV_SHA")
    REQ_COMMIT_RESP=$(api -X POST "https://api.github.com/repos/$REPO_FULL/git/commits" --data "$REQ_COMMIT_BODY")
    REQUIREMENT_COMMIT_SHA=$(printf '%s' "$REQ_COMMIT_RESP" \
      | grep -oE '"sha":[[:space:]]*"[^"]+"' | head -1 \
      | sed -E 's|.*"sha":[[:space:]]*"([^"]+)".*|\1|')
    if [ -z "$REQUIREMENT_COMMIT_SHA" ]; then
      echo "allocate-pool-branch: failed to create commit for active-requirement; rolling back" >&2
      echo "$REQ_COMMIT_RESP" >&2
      rollback_pair
      exit 1
    fi

    # Fast-forward update the pool ref to the requirement commit. Safety
    # stays at the original dev tip.
    REQ_PATCH_BODY=$(printf '{"sha":"%s","force":false}' "$REQUIREMENT_COMMIT_SHA")
    REQ_PATCH_RESP=$(api -X PATCH "https://api.github.com/repos/$REPO_FULL/git/refs/heads/$POOL_REF" --data "$REQ_PATCH_BODY")
    if ! echo "$REQ_PATCH_RESP" | grep -q '"ref":[[:space:]]*"refs/heads/'; then
      echo "allocate-pool-branch: failed to advance pool ref to requirement commit; rolling back" >&2
      echo "$REQ_PATCH_RESP" >&2
      rollback_pair
      exit 1
    fi
  fi
  echo "  ✓ active-requirement committed at $REQUIREMENT_COMMIT_SHA" >&2
else
  echo "  · no requirement supplied; pool branch left at dev tip (legacy mode)" >&2
fi

# ---------------------------------------------------------------------------
# Emit success JSON. URLs point at GitHub in connected mode and at the
# local repo (file:// + ref fragment) in off-grid mode so callers can
# always render a clickable target even when the repo never reaches a
# GitHub remote.
# ---------------------------------------------------------------------------
if [ "$MODE" = "off-grid" ]; then
  BRANCH_URL="file://$(git rev-parse --show-toplevel)#$POOL_REF"
  SAFETY_URL="file://$(git rev-parse --show-toplevel)#$SAFETY_REF"
else
  BRANCH_URL="https://github.com/$REPO_FULL/tree/$POOL_REF"
  SAFETY_URL="https://github.com/$REPO_FULL/tree/$SAFETY_REF"
fi

cat <<JSON
{
  "status": "created",
  "branch_name": "$POOL_REF",
  "safety_name": "$SAFETY_REF",
  "branch_url": "$BRANCH_URL",
  "safety_url": "$SAFETY_URL",
  "sha": "$DEV_SHA",
  "requirement_commit_sha": "$REQUIREMENT_COMMIT_SHA",
  "has_requirement": $([ -n "$REQUIREMENT_COMMIT_SHA" ] && echo "true" || echo "false"),
  "kind": "$KIND",
  "jira_key": "$JIRA",
  "mode": "$MODE",
  "major_prefix": "$MAJOR_PREFIX"
}
JSON
