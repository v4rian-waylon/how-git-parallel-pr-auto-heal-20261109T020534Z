#!/usr/bin/env bash
# claim-main-release.sh - promote the latest dev tag to a public release.
#
# Run this LOCALLY on the `main` branch immediately after `dev` has been
# merged in via --no-ff. The MERGE itself promotes the code; this script
# just creates the GitHub Release object against the existing dev tag.
#
# The release REUSES the dev tag. Same code, same version. Two binary-
# identical builds never carry different versions. The dev merge commit
# already has the tag (e.g. v2026.0.7); the dev->main merge brings that
# commit into main's history. The "release" is the GitHub Release
# object that flips the tag from internal-only to public + ships the
# built artifact.
#
# Steps:
#   1. Verify HEAD is `main`
#   2. Refuse tracked changes; untracked files left in place
#   3. Verify the dev->main merge was --no-ff (HEAD has >=2 parents)
#   4. Pull main (unless --skip-pull)
#   5. Find the latest reachable v* tag this year
#   6. (Optional) Create GitHub Release object against that tag if a
#      token is available. The git tag itself is NOT touched.
#
# Safety/ anchor branches are never touched by this script. Under the
# stay-forever rule every safety/ ref persists for the life of the repo
# regardless of whether the paired pool branch was released, is in
# flight, or was abandoned; the institutional record of where every
# working branch started is worth more than the negligible cost of one
# extra ref pointer per pool branch.
#
# Usage:
#   claim-main-release.sh                  do the claim
#   claim-main-release.sh --dry-run        show what would happen, no mutations
#   claim-main-release.sh --skip-pull      skip `git pull origin main`
#   claim-main-release.sh --no-release     don't try to create a GitHub Release
#   claim-main-release.sh -h | --help      print this help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "X claim-main-release.sh: not inside a git repo" >&2
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
NO_RELEASE=false
ORIG_ARGS="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --skip-pull)  SKIP_PULL=true; shift ;;
    --no-release) NO_RELEASE=true; shift ;;
    -h|--help)    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "X unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Mode-aware mutation gate. Off-grid repos do not accept CI-driven releases -
# the workflow may still be wired up but in off-grid mode the authoritative
# release path is local (bin/ship). Connected repos require CI=true (or
# --dry-run / LIFECYCLE_TEST_MODE=1) so local runs cannot race the workflow.
MODE_VAL=$(get_mode)
if [ "$MODE_VAL" = "off-grid" ] && [ "${CI:-}" = "true" ]; then
  echo "→ mode is off-grid; CI-driven release is a no-op (off-grid releases run locally via bin/ship)"
  exit 0
fi
if [ "$MODE_VAL" != "off-grid" ] \
    && [ "${CI:-}" != "true" ] \
    && [ "${LIFECYCLE_TEST_MODE:-}" != "1" ] \
    && ! $DRY_RUN; then
  echo "X claim-main-release is a CI-only operation in connected mode. Trigger a release by merging dev into main; use --dry-run for local diagnostic, or flip to off-grid via bin/set-mode off-grid for local-driven releases." >&2
  exit 2
fi

cd "$REPO_ROOT"

HEAD=$(git rev-parse --abbrev-ref HEAD)
[ "$HEAD" = "main" ] || { echo "X HEAD is '$HEAD', not 'main'. Switch to main first." >&2; exit 2; }

# Untracked files ride along; tracked changes the claim would fold into
# the merge or carry across the sync are refused with exact commands.
claim_tree_guard "claim-main-release" "bash $NS_DIR/scripts/claim-main-release.sh${ORIG_ARGS:+ $ORIG_ARGS}" || exit 2

if [ "$(git rev-list --parents -n 1 HEAD | wc -w)" -lt 3 ]; then
  echo "X HEAD on main has fewer than 2 parents - the dev->main merge was NOT --no-ff." >&2
  echo "  The v4rian model requires --no-ff so the merge commit lands on main's" >&2
  echo "  first-parent line. Re-merge dev with --no-ff." >&2
  exit 2
fi

if ! $SKIP_PULL; then
  echo "-> pulling origin/main (use --skip-pull to bypass)"
  git pull -q --ff-only origin main
fi

# The release version IS the latest dev tag - same code = same version.
RELEASE_TAG=$("$VERSION_BIN" --release-tag)

echo "-> release version (from bin/version --release-tag): $RELEASE_TAG"
echo "   (this REUSES the existing dev tag; no new git tag is created)"

# Confirm the dev tag actually exists (it should, from claim-dev-merge.sh
# running when the dev merge was claimed). If not, something is off.
if ! git rev-parse "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "X no git tag $RELEASE_TAG exists locally - was the dev merge ever claimed?" >&2
  echo "  Run claim-dev-merge.sh on dev to create the tag, then re-run this." >&2
  exit 2
fi

if $DRY_RUN; then
  echo "[dry-run] would amend release merge subject + create GitHub Release against $RELEASE_TAG"
  exit 0
fi

# ---------------------------------------------------------------------------
# Amend the merge commit subject to the spec format
# [MERGE] dev into main: vYYYY.X
# so the main log reads canonically regardless of how the dev->main merge was
# triggered (UI button, init-release, or off-grid local merge).
# Connected mode: pull PR body via gh for full parity with the dev->main PR.
# Off-grid mode: preserve the operator's existing merge body (they wrote it
# via git merge --no-ff -m).
# ---------------------------------------------------------------------------

echo "→ mode: $MODE_VAL"

NEW_SUBJECT="[MERGE] dev into main: $RELEASE_TAG"
CUR_SUBJECT=$(git log -1 --format='%s' HEAD)

if [ "$CUR_SUBJECT" = "$NEW_SUBJECT" ]; then
  echo "→ release merge subject already in spec format; skipping amend"
else
  OLD_HEAD=$(git rev-parse HEAD)
  ORIG_AUTHOR_NAME=$(git log -1 --format='%an' HEAD)
  ORIG_AUTHOR_EMAIL=$(git log -1 --format='%ae' HEAD)
  ORIG_AUTHOR_DATE=$(git log -1 --format='%aI' HEAD)
  ORIG_COMMITTER_DATE=$(git log -1 --format='%cI' HEAD)

  NEW_BODY=""
  if [ "$MODE_VAL" = "connected" ] && command -v gh >/dev/null 2>&1; then
    # Resolve the PR number for this dev->main merge. First try the
    # GitHub-default 'Merge pull request #N' shape on the current subject;
    # fall back to searching closed PRs whose head is dev.
    PR_NUM=$(printf '%s' "$CUR_SUBJECT" | sed -nE 's|^Merge pull request #([0-9]+) from .*|\1|p')
    if [ -z "$PR_NUM" ]; then
      REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
      OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
      if [ -n "$OWNER_REPO" ]; then
        PR_NUM=$(gh pr list --repo "$OWNER_REPO" --state merged --head dev --base main --json number --jq '.[0].number' 2>/dev/null || true)
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
  # after the subject line) so the release merge commit's PR pointer is
  # the first thing a reader sees under the spec-format subject, before
  # the recap section. The PR number is followed by the full GitHub
  # PR URL so a reader can click straight through to the source PR
  # from any terminal that auto-links URLs. The URL append is gated on
  # OWNER_REPO being resolvable; when it is not, the reference falls
  # back to the bare "PR #N" form.
  if [ -n "${PR_NUM:-}" ]; then
    PR_LINE="PR #${PR_NUM}"
    if [ -n "${OWNER_REPO:-}" ]; then
      PR_LINE="${PR_LINE} https://github.com/${OWNER_REPO}/pull/${PR_NUM}"
    fi
    NEW_BODY="${PR_LINE}

${NEW_BODY}"
  fi

  # Append the "open work pool branches at release" roster so the main
  # log carries an honest picture of what was still in flight when the
  # release cut went out. It is the LAST topic of the ruled list (git-merge-
  # audit rule 5), one leaf per open pool, so the body keeps the merge shape;
  # an empty roster still renders the topic with an explicit "None" leaf so
  # its existence is verifiable on every release. PR parity ignores this
  # claim-added topic the same way it ignores the PR reference paragraph.
  OPEN_POOL_TOPIC="- Open work pool branches at release."
  OPEN_POOL_ROWS=$(list_open_pool_branches 2>/dev/null || true)
  if [ -z "$OPEN_POOL_ROWS" ]; then
    OPEN_POOL_LEAVES="    - None: no open work pool branches at release."
  else
    OPEN_POOL_LEAVES=$(printf '%s\n' "$OPEN_POOL_ROWS" | awk -F'\t' '{ printf "    - %s: open %s - %s.\n", $1, $2, $3 }')
  fi
  NEW_BODY="$(printf '%s' "$NEW_BODY" | awk '{ l[++n] = $0 } END { while (n > 0 && l[n] ~ /^[ \t]*$/) n--; for (i = 1; i <= n; i++) print l[i] }')
${OPEN_POOL_TOPIC}
${OPEN_POOL_LEAVES}"

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
  # post-merge hook context: git has not yet removed MERGE_HEAD / MERGE_MSG
  # / MERGE_MODE / AUTO_MERGE when the hook fires. The merge IS complete;
  # remove the stale state so git commit --amend does not refuse.
  GIT_DIR=$(git rev-parse --git-dir)
  rm -f "$GIT_DIR/MERGE_HEAD" "$GIT_DIR/MERGE_MSG" "$GIT_DIR/MERGE_MODE" "$GIT_DIR/AUTO_MERGE" 2>/dev/null || true
  HOW_GIT_PRESERVE_AUTHOR=1 GIT_AUTHOR_NAME="$ORIG_AUTHOR_NAME" GIT_AUTHOR_EMAIL="$ORIG_AUTHOR_EMAIL" \
  GIT_AUTHOR_DATE="$ORIG_AUTHOR_DATE" GIT_COMMITTER_DATE="$ORIG_COMMITTER_DATE" \
    git commit --amend -F "$MSG_FILE"
  rm -f "$MSG_FILE"
  NEW_HEAD=$(git rev-parse HEAD)
  echo "→ amended release merge: $OLD_HEAD -> $NEW_HEAD"
  # PR body parity (git-merge-audit, PR body parity): the amended merge
  # body minus the PR reference paragraph must equal the PR body.
  if [ -n "${PR_BODY_SRC:-}" ]; then
    PARITY_FILE=$(mktemp)
    trap 'rm -f "${MSG_FILE:-}" "$PARITY_FILE"' EXIT
    printf '%s\n' "$PR_BODY_SRC" > "$PARITY_FILE"
    if ! bash "$SCRIPT_DIR/check-merge-parity.sh" HEAD --pr-body-file "$PARITY_FILE" --strip-topic "Open work pool branches at release."; then
      rm -f "$PARITY_FILE"
      echo "X claim: merge body and PR body differ after the amend; nothing pushed or tagged" >&2
      exit 1
    fi
    rm -f "$PARITY_FILE"
  fi

  # Force-push main with explicit lease against origin/main's current SHA.
  # The release tag points to a commit on dev (RELEASE_TAG was minted by
  # claim-dev-merge), not to main's merge commit, so the amend does not
  # orphan the tag. Skip the push when origin/main is not present (off-grid
  # scratch repos, no remote tracking ref yet) - the local amend stands on
  # its own.
  if ORIGIN_MAIN_SHA=$(git rev-parse --verify --quiet origin/main 2>/dev/null); then
    git push --force-with-lease="refs/heads/main:$ORIGIN_MAIN_SHA" origin "HEAD:refs/heads/main" || {
      echo "X force-push of amended main rejected; aborting before Release creation" >&2
      exit 1
    }
  else
    echo "→ origin/main not present; skipping force-push of amended main (local-only repo)"
  fi
fi

# --- GitHub Release against the existing dev tag --------------------------
if ! $NO_RELEASE; then
  TOKEN=""
  if [ -n "${GH_TOKEN:-}" ]; then TOKEN="$GH_TOKEN"; fi
  if [ -z "$TOKEN" ] && [ -n "${CREATE_POOL_BRANCH_TOKEN:-}" ]; then TOKEN="$CREATE_POOL_BRANCH_TOKEN"; fi
  if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN=$(gh auth token 2>/dev/null || true); fi
  if [ -z "$TOKEN" ] && [ -d "$HOME/.gcm/store/git/https/github.com" ]; then
    for f in "$HOME"/.gcm/store/git/https/github.com/*.credential; do
      [ -f "$f" ] && TOKEN=$(head -1 "$f" 2>/dev/null || true) && break
    done
  fi
  # Prefer gh CLI when available (the LIFECYCLE_TEST_MODE gh mock intercepts
  # it for offline e2e). Fall back to direct curl POST if gh isn't installed.
  if command -v gh >/dev/null 2>&1; then
    REMOTE_URL=$(git config --get remote.origin.url)
    OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
    if gh release create "$RELEASE_TAG" --repo "$OWNER_REPO" --title "$RELEASE_TAG" --generate-notes >/dev/null 2>&1; then
      echo "  ok: GitHub Release skeleton created against existing tag $RELEASE_TAG (build pipeline attaches the binary asset)"
    else
      echo "  warn: gh release create failed for $RELEASE_TAG (tag still on origin; Release object missing)"
    fi
  elif [ -n "$TOKEN" ] && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    REMOTE_URL=$(git config --get remote.origin.url)
    OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
    PAYLOAD=$(TAG="$RELEASE_TAG" python3 -c "import json,os; print(json.dumps({'tag_name':os.environ['TAG'],'name':os.environ['TAG'],'generate_release_notes':True,'make_latest':'true'}))")
    REL_RESP=$(mktemp -t v4rian-claim-release-resp-XXXXXX)
    trap 'rm -f "${MSG_FILE:-}" "${PARITY_FILE:-}" "$REL_RESP"' EXIT
    REL_CODE=$(curl -sS -o "$REL_RESP" -w "%{http_code}" -X POST \
      -H "Authorization: token $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "https://api.github.com/repos/$OWNER_REPO/releases")
    case "$REL_CODE" in
      201) echo "  ok: GitHub Release skeleton created against existing tag $RELEASE_TAG (curl fallback)" ;;
      *)   echo "  warn: GitHub Release create returned HTTP $REL_CODE. Body:" >&2
           cat "$REL_RESP" >&2 ;;
    esac
    rm -f "$REL_RESP"
  else
    echo "  warn: no gh / no token+curl+python3 - skipping GitHub Release (the existing tag $RELEASE_TAG is canonical anyway)"
  fi
fi

# Safety/ anchor branches are not touched here. The stay-forever rule
# keeps every safety/ ref alive for the life of the repo regardless of
# whether the paired pool branch was released, is in flight, or was
# abandoned.

echo "ok: released $RELEASE_TAG (existing dev tag, promoted via Release object)"
