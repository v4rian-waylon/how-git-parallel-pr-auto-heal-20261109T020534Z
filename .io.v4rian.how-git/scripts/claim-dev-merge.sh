#!/usr/bin/env bash
# claim-dev-merge.sh - git-native claim of the next dev version.
#
# Run this LOCALLY on the `dev` branch immediately after a working-branch
# PR has landed (via GitHub merge-button, manual `git merge --no-ff`, or
# any other path). Tags the merge commit with the dev version returned
# by `bin/version --seal`. No VERSION file is touched - tags are the
# canonical version state ("seal of approval"). No CI required.
#
# This script is the canonical source of truth for the dev → dev claim
# operation. It is the same logic CI would run, but it runs from git, on
# anyone's machine, with no GitHub Actions dependency.
#
# Version derivation: this script never computes the dev tag itself.
# `bin/version` is the single authority for version math across the
# template (claim flow, open-pr, build-on-tag, auto-rebase, status).
# The script's only job here is to consume what `bin/version` returns
# and tag the merge commit with it. The flag used is `--seal`: claim
# runs AFTER the pool->dev merge has landed, so the merge already
# counts in `bin/version`'s first-parent walk and `--seal` returns the
# correct vYEAR.SERIES.DEV value for that merge commit. `--next-dev`
# is what the FOLLOWING merge would claim.
#
# Steps:
#   1. Verify HEAD is `dev`
#   2. Refuse tracked changes; untracked files left in place
#   3. Sync with origin/dev (unless --skip-pull): fast-forward only, keep
#      an unpushed local merge, adopt only an amended twin, else refuse
#   4. Ask `bin/version --seal` for the tag to claim on the merge commit
#   5. Refuse if the tag already exists (claim is already in)
#   6. Annotated-tag HEAD, push tag
#   7. Invoke auto-rebase-pools-after-dev-merge.sh as a best-effort pass
#
# Dependencies: bash, git.
#
# Usage:
#   claim-dev-merge.sh                  do the claim
#   claim-dev-merge.sh --dry-run        show what would happen, no mutations
#   claim-dev-merge.sh --skip-pull      skip the origin/dev sync
#   claim-dev-merge.sh -h | --help      print this help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "✗ claim-dev-merge.sh: not inside a git repo" >&2
  exit 2
fi

NS_DIR=$(basename "$(dirname "$SCRIPT_DIR")")
HOOKS_PATH_OVERRIDE="$NS_DIR/githooks"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"
( cd "$REPO_ROOT" && ensure_hooks_path )

VERSION_BIN="$REPO_ROOT/$NS_DIR/bin/version"

DRY_RUN=false
SKIP_PULL=false
ORIG_ARGS="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --skip-pull) SKIP_PULL=true; shift ;;
    -h|--help)   sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Mode-aware mutation gate. Off-grid repos do not accept CI-driven claims -
# the workflow may still be wired up in the repo for a future flip back, but
# in off-grid mode the authoritative path is local (bin/finalize-pool-merge).
# Connected repos require CI=true (or --dry-run / LIFECYCLE_TEST_MODE=1) so
# local invocations cannot race the workflow and produce duplicate tags on
# the same commit (the 2026-05-23 incident).
MODE_VAL=$(get_mode)
if [ "$MODE_VAL" = "off-grid" ] && [ "${CI:-}" = "true" ]; then
  echo "→ mode is off-grid; CI-driven claim is a no-op (off-grid claims run locally via bin/finalize-pool-merge)"
  exit 0
fi
if [ "$MODE_VAL" != "off-grid" ] \
    && [ "${CI:-}" != "true" ] \
    && [ "${LIFECYCLE_TEST_MODE:-}" != "1" ] \
    && ! $DRY_RUN; then
  echo "✗ claim-dev-merge is a CI-only operation in connected mode. Trigger a tag claim by pushing to dev; use --dry-run for local diagnostic, or flip to off-grid via bin/set-mode off-grid for local-driven ceremonies." >&2
  exit 2
fi

cd "$REPO_ROOT"

HEAD=$(git rev-parse --abbrev-ref HEAD)
claim_head_ok || { echo "✗ HEAD is '$HEAD', not 'dev' nor a detached merge on top of local dev. Switch to dev first." >&2; exit 2; }
LOCAL_DEV_BEFORE=$(git rev-parse refs/heads/dev)

# Untracked files ride along; tracked changes the claim would fold into
# the merge or carry across the sync are refused with exact commands.
claim_tree_guard "claim-dev-merge" "bash $NS_DIR/scripts/claim-dev-merge.sh${ORIG_ARGS:+ $ORIG_ARGS}" || exit 2

# Sync local dev with origin/dev without ever dropping a local commit.
# Local dev behind origin fast-forwards; local dev ahead (an off-grid merge
# not pushed yet) is kept and published by the claim below (R01: the old
# unconditional `checkout -B dev FETCH_HEAD` tagged the previous dev tip).
# The one divergence adopted is the amended twin: local and origin tips with
# the same tree and the same parents, i.e. the same merge with a different
# message. That is the CI rerun shape (the run checks out the PRE amend merge
# SHA while origin/dev carries the amended commit; live incident: eight
# backoff sleeps against "not possible to fast-forward"), and adopting it
# loses no content. Every other divergence is refused wherever the claim
# runs: no environment variable (CI, GITHUB_ACTIONS, ...) authorizes
# dropping a commit, since any shell can carry them. --dry-run never fetches
# or moves anything.
IN_CI=false
[ "${CI:-}" = "true" ] && IN_CI=true
if $SKIP_PULL; then
  :
elif $DRY_RUN; then
  echo "[dry-run] would fetch origin dev; local dev only fast-forwards, an unpushed local merge is kept, a divergence is refused"
elif ! git remote get-url origin >/dev/null 2>&1; then
  echo "→ no origin remote; claiming local dev as is"
elif ! git fetch -q origin dev 2>/dev/null; then
  if $IN_CI; then
    echo "X could not fetch origin dev; aborting the claim" >&2
    exit 1
  fi
  echo "  ! could not fetch origin dev (unreachable, or origin has no dev yet); claiming local dev as is"
else
  LOCAL_DEV=$(git rev-parse HEAD)
  ORIGIN_DEV=$(git rev-parse FETCH_HEAD)
  # Moves local dev to <target> with reset --keep after refusing, by name,
  # any local path the move would have to overwrite that local dev does not
  # track: an untracked or IGNORED file at a path the sync writes, or one
  # sitting where the sync needs a directory (reset --keep overwrites
  # ignored files silently and dies on the rest; the claim never touches
  # files it does not track).
  sync_dev_to() {
    local target="$1" hit p q
    hit=$(git diff --name-only "$LOCAL_DEV" "$target" | while IFS= read -r p; do
        q="$p"
        while [ -n "$q" ] && [ "$q" != "." ]; do
          # The path itself in any form, or a parent that is not a directory.
          if { [ -L "$q" ] || { [ -e "$q" ] && { [ "$q" = "$p" ] || [ ! -d "$q" ]; }; }; } \
              && ! git cat-file -e "$LOCAL_DEV:$q" 2>/dev/null; then
            echo "$q"
          fi
          q=$(dirname "$q")
        done
      done | sort -u)
    if [ -n "$hit" ]; then
      {
        echo "X the sync to origin/dev ($target) would overwrite local path(s) dev does not track (untracked or ignored):"
        printf '%s\n' "$hit" | sed 's/^/    /'
        echo "  Move them aside, rerun the claim, then compare:"
        printf '%s\n' "$hit" | while IFS= read -r f; do printf "    mv '%s' '%s.local'\n" "$f" "$f"; done
        echo "    bash $NS_DIR/scripts/claim-dev-merge.sh${ORIG_ARGS:+ $ORIG_ARGS}"
      } >&2
      exit 2
    fi
    git reset -q --keep "$target"
  }
  if [ "$LOCAL_DEV" = "$ORIGIN_DEV" ]; then
    echo "→ local dev matches origin/dev"
  elif git merge-base --is-ancestor "$LOCAL_DEV" "$ORIGIN_DEV"; then
    sync_dev_to "$ORIGIN_DEV"
    echo "→ fast-forwarded local dev to origin/dev ($ORIGIN_DEV)"
  elif git merge-base --is-ancestor "$ORIGIN_DEV" "$LOCAL_DEV"; then
    echo "→ local dev carries $(git rev-list --count "$ORIGIN_DEV..$LOCAL_DEV") commit(s) origin/dev lacks; keeping them (the claim publishes dev)"
  elif [ "$(git rev-parse "$LOCAL_DEV^{tree}")" = "$(git rev-parse "$ORIGIN_DEV^{tree}")" ] \
      && [ "$(git log -1 --format=%P "$LOCAL_DEV")" = "$(git log -1 --format=%P "$ORIGIN_DEV")" ]; then
    sync_dev_to "$ORIGIN_DEV"
    echo "→ adopted origin/dev ($ORIGIN_DEV), the amended twin of local dev ($LOCAL_DEV): same tree, same parents"
    echo "  dropped local twin (author $(git log -1 --format='%an <%ae>' "$LOCAL_DEV")), message:"
    git log -1 --format=%B "$LOCAL_DEV" | sed 's/^/    | /'
    echo "  keep it with: git branch backup/dev-twin-$(git rev-parse --short "$LOCAL_DEV") $LOCAL_DEV"
  else
    {
      echo "X local dev ($LOCAL_DEV) and origin/dev ($ORIGIN_DEV) diverged; refusing to reset local dev."
      echo "  Local commits origin lacks:"
      git log --oneline "$ORIGIN_DEV..$LOCAL_DEV" | sed 's/^/    /'
      echo "  Origin commits local dev lacks:"
      git log --oneline "$LOCAL_DEV..$ORIGIN_DEV" | sed 's/^/    /'
      echo "  Redo the merge on top of origin/dev, then rerun the claim:"
      echo "    git branch backup/dev-before-claim $LOCAL_DEV"
      echo "    git reset --keep origin/dev && git merge --no-ff <pool branch>"
    } >&2
    exit 2
  fi
fi

# --- Compute the dev tag to claim via the single authority: bin/version ---
# Delegated entirely to `bin/version --seal`. Any other consumer that
# needs to know the current dev tag must call the same binary; never
# duplicate the math here or anywhere else. `--seal` (not --next-dev)
# is the right flag because claim runs AFTER the pool->dev merge lands
# and the merge already counts in `bin/version`'s first-parent walk.
if [ ! -x "$VERSION_BIN" ]; then
  echo "✗ bin/version missing or not executable at $VERSION_BIN" >&2
  exit 2
fi

NEXT=$("$VERSION_BIN" --seal) || {
  echo "✗ bin/version --seal failed; cannot derive dev tag to claim" >&2
  exit 1
}

echo "→ dev tag to claim (from bin/version --seal): $NEXT"

# Re-run idempotency: a tag that already seals the CURRENT dev tip means
# the claim itself succeeded on a prior attempt and this invocation is a
# recovery pass (archive rejected, reconcile interrupted, runner died
# after the tag push). Refusing here made workflow re-runs useless as a
# recovery path (live incident: the archive push was rejected and the
# rerun exit-2'd on the existing tag eight times).
# A tag sealing a DIFFERENT commit is still a hard conflict.
ALREADY_CLAIMED=false
HEAD_SHA_NOW=$(git rev-parse HEAD)
if git rev-parse "$NEXT" >/dev/null 2>&1; then
  TAG_TARGET=$(git rev-parse "$NEXT^{commit}" 2>/dev/null || true)
  if [ "$TAG_TARGET" = "$HEAD_SHA_NOW" ]; then
    echo "→ tag $NEXT already seals HEAD ($HEAD_SHA_NOW); resuming post-claim steps idempotently (archive + reconcile)"
    ALREADY_CLAIMED=true
  else
    echo "✗ tag $NEXT already exists locally and seals $TAG_TARGET, not HEAD ($HEAD_SHA_NOW) - claim conflict" >&2
    echo "  Drop the local tag if re-running after a partial failure:" >&2
    echo "    git tag -d $NEXT" >&2
    exit 2
  fi
fi
if ! $ALREADY_CLAIMED && git ls-remote --tags origin "refs/tags/$NEXT" | grep -q "$NEXT"; then
  REMOTE_TAG_TARGET=$(git ls-remote origin "refs/tags/$NEXT^{}" 2>/dev/null | awk '{print $1}' | head -1)
  if [ -z "$REMOTE_TAG_TARGET" ]; then
    REMOTE_TAG_TARGET=$(git ls-remote --tags origin "refs/tags/$NEXT" | awk '{print $1}' | head -1)
  fi
  if [ "$REMOTE_TAG_TARGET" = "$HEAD_SHA_NOW" ]; then
    echo "→ tag $NEXT already seals HEAD on origin; resuming post-claim steps idempotently (archive + reconcile)"
    ALREADY_CLAIMED=true
  else
    echo "✗ tag $NEXT already exists on origin sealing ${REMOTE_TAG_TARGET:-<unresolvable>} - claim conflict" >&2
    exit 2
  fi
fi

# Detect the just-merged pool/* branch from HEAD's merge subject so the
# auto-archive pass downstream knows what to vault. The character class
# includes / so the vYYYY.MAIN/ major-prefix segment (pool/v2026.0/nN.kind
# .short) is captured intact alongside the legacy flat layout.
HEAD_SUBJ=$(git log -1 --format='%s' HEAD)
MERGED_POOL=$(printf '%s' "$HEAD_SUBJ" | sed -nE \
  -e "s|^Merge pull request #[0-9]+ from [^/]+/(pool/[a-zA-Z0-9./&-]+)$|\1|p" \
  -e "s|^Merge branch '(pool/[a-zA-Z0-9./&-]+)'.*|\1|p" \
  -e "s|^\[MERGE\] (pool/[a-zA-Z0-9./&-]+) into dev.*|\1|p" \
  | head -1)

# Subject-pattern fallback: when bootstrap-ci sets merge_commit_title=PR_TITLE
# (the framework's own repo config), GitHub's default merge subject becomes
# "<PR title> (#N)" instead of "Merge pull request #N from <user>/<branch>",
# so neither of the three sed expressions above match. Recover the source ref
# via the PR API: gh pr list --search <merge-sha> -> headRefName. Same
# fallback shape used by claim-main-release.sh; both call the shared helper
# resolve_source_ref_for_merge_sha in _lib.sh so the gh invocation is owned
# in one place.
if [ -z "$MERGED_POOL" ]; then
  HEAD_SHA=$(git rev-parse HEAD)
  CANDIDATE=$(resolve_source_ref_for_merge_sha "$HEAD_SHA")
  case "$CANDIDATE" in
    pool/*) MERGED_POOL="$CANDIDATE"; echo "→ MERGED_POOL resolved via PR API: $MERGED_POOL" ;;
    "") : ;;
    *) echo "  · PR API returned non-pool source ref '$CANDIDATE'; not using" >&2 ;;
  esac
fi

# R19: every first-parent merge on dev spends a version number (bin/version
# counts merges, the unfailing primitive), so a merge that never got its
# claim (a non-pool merge, hooks off, a claim that died) left a permanent
# hole in the tag chain. Each claim therefore seals every untagged merge on
# dev's line (dev_line_merges, across releases) that is newer than the oldest claim tag there, with the number
# it spent (`bin/version --seal --at`). The walk never stops at the first
# tagged merge, so a hole stays visible to every later claim until sealed.
# Tags are only added locally here (publish_claim_tags pushes them): an
# existing tag is never moved, and merges older than the first claim tag
# (history from before the framework) are left alone.
# Prints the dev merges behind <rev>, newest first: its first-parent merges,
# except that a release merge (a merge on main's first-parent line, met
# after dev took main back) is not a dev merge; the walk continues at the
# dev tip that release shipped (its second parent) instead of drifting into
# main's history.
dev_line_merges() {
  local c="$1" main_ref="" rels="" m next
  if git rev-parse -q --verify main >/dev/null; then
    main_ref=main
  elif git rev-parse -q --verify origin/main >/dev/null; then
    main_ref=origin/main
  fi
  [ -z "$main_ref" ] || rels=$(git rev-list --first-parent --merges "$main_ref")
  while [ -n "$c" ]; do
    next=""
    for m in $(git rev-list --first-parent --merges "$c"); do
      if [ -n "$rels" ] && printf '%s\n' "$rels" | grep -qx "$m"; then
        next=$(git rev-parse -q --verify "$m^2" || true)
        break
      fi
      echo "$m"
    done
    c="$next"
  done
}

seal_unclaimed_merges() {
  local dry="$1" tagged cand cand_year seal seen_tag=false
  git rev-parse -q --verify HEAD^1 >/dev/null || return 0
  # Peeled (annotated) and direct targets of every v* tag, one walk.
  tagged=$(git for-each-ref --format='%(*objectname) %(objectname)' 'refs/tags/v[0-9]*')
  for cand in $(dev_line_merges HEAD^1 | awk '{l[NR]=$0} END {for (i = NR; i > 0; i--) print l[i]}'); do
    if printf '%s\n' "$tagged" | grep -q "$cand"; then
      seen_tag=true
      continue
    fi
    $seen_tag || continue
    seal=$("$VERSION_BIN" --seal --at "$cand") || continue
    if printf '%s\n' "$ORIGIN_TAG_NAMES" | grep -qx "$seal"; then
      echo "  ! merge $cand spent $seal, but origin already holds a $seal that is not a claim tag here; left as is" >&2
      continue
    fi
    if git rev-parse -q --verify "refs/tags/$seal" >/dev/null; then
      echo "  ! merge $cand spent $seal, but that tag already seals $(git rev-parse --short "$seal^{commit}"); left as is" >&2
      continue
    fi
    if [ "$dry" = "dry" ]; then
      echo "[dry-run] would seal unclaimed merge $cand as $seal"
      continue
    fi
    git tag -a "$seal" -m "dev tag $seal (internal; sealed by a later claim: merge $cand spent this number unclaimed)" "$cand"
    echo "→ sealed unclaimed merge $cand as $seal (closes the tag hole)"
    cand_year=$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y "$cand")
    if [ "$cand_year" != "$(date -u +%Y)" ]; then
      echo "  ! merge $cand carries committer year $cand_year, not $(date -u +%Y); $seal sits in the $cand_year chain it counted in (check the committer clock if that is wrong)"
    fi
  done
}

# Brings origin's claim tags (annotated vN.N.N tags) into the local tag set
# before holes are judged: the dev fetch never follows tags, so a clone or
# a CI checkout missing them would take a sealed merge for a hole and mint
# a second tag object under a name origin already holds. Only names that
# are missing locally are fetched, through a private ref namespace, and a
# local tag is created only when absent (update-ref with an empty old
# value), so nothing local ever moves. A local tag of the same name that
# differs, or a fetch that fails, stops the claim before any tag is made.
# Sets ORIGIN_TAG_NAMES (every v* name on origin) for seal_unclaimed_merges.
ORIGIN_TAG_NAMES=""
fetch_claim_tags() {
  local listing n remote_obj local_obj refspecs="" wanted=""
  listing=$(git ls-remote --tags origin 'refs/tags/v*' 2>/dev/null) || {
    echo "X cannot list origin's tags; refusing to seal or publish claim tags without them (rerun once origin answers)" >&2
    return 1
  }
  ORIGIN_TAG_NAMES=$(printf '%s\n' "$listing" | awk '{print $2}' | sed -e 's|^refs/tags/||' -e 's|\^{}$||' | sort -u)
  # Annotated semver tags are the ones with a peeled ^{} line.
  for n in $(printf '%s\n' "$listing" | awk '{print $2}' \
      | sed -n 's|^refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)^{}$|\1|p'); do
    remote_obj=$(printf '%s\n' "$listing" | awk -v r="refs/tags/$n" '$2 == r {print $1}')
    if local_obj=$(git rev-parse -q --verify "refs/tags/$n"); then
      if [ "$local_obj" != "$remote_obj" ]; then
        echo "X local tag $n ($local_obj) differs from origin's claim tag $n ($remote_obj); refusing to seal or publish." >&2
        echo "  Inspect both (git show $n; git ls-remote origin refs/tags/$n), drop the wrong local one (git tag -d $n), rerun the claim." >&2
        return 1
      fi
      continue
    fi
    refspecs="$refspecs refs/tags/$n:refs/claim-fetch/$n"
    wanted="$wanted $n"
  done
  [ -n "$wanted" ] || return 0
  # shellcheck disable=SC2086
  git fetch -q --no-tags origin $refspecs || {
    echo "X fetching origin's claim tags failed; refusing to seal or publish claim tags without them:$wanted" >&2
    return 1
  }
  for n in $wanted; do
    if [ "$(git cat-file -t "refs/claim-fetch/$n")" = "tag" ]; then
      git update-ref "refs/tags/$n" "$(git rev-parse "refs/claim-fetch/$n")" "" \
        || { echo "X could not record origin's claim tag $n locally" >&2; return 1; }
    fi
    git update-ref -d "refs/claim-fetch/$n"
  done
  echo "→ fetched origin's claim tags missing locally:$wanted"
}

# Pushes every claim tag (an annotated vN.N.N tag; claims never make
# lightweight ones) on HEAD's history that origin lacks, the HEAD tag
# included. Recomputed on every claim, so a tag push rejected by an earlier
# claim is repaired by the next one. Add-only: a claim tag deleted on origin
# while it still seals a merge on dev comes back. If origin's tag list
# cannot be read the push is refused rather than resending every tag.
publish_claim_tags() {
  local remote missing t
  remote=$(git ls-remote --tags origin 'refs/tags/v*') || {
    echo "X cannot list origin's tags; claim tags not pushed (the next claim pushes them)" >&2
    return 1
  }
  remote=$(printf '%s\n' "$remote" | awk '{print $2}' | sed -e 's|^refs/tags/||' -e 's|\^{}$||' | sort -u)
  missing=$(git for-each-ref --merged HEAD --format='%(objecttype) %(refname:short)' 'refs/tags/v[0-9]*' \
    | awk '$1 == "tag" && $2 ~ /^v[0-9]+[.][0-9]+[.][0-9]+$/ {print $2}' \
    | while IFS= read -r t; do printf '%s\n' "$remote" | grep -qx "$t" || echo "$t"; done)
  if [ -z "$missing" ]; then
    echo "→ origin holds every claim tag on dev; nothing to push"
    return 0
  fi
  # Tag pushes route through lifecycle_push (_lib.sh): in CI the optional
  # CLAIM_TAG_PUSH_TOKEN App installation token is used when configured
  # (an external actor, so the tag event fires downstream tag workflows);
  # otherwise the plain origin push applies - under a workflow GITHUB_TOKEN
  # the tag lands but downstream workflows are suppressed by GitHub's
  # recursion guard, while a local operator run pushes under their own gh
  # session credentials and events fire normally.
  if [ -n "${CLAIM_TAG_PUSH_TOKEN:-}" ]; then
    echo "→ pushing claim tags via CLAIM_TAG_PUSH_TOKEN (App identity; downstream tag workflows fire)"
  else
    echo "  · plain origin tag push (in CI the GITHUB_TOKEN recursion guard suppresses downstream tag workflows)"
  fi
  for t in $missing; do
    echo "→ pushing tag $t"
    lifecycle_push -q "$t" || {
      echo "X tag push of $t via the lifecycle identity failed; falling back to plain origin push" >&2
      git push -q origin "$t" || {
        echo "X push of $t rejected; the tag is kept locally and the next claim pushes it again" >&2
        return 1
      }
    }
  done
}

if $DRY_RUN; then
  seal_unclaimed_merges dry
  echo "[dry-run] would tag HEAD ($(git rev-parse HEAD)) as $NEXT, push tag, archive $MERGED_POOL, run auto-rebase pass"
  exit 0
fi

# ---------------------------------------------------------------------------
# Amend the merge commit subject to the spec format
# [MERGE] <source> into dev: vYYYY.SERIES.DEV
# so the dev log reads canonically regardless of how the merge was triggered.
# Connected mode: pull PR title+body via gh for full parity with the PR.
# Off-grid mode: derive title from MERGED_POOL + NEXT; preserve the operator's
# existing merge body (they wrote it via git merge --no-ff -m).
# ---------------------------------------------------------------------------

echo "→ mode: $MODE_VAL"

if [ -n "$MERGED_POOL" ]; then
  NEW_SUBJECT="[MERGE] $MERGED_POOL into dev: $NEXT"
  CUR_SUBJECT=$(git log -1 --format='%s' HEAD)

  if [ "$CUR_SUBJECT" = "$NEW_SUBJECT" ]; then
    echo "→ merge subject already in spec format; skipping amend"
  else
    OLD_HEAD=$(git rev-parse HEAD)
    ORIG_AUTHOR_NAME=$(git log -1 --format='%an' HEAD)
    ORIG_AUTHOR_EMAIL=$(git log -1 --format='%ae' HEAD)
    ORIG_AUTHOR_DATE=$(git log -1 --format='%aI' HEAD)
    ORIG_COMMITTER_DATE=$(git log -1 --format='%cI' HEAD)

    NEW_BODY=""
    if [ "$MODE_VAL" = "connected" ] && command -v gh >/dev/null 2>&1; then
      # Pull PR title+body. Resolve the PR number from the merge subject's
      # 'Merge pull request #N' shape; if absent (e.g. local merge pushed up),
      # fall back to gh's search for closed PRs whose head matches MERGED_POOL.
      PR_NUM=$(printf '%s' "$CUR_SUBJECT" | sed -nE 's|^Merge pull request #([0-9]+) from .*|\1|p')
      if [ -z "$PR_NUM" ]; then
        REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
        OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
        if [ -n "$OWNER_REPO" ]; then
          PR_NUM=$(gh pr list --repo "$OWNER_REPO" --state merged --head "${MERGED_POOL#pool/}" --json number --jq '.[0].number' 2>/dev/null || true)
          # gh pr list --head wants the branch name without owner prefix; try once with pool/ stripped.
          if [ -z "$PR_NUM" ]; then
            PR_NUM=$(gh pr list --repo "$OWNER_REPO" --state merged --head "$MERGED_POOL" --json number --jq '.[0].number' 2>/dev/null || true)
          fi
        fi
      fi
      if [ -n "$PR_NUM" ]; then
        REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
        OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
        NEW_BODY=$(gh pr view "$PR_NUM" --repo "$OWNER_REPO" --json body --jq '.body' 2>/dev/null || true)
        if [ -z "$NEW_BODY" ]; then
          echo "  ! PR #$PR_NUM body fetch returned empty (gh auth missing? rate limit? body genuinely empty?); falling back to existing merge body so the recap section is not silently dropped" >&2
          NEW_BODY=$(git log -1 --format='%b' HEAD)
        else
          echo "→ amend body source: PR #$PR_NUM via gh"
        PR_BODY_SRC="$NEW_BODY"
        fi
      else
        echo "  ! no PR number resolvable; amend body falls back to current merge body"
        NEW_BODY=$(git log -1 --format='%b' HEAD)
      fi
    else
      # Off-grid path or gh unavailable: preserve current merge body.
      NEW_BODY=$(git log -1 --format='%b' HEAD)
      [ "$MODE_VAL" = "off-grid" ] && echo "→ amend body source: existing merge body (off-grid mode)"
    fi

    # Prepend the PR backreference as the first body paragraph (right
    # after the subject line) so the merge commit's PR pointer is the
    # first thing a reader sees under the spec-format subject, before
    # the recap section. The PR number is followed by the full GitHub
    # PR URL so a reader can click straight through to the source PR
    # from any terminal that auto-links URLs. The URL append is
    # gated on OWNER_REPO being resolvable; when it is not, the
    # reference falls back to the bare "PR #N" form.
    if [ -n "${PR_NUM:-}" ]; then
      PR_LINE="PR #${PR_NUM}"
      if [ -n "${OWNER_REPO:-}" ]; then
        PR_LINE="${PR_LINE} https://github.com/${OWNER_REPO}/pull/${PR_NUM}"
      fi
      NEW_BODY="${PR_LINE}

${NEW_BODY}"
    fi

    MSG_FILE=$(mktemp)
    trap 'rm -f "$MSG_FILE"' EXIT
    { printf '%s\n\n' "$NEW_SUBJECT"; printf '%s\n' "$NEW_BODY"; } > "$MSG_FILE"
    # The merge message gate runs here as well as in commit-msg, because a
    # runner without the repo hooks would otherwise amend and tag a merge
    # whose body breaks the ruled shape (git-merge-audit rule 5). Nothing is
    # amended, pushed or tagged when it fails.
    if ! bash "$SCRIPT_DIR/check-merge-message.sh" --file "$MSG_FILE" --pr-ref; then
      rm -f "$MSG_FILE"
      echo "X claim: the merge message breaks the merge shape; fix the PR body (connected) or amend the merge body (off-grid), then re-run the claim" >&2
      exit 1
    fi
    # When this script runs from the post-merge hook, git has just created
    # the merge commit but has not yet removed MERGE_HEAD / MERGE_MSG /
    # MERGE_MODE / AUTO_MERGE. The lingering state makes git commit --amend
    # refuse with "You are in the middle of a merge -- cannot amend." The
    # merge IS complete (HEAD already points at the merge commit), so the
    # state files are stale metadata; remove them before the amend.
    GIT_DIR=$(git rev-parse --git-dir)
    rm -f "$GIT_DIR/MERGE_HEAD" "$GIT_DIR/MERGE_MSG" "$GIT_DIR/MERGE_MODE" "$GIT_DIR/AUTO_MERGE" 2>/dev/null || true
    HOW_GIT_PRESERVE_AUTHOR=1 GIT_AUTHOR_NAME="$ORIG_AUTHOR_NAME" GIT_AUTHOR_EMAIL="$ORIG_AUTHOR_EMAIL" \
    GIT_AUTHOR_DATE="$ORIG_AUTHOR_DATE" GIT_COMMITTER_DATE="$ORIG_COMMITTER_DATE" \
      git commit --amend -F "$MSG_FILE"
    rm -f "$MSG_FILE"
    NEW_HEAD=$(git rev-parse HEAD)
    echo "→ amended merge: $OLD_HEAD -> $NEW_HEAD"
    # PR body parity (git-merge-audit, PR body parity): the amended merge
    # body minus the PR reference paragraph must equal the PR body.
    if [ -n "${PR_BODY_SRC:-}" ]; then
      PARITY_FILE=$(mktemp)
      trap 'rm -f "${MSG_FILE:-}" "$PARITY_FILE"' EXIT
      printf '%s\n' "$PR_BODY_SRC" > "$PARITY_FILE"
      if ! bash "$SCRIPT_DIR/check-merge-parity.sh" HEAD --pr-body-file "$PARITY_FILE"; then
        rm -f "$PARITY_FILE"
        echo "X claim: merge body and PR body differ after the amend; nothing pushed or tagged" >&2
        exit 1
      fi
      rm -f "$PARITY_FILE"
    fi
  fi
else
  echo "  · MERGED_POOL not detected from HEAD subject; skipping amend (cannot derive spec subject without source ref)"
fi

# ---------------------------------------------------------------------------
# Publish dev BEFORE the tag, whatever the merge subject looked like: a tag
# reaches origin only once origin's dev carries the commit it seals (R03: a
# non-spec subject skipped the dev push but still pushed the tag, leaving a
# tag for a commit origin's dev never received). Also the v2026.0.99 lesson
# (2026-05-28): a rejected amend push followed by a retry that skipped the
# already-applied amend tagged a local-only commit; the push therefore runs
# on every attempt and a rejection aborts before the tag.
#
# origin's dev is read live (ls-remote), and dev is only ever moved forward
# or replaced by its amended twin (same tree, same parents: the merge this
# claim just rewrote into spec form). Anything else on origin means another
# merge landed first; the claim stops rather than overwrite it. The lease
# pins the value read, so a push racing this one is rejected too.
# ---------------------------------------------------------------------------
DEV_ON_ORIGIN=false
HEAD_SHA_NOW=$(git rev-parse HEAD)
if ! git remote get-url origin >/dev/null 2>&1; then
  echo "→ no origin remote; the claim stays local"
elif ! REMOTE_DEV_LINE=$(git ls-remote origin refs/heads/dev 2>/dev/null); then
  # HG-R238: an unreachable origin fails the claim before any tag exists;
  # a rerun once origin is back converges dev and the tag.
  echo "X origin unreachable; aborting before tag to avoid orphaning the tag $NEXT (rerun the claim once origin is back)" >&2
  exit 1
else
  REMOTE_DEV=$(printf '%s' "$REMOTE_DEV_LINE" | awk '{print $1}')
  PUSH_DEV=true
  if [ "$REMOTE_DEV" = "$HEAD_SHA_NOW" ]; then
    PUSH_DEV=false
    DEV_ON_ORIGIN=true
  elif [ -z "$REMOTE_DEV" ]; then
    echo "→ origin has no dev yet; publishing it"
  elif ! git cat-file -e "$REMOTE_DEV^{commit}" 2>/dev/null; then
    echo "X origin dev is at $REMOTE_DEV, a commit this clone has never seen; another merge landed first." >&2
    echo "  Aborting before tag to avoid orphaning the tag $NEXT. Fetch, redo the merge on the new dev, rerun the claim." >&2
    exit 1
  elif git merge-base --is-ancestor "$REMOTE_DEV" "$HEAD_SHA_NOW"; then
    :
  elif [ "$(git rev-parse "$REMOTE_DEV^{tree}")" = "$(git rev-parse "HEAD^{tree}")" ] \
      && [ "$(git log -1 --format=%P "$REMOTE_DEV")" = "$(git log -1 --format=%P HEAD)" ]; then
    echo "→ origin dev holds the pre amend twin of HEAD ($REMOTE_DEV); replacing it with the spec-form merge"
  else
    echo "X origin dev ($REMOTE_DEV) is not contained in HEAD ($HEAD_SHA_NOW); another merge landed first." >&2
    echo "  Aborting before tag to avoid orphaning the tag $NEXT. Fetch, redo the merge on the new dev, rerun the claim." >&2
    exit 1
  fi
  if $PUSH_DEV; then
    V4RIAN_CLAIM_PUSH=1 git push -q --force-with-lease="refs/heads/dev:$REMOTE_DEV" origin "HEAD:refs/heads/dev" || {
      echo "X push of dev rejected; aborting before tag to avoid orphaning the tag $NEXT" >&2
      exit 1
    }
    echo "→ origin dev now carries $HEAD_SHA_NOW"
    DEV_ON_ORIGIN=true
  fi
fi

if $DEV_ON_ORIGIN; then
  fetch_claim_tags || exit 1
fi

if $ALREADY_CLAIMED; then
  echo "→ tag $NEXT already in place; skipping tag + tag push (resume); origin is checked for every missing claim tag below"
else
  echo "→ tagging $NEXT on $(git rev-parse HEAD)"
  git tag -a "$NEXT" -m "dev tag $NEXT (internal)"
fi

# Holes are sealed locally before any tag push, so a rejected push cannot
# skip them; the publish step then pushes every claim tag origin lacks.
seal_unclaimed_merges run

if $DEV_ON_ORIGIN; then
  publish_claim_tags || exit 1
else
  echo "  · no origin remote; claim tags stay local"
fi

echo "✓ claimed $NEXT"
claim_advance_local_dev "$LOCAL_DEV_BEFORE"

# Vault step decoupled from amend: the amend block above may have early-exited
# (when MERGED_POOL was empty AND no subject pattern matched AND the PR-API
# fallback returned nothing), but the vault target is independently derivable
# from the merge commit's structural metadata. Reach for that ONLY when the
# upstream resolution paths produced nothing - otherwise this is a no-op.
#
# Resolution order for vault target:
#   1. MERGED_POOL from subject parse + PR-API fallback (computed above).
#   2. Second-parent SHA reverse lookup: git log -1 --format=%P HEAD gives the
#      merge's parent SHAs space-separated; field 2 is the source branch tip.
#      git ls-remote origin returns every remote ref's SHA so a grep on the
#      tip SHA recovers the branch name when the head ref still exists on
#      origin (it always does at claim time - the GitHub-side merge button
#      keeps the head branch alive until claim's archive step deletes it).
#   3. Loud error naming the merge SHA + every resolution path that failed,
#      so a human operator can rerun archive-pool-branch.sh manually with the
#      right argument. No silent skip - D-5 in the n78 sacrificial throwaway
#      report traced an entire missed vault to the prior silent skip.
if [ -z "$MERGED_POOL" ]; then
  HEAD_SHA=$(git rev-parse HEAD)
  PARENTS=$(git log -1 --format='%P' HEAD)
  SECOND_PARENT_SHA=$(printf '%s' "$PARENTS" | awk '{print $2}')
  if [ -n "$SECOND_PARENT_SHA" ]; then
    echo "→ MERGED_POOL still empty; trying second-parent reverse-lookup against origin (second_parent=$SECOND_PARENT_SHA)"
    SECOND_PARENT_REF=$(git ls-remote origin 2>/dev/null \
      | awk -v sha="$SECOND_PARENT_SHA" '$1 == sha { print $2 }' \
      | sed -n 's|^refs/heads/\(pool/.*\)$|\1|p' \
      | head -1)
    if [ -n "$SECOND_PARENT_REF" ]; then
      MERGED_POOL="$SECOND_PARENT_REF"
      echo "→ MERGED_POOL resolved via second-parent reverse-lookup: $MERGED_POOL"
    fi
  fi
  if [ -z "$MERGED_POOL" ]; then
    cat >&2 <<EOF
X claim-dev-merge: cannot derive the source pool branch for vault step.
  merge SHA            : $HEAD_SHA
  HEAD subject         : $HEAD_SUBJ
  subject parse        : returned no pool/ ref (no legacy "Merge pull request" shape, no "Merge branch", no [MERGE] tag)
  PR-API fallback      : gh pr list --search "$HEAD_SHA" returned no headRefName starting with pool/
  second-parent lookup : second parent ${SECOND_PARENT_SHA:-<none>} not found among origin's pool/* refs
  consequence          : the pool branch will remain on origin un-vaulted; rerun .io.v4rian.how-git/scripts/archive-pool-branch.sh <pool/branch-name> manually once you identify the source.
EOF
  fi
fi

# Archive the merged pool/* branch to vault/<same-suffix>. See
# archive-pool-branch.sh for behavior. The vault step proceeds whenever
# MERGED_POOL was resolvable via ANY of the three paths above (subject,
# PR API, second-parent reverse-lookup); the loud error block above
# already covered the all-three-failed case.
if [ -n "$MERGED_POOL" ] && [ -x "$SCRIPT_DIR/archive-pool-branch.sh" ]; then
  echo "→ archiving $MERGED_POOL (vault path resolved by archive-pool-branch.sh: prefixed when bin/version --seal returns vN.N.N, flat otherwise)"
  "$SCRIPT_DIR/archive-pool-branch.sh" "$MERGED_POOL" || {
    echo "  ⚠ archive failed; $MERGED_POOL left as-is on origin (rerun archive-pool-branch.sh manually)"
    # A swallowed archive failure inside a green claim job is how stale
    # vaulted-but-not-deleted pool refs accumulate unseen; surface it on
    # the run summary where the admin actually looks.
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        echo "## :red_circle: archive failed for \`$MERGED_POOL\`"
        echo "The vault rename did not land; the pool ref remains on origin. An admin completes the transition locally: \`.io.v4rian.how-git/bin/post-merge-lifecycle\` (runs under the operator gh session)."
      } >> "$GITHUB_STEP_SUMMARY"
    fi
  }
elif [ -n "$MERGED_POOL" ]; then
  echo "  · archive-pool-branch.sh not present in this template revision; skipping auto-archive"
fi

# Dual-vault on reconcile-merge: when the just-merged source ref is a
# pool/[<major>/]nN.reconcile.<short> branch (the auto-rebase candidate
# from feedback_how_git_never_rewrites_history), the corresponding
# original pool/[<major>/]nN.<kind>.<short> branch is still on origin as
# an open ref. The reconcile merge represents the final landing of the
# original branch's intent on dev, so leaving the original pool ref
# open after the reconcile lands creates a stale dangling ref that the
# auto-rebase pass would keep iterating against. Identify and vault the
# original here so both refs disappear from the pool/ namespace in the
# same close-up that tagged the merge commit.
#
# Resolution: extract nN + short_name from MERGED_POOL, then walk
# origin's pool/[<major>/]nN.* refs (gh ls-remote in connected mode,
# git for-each-ref in off-grid mode) and pick the one whose kind is not
# reconcile AND whose <short> matches. Zero matches: log and continue
# (the original was already vaulted by a prior pass, or the reconcile
# was synthesized from a test fixture without a corresponding original).
# More-than-one matches: surface a loud error naming every candidate and
# skip the additional vault so an admin can decide manually.
if [ -n "$MERGED_POOL" ] && [ -x "$SCRIPT_DIR/archive-pool-branch.sh" ]; then
  RECON_MAJOR_PREFIX=""
  RECON_N=""
  RECON_KIND=""
  RECON_SHORT=""
  if [[ "$MERGED_POOL" =~ ^pool/(v[0-9]+\.[0-9]+)/n([0-9]+)\.([a-z\&]+)\.(.+)$ ]]; then
    RECON_MAJOR_PREFIX="${BASH_REMATCH[1]}"
    RECON_N="${BASH_REMATCH[2]}"
    RECON_KIND="${BASH_REMATCH[3]}"
    RECON_SHORT="${BASH_REMATCH[4]}"
  elif [[ "$MERGED_POOL" =~ ^pool/n([0-9]+)\.([a-z\&]+)\.(.+)$ ]]; then
    RECON_N="${BASH_REMATCH[1]}"
    RECON_KIND="${BASH_REMATCH[2]}"
    RECON_SHORT="${BASH_REMATCH[3]}"
  fi

  if [ "$RECON_KIND" = "reconcile" ] && [ -n "$RECON_N" ] && [ -n "$RECON_SHORT" ]; then
    if [ -n "$RECON_MAJOR_PREFIX" ]; then
      LOOKUP_PREFIX="pool/$RECON_MAJOR_PREFIX/n$RECON_N."
    else
      LOOKUP_PREFIX="pool/n$RECON_N."
    fi
    echo "→ reconcile-merge detected; probing for the corresponding original pool branch under ${LOOKUP_PREFIX}*"

    ORIGINAL_CANDIDATES=""
    if [ "$MODE_VAL" = "off-grid" ]; then
      ORIGINAL_CANDIDATES=$(git for-each-ref --format='%(refname:short)' "refs/heads/${LOOKUP_PREFIX}*" 2>/dev/null || true)
    else
      ORIGINAL_CANDIDATES=$(git ls-remote --heads origin "${LOOKUP_PREFIX}*" 2>/dev/null \
        | awk '{print $2}' \
        | sed -n 's|^refs/heads/||p' || true)
    fi

    ORIGINAL_MATCHES=""
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      cand_kind=""
      cand_short=""
      if [[ "$ref" =~ ^pool/v[0-9]+\.[0-9]+/n[0-9]+\.([a-z\&]+)\.(.+)$ ]]; then
        cand_kind="${BASH_REMATCH[1]}"
        cand_short="${BASH_REMATCH[2]}"
      elif [[ "$ref" =~ ^pool/n[0-9]+\.([a-z\&]+)\.(.+)$ ]]; then
        cand_kind="${BASH_REMATCH[1]}"
        cand_short="${BASH_REMATCH[2]}"
      fi
      if [ "$cand_kind" != "reconcile" ] && [ "$cand_short" = "$RECON_SHORT" ]; then
        if [ -z "$ORIGINAL_MATCHES" ]; then
          ORIGINAL_MATCHES="$ref"
        else
          ORIGINAL_MATCHES="$ORIGINAL_MATCHES"$'\n'"$ref"
        fi
      fi
    done <<< "$ORIGINAL_CANDIDATES"

    MATCH_COUNT=0
    if [ -n "$ORIGINAL_MATCHES" ]; then
      MATCH_COUNT=$(printf '%s\n' "$ORIGINAL_MATCHES" | wc -l | tr -d ' ')
    fi

    if [ "$MATCH_COUNT" -eq 0 ]; then
      echo "  · no non-reconcile pool/ ref matches n$RECON_N + short=$RECON_SHORT; the original branch was already vaulted by a prior pass (or the reconcile was synthesized without a corresponding original). Continuing without a second vault."
    elif [ "$MATCH_COUNT" -gt 1 ]; then
      echo "X claim-dev-merge: dual-vault step found MORE THAN ONE non-reconcile pool/ ref matching n$RECON_N + short=$RECON_SHORT:" >&2
      printf '  %s\n' $ORIGINAL_MATCHES >&2
      echo "  the nN allocator uniqueness invariant should prevent this; skipping the additional vault so an admin can decide which ref to vault manually via $SCRIPT_DIR/archive-pool-branch.sh <ref>." >&2
    else
      ORIGINAL_REF="$ORIGINAL_MATCHES"
      echo "→ reconcile-merge dual-vault: also archiving the original pool branch $ORIGINAL_REF (paired with merged reconcile $MERGED_POOL)"
      "$SCRIPT_DIR/archive-pool-branch.sh" "$ORIGINAL_REF" || \
        echo "  ⚠ archive of original $ORIGINAL_REF failed; left as-is on origin (rerun archive-pool-branch.sh manually)"
    fi
  fi
fi

# Sync every active pool/* branch + its open PR title to the new tag.
# Best-effort: failures don't roll back the claim.
if [ -x "$SCRIPT_DIR/auto-rebase-pools-after-dev-merge.sh" ]; then
  "$SCRIPT_DIR/auto-rebase-pools-after-dev-merge.sh" || \
    echo "  ⚠ auto-rebase pass returned non-zero; the claim is still in place"
fi
