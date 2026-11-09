#!/usr/bin/env bash
# sync-framework.sh - migrate a consumer repo's vendored framework copy to a
# different framework spec version, UP or DOWN.
#
# A consumer repo carries a vendored copy of the framework under
# .io.v4rian.how-git/ (and the CI dispatchers under .github/workflows/). This
# script moves that copy from the revision it was taken at (the BASE) to any
# other revision of the framework source (the TARGET) by computing the
# migration diff in a fresh clone of the source and applying it three way in
# the consumer. Downgrade is the same mechanic with an older target ref: the
# diff simply points the other way, so rolling back to a prior tag is
# `sync-framework <older-tag>` with no special casing.
#
# Consumer owned state under the vendored namespace never rides the
# migration diff: MODE, SPEC, FRAMEWORK_REPO, admins.txt, MERGE_POLICY, WARP and
# active-requirement are pathspec excluded from the computed diff, so a
# consumer's mode choice, provenance record, and admin roster survive every
# migration in both directions.
#
# Mechanic:
#   1. Resolves the framework source (--source flag, else SPEC source=).
#   2. Clones the source into a temp dir and resolves the target sha there.
#   3. Resolves the base sha: --base-ref wins; else SPEC ref=; else content
#      matching of the consumer's vendored tree against the clone's tags and
#      dev/main tips (consumer owned files ignored in the comparison).
#   4. Fetches base and target objects into the consumer so the three way
#      apply has blobs to merge against.
#   5. Computes the base..target diff in the clone (framework paths only,
#      consumer owned state excluded) and applies it with
#      `git apply --3way --index`.
#   6. On conflicts: leaves the markers and the unmerged index entries in
#      place, prints the conflicted files and the resolution steps, and
#      exits 1 without committing or restamping.
#   7. On a clean apply: runs heal.sh (exec bits, hooksPath), restamps SPEC
#      to the target, and commits unless --no-commit.
#
# Usage:
#   sync-framework.sh <target-ref> [--source <url-or-path>] [--base-ref <sha>]
#                     [--no-commit] [--dry-run]
#
#   <target-ref>            tag, branch, or sha in the framework source
#   --source <url-or-path>  framework source override (else SPEC source=)
#   --base-ref <sha>        base revision override (else SPEC ref=, else
#                           content matching)
#   --no-commit             apply and restamp but leave the result staged
#   --dry-run               print resolved source, base, target, diffstat,
#                           and the planned stamp; change nothing
#   -h | --help             print this help
#
# Exit codes: 0 success, 1 conflicted apply, 2 precondition or resolution
# failure.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "X sync-framework.sh: not inside a git repo" >&2
  exit 2
fi

NS_DIR=$(basename "$(dirname "$SCRIPT_DIR")")
HOOKS_PATH_OVERRIDE="$NS_DIR/githooks"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# Consumer owned files under the vendored namespace. Never migrated, never
# part of the base fingerprint comparison.
CONSUMER_OWNED="MODE SPEC FRAMEWORK_REPO admins.txt active-requirement requirements MERGE_POLICY WARP"

TARGET_REF=""
SOURCE_OVERRIDE=""
BASE_OVERRIDE=""
NO_COMMIT=false
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --source)    SOURCE_OVERRIDE="${2:-}"; shift 2 ;;
    --base-ref)  BASE_OVERRIDE="${2:-}"; shift 2 ;;
    --no-commit) NO_COMMIT=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    -h|--help)   sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          echo "X unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -n "$TARGET_REF" ]; then
        echo "X unexpected extra argument: $1" >&2
        exit 2
      fi
      TARGET_REF="$1"; shift
      ;;
  esac
done

echo "-> sync-framework starting in $REPO_ROOT"

CLONE_DIR=""
cleanup() {
  local rc=$?
  [ -n "$CLONE_DIR" ] && rm -rf "$CLONE_DIR"
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ] && [ "$rc" -ne 2 ]; then
    echo "X sync-framework.sh exited rc=$rc (last command: $BASH_COMMAND)" >&2
  fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

# --- preconditions ---------------------------------------------------------

if [ ! -d "$REPO_ROOT/$NS_DIR" ]; then
  precondition_banner "sync-framework" \
    "No $NS_DIR/ directory at the repo root." \
    "This tool migrates an existing vendored framework copy; nothing to sync."
  exit 2
fi

if [ -f "$REPO_ROOT/$NS_DIR/FRAMEWORK_REPO" ]; then
  precondition_banner "sync-framework" \
    "The FRAMEWORK_REPO marker is present: this repo IS the framework source." \
    "sync-framework runs only in consumer repos; the source repo advances" \
    "through its own pool/dev/main lifecycle, not through vendored sync."
  exit 2
fi

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  precondition_banner "sync-framework" \
    "The working tree is not clean." \
    "The migration applies a three way diff onto the index and working tree;" \
    "commit or stash local changes first, then re-run."
  exit 2
fi

if [ -z "$TARGET_REF" ]; then
  precondition_banner "sync-framework" \
    "No target ref given." \
    "Usage: sync-framework <target-ref> [--source <url-or-path>]" \
    "       [--base-ref <sha>] [--no-commit] [--dry-run]"
  exit 2
fi

ensure_hooks_path

# --- resolve the framework source ------------------------------------------

SOURCE="$SOURCE_OVERRIDE"
if [ -z "$SOURCE" ]; then
  SOURCE=$(get_spec_field source 2>/dev/null || true)
fi
if [ -z "$SOURCE" ]; then
  precondition_banner "sync-framework" \
    "Cannot resolve the framework source." \
    "No --source flag was given and $NS_DIR/SPEC carries no source= line." \
    "Pass the framework clone URL or local path explicitly:" \
    "  sync-framework $TARGET_REF --source <url-or-path>"
  exit 2
fi
# SOURCE may carry user:token@ (a --source override or an old SPEC); it is
# used as is for the clone, and only SOURCE_STAMP (credential-free) is
# printed or written to SPEC.
SOURCE_STAMP=$(hg_strip_url_credentials "$SOURCE")
echo "  source: $SOURCE_STAMP"

# --- clone the source, resolve target --------------------------------------

CLONE_DIR=$(mktemp -d -t sync-framework.XXXXXX)
if ! git clone --quiet "$SOURCE" "$CLONE_DIR" 2>/dev/null; then
  precondition_banner "sync-framework" \
    "Failed to clone the framework source." \
    "  source: $SOURCE_STAMP" \
    "Check the URL or path and your access to it, then re-run."
  exit 2
fi
# Allow the consumer to fetch the exact base/target shas from this clone even
# when they are not branch or tag tips.
git -C "$CLONE_DIR" config uploadpack.allowAnySHA1InWant true

resolve_in_clone() {
  local ref="$1" sha
  sha=$(git -C "$CLONE_DIR" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null || true)
  if [ -z "$sha" ]; then
    sha=$(git -C "$CLONE_DIR" rev-parse --verify --quiet "origin/${ref}^{commit}" 2>/dev/null || true)
  fi
  printf '%s' "$sha"
}

TARGET_SHA=$(resolve_in_clone "$TARGET_REF")
if [ -z "$TARGET_SHA" ]; then
  precondition_banner "sync-framework" \
    "Target ref '$TARGET_REF' is unknown in the framework source." \
    "  source: $SOURCE_STAMP" \
    "Known tags:" \
    "$(git -C "$CLONE_DIR" tag | sed 's/^/    /' | head -20)"
  exit 2
fi
echo "  target: $TARGET_REF at $TARGET_SHA"

# Exact tag at the target, for the SPEC stamp. Prefer the operator's own ref
# name when it is itself a tag; otherwise the first tag pointing at the sha.
TARGET_TAG="none"
if git -C "$CLONE_DIR" rev-parse --verify --quiet "refs/tags/$TARGET_REF" >/dev/null 2>&1; then
  TARGET_TAG="$TARGET_REF"
else
  TARGET_TAG=$(git -C "$CLONE_DIR" tag --points-at "$TARGET_SHA" 2>/dev/null | head -1)
  [ -n "$TARGET_TAG" ] || TARGET_TAG="none"
fi

# --- resolve the base ------------------------------------------------------

# Fingerprint of the vendored framework tree at a revision with the consumer
# owned files removed. Blob shas are content hashes, so the same framework
# content yields the same fingerprint in the consumer and in the source clone
# even though the surrounding trees differ (SPEC exists only in consumers,
# FRAMEWORK_REPO only in the source).
vendored_fingerprint() {
  local dir="$1" rev="$2" listing name
  listing=$(git -C "$dir" ls-tree -r "${rev}:.io.v4rian.how-git" 2>/dev/null || true)
  [ -n "$listing" ] || return 1
  for name in $CONSUMER_OWNED; do
    listing=$(printf '%s\n' "$listing" | awk -v skip="$name" '$4 != skip && index($4, skip "/") != 1')
  done
  printf '%s\n' "$listing" | sort
}

BASE_SHA=""
BASE_HOW=""
if [ -n "$BASE_OVERRIDE" ]; then
  BASE_SHA=$(resolve_in_clone "$BASE_OVERRIDE")
  if [ -z "$BASE_SHA" ]; then
    precondition_banner "sync-framework" \
      "--base-ref '$BASE_OVERRIDE' is unknown in the framework source." \
      "  source: $SOURCE_STAMP"
    exit 2
  fi
  BASE_HOW="--base-ref"
else
  SPEC_REF=$(get_spec_field ref 2>/dev/null || true)
  if [ -n "$SPEC_REF" ] && [ "$SPEC_REF" != "unknown" ]; then
    if git -C "$CLONE_DIR" cat-file -e "${SPEC_REF}^{commit}" 2>/dev/null; then
      BASE_SHA="$SPEC_REF"
      BASE_HOW="SPEC ref="
    fi
    # Older attaches stamped the local SHA of a checkout whose tag points
    # at a rewritten twin in the source. Recover through SPEC tag= when the
    # tag exists in the source AND its vendored tree matches this copy.
    SPEC_TAG=$(get_spec_field tag 2>/dev/null || true)
    if [ -z "$BASE_SHA" ] && [ -n "$SPEC_TAG" ] && [ "$SPEC_TAG" != "none" ]; then
      TAG_SHA=$(resolve_in_clone "$SPEC_TAG")
      if [ -n "$TAG_SHA" ] \
         && [ "$(vendored_fingerprint "$CLONE_DIR" "$TAG_SHA" || true)" = "$(vendored_fingerprint "$REPO_ROOT" HEAD || true)" ]; then
        BASE_SHA="$TAG_SHA"
        BASE_HOW="SPEC tag=$SPEC_TAG (SPEC ref=$SPEC_REF is absent in the source; same vendored tree)"
      fi
    fi
    if [ -z "$BASE_SHA" ]; then
      precondition_banner "sync-framework" \
        "SPEC records ref=$SPEC_REF but that commit does not exist in the source." \
        "  source: $SOURCE_STAMP" \
        "Either the SPEC is stale or the source is the wrong repo. Pass the" \
        "true base explicitly:" \
        "  sync-framework $TARGET_REF --base-ref <sha>"
      exit 2
    fi
  fi
fi

if [ -z "$BASE_SHA" ]; then
  # Content matching: compare the consumer's vendored tree fingerprint
  # against every tag and the dev/main tips of the source clone. An exact
  # match identifies the revision this copy was taken from.
  CONSUMER_FP=$(vendored_fingerprint "$REPO_ROOT" HEAD || true)
  if [ -z "$CONSUMER_FP" ]; then
    precondition_banner "sync-framework" \
      "HEAD carries no committed $NS_DIR/ tree to fingerprint." \
      "Commit the vendored framework copy first, or pass --base-ref."
    exit 2
  fi
  CANDIDATES=$(git -C "$CLONE_DIR" tag)
  for tip in dev main origin/dev origin/main; do
    if git -C "$CLONE_DIR" rev-parse --verify --quiet "$tip" >/dev/null 2>&1; then
      CANDIDATES=$(printf '%s\n%s' "$CANDIDATES" "$tip")
    fi
  done
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    CAND_SHA=$(resolve_in_clone "$cand")
    [ -n "$CAND_SHA" ] || continue
    CAND_FP=$(vendored_fingerprint "$CLONE_DIR" "$CAND_SHA" || true)
    if [ -n "$CAND_FP" ] && [ "$CAND_FP" = "$CONSUMER_FP" ]; then
      BASE_SHA="$CAND_SHA"
      BASE_HOW="content match ($cand)"
      break
    fi
  done <<EOF
$CANDIDATES
EOF
  if [ -z "$BASE_SHA" ]; then
    precondition_banner "sync-framework" \
      "Cannot resolve the base revision of this vendored copy." \
      "No SPEC ref= is recorded and the vendored tree matches none of the" \
      "source's tags or dev/main tips (local edits to framework owned files" \
      "break content matching)." \
      "Name the revision the copy was taken from explicitly:" \
      "  sync-framework $TARGET_REF --base-ref <sha>"
    exit 2
  fi
fi
echo "  base:   $BASE_SHA (via $BASE_HOW)"

if [ "$BASE_SHA" = "$TARGET_SHA" ]; then
  echo "  base and target are the same commit; nothing to migrate"
  exit 0
fi

# --- fetch objects, compute the migration diff -----------------------------

git fetch --quiet "$CLONE_DIR" "$BASE_SHA" "$TARGET_SHA"

DIFF_PATHSPEC=(-- .io.v4rian.how-git .github/workflows)
for name in $CONSUMER_OWNED; do
  DIFF_PATHSPEC+=(":(exclude).io.v4rian.how-git/$name")
done

PATCH_FILE=$(mktemp -t sync-framework-patch.XXXXXX)
git -C "$CLONE_DIR" diff --binary --full-index "$BASE_SHA" "$TARGET_SHA" \
  ${DIFF_PATHSPEC[@]+"${DIFF_PATHSPEC[@]}"} > "$PATCH_FILE"
DIFFSTAT=$(git -C "$CLONE_DIR" diff --stat "$BASE_SHA" "$TARGET_SHA" \
  ${DIFF_PATHSPEC[@]+"${DIFF_PATHSPEC[@]}"})

if $DRY_RUN; then
  echo ""
  echo "[dry-run] resolved migration plan (nothing changed):"
  echo "  source: $SOURCE_STAMP"
  echo "  base:   $BASE_SHA (via $BASE_HOW)"
  echo "  target: $TARGET_REF at $TARGET_SHA (tag: $TARGET_TAG)"
  echo ""
  if [ -s "$PATCH_FILE" ]; then
    echo "$DIFFSTAT"
  else
    echo "  (empty migration diff; only the SPEC stamp would change)"
  fi
  echo ""
  echo "  would restamp SPEC: source=$SOURCE_STAMP ref=$TARGET_SHA tag=$TARGET_TAG"
  if $NO_COMMIT; then
    echo "  would leave the result staged (--no-commit)"
  else
    echo "  would commit: [REFACTOR] Sync vendored framework to $TARGET_REF"
  fi
  rm -f "$PATCH_FILE"
  exit 0
fi

# --- apply -------------------------------------------------------------------

if [ -s "$PATCH_FILE" ]; then
  echo "  applying migration diff (three way)"
  if ! git apply --3way --index "$PATCH_FILE"; then
    CONFLICTED=$(git diff --name-only --diff-filter=U)
    rm -f "$PATCH_FILE"
    echo ""
    echo "X sync-framework: the migration diff did not apply cleanly." >&2
    if [ -n "$CONFLICTED" ]; then
      echo "  Conflicted files (markers left in place):" >&2
      printf '%s\n' "$CONFLICTED" | sed 's/^/    /' >&2
    fi
    echo "" >&2
    echo "  Resolve by hand, then finish the migration:" >&2
    echo "    1. Edit each conflicted file and clear the <<<<<<< markers." >&2
    echo "    2. git add <each resolved file>" >&2
    echo "    3. Restamp the SPEC to the target you migrated to:" >&2
    echo "       bash -c '. $NS_DIR/scripts/_lib.sh; stamp_spec \"$SOURCE_STAMP\" \"$TARGET_SHA\" \"$TARGET_TAG\"'" >&2
    echo "       git add $NS_DIR/SPEC" >&2
    echo "    4. git commit with the [REFACTOR] sync subject." >&2
    echo "  Or abandon: git reset --hard HEAD" >&2
    exit 1
  fi
else
  echo "  migration diff is empty; only the SPEC stamp changes"
fi
rm -f "$PATCH_FILE"

# --- heal, restamp, commit ---------------------------------------------------

echo "  running heal.sh on the migrated copy"
bash "$REPO_ROOT/$NS_DIR/scripts/heal.sh"
# Pick up any exec-bit normalization heal made to tracked framework files so
# the commit carries the healed modes.
git add -u -- "$NS_DIR"
if [ -d .github/workflows ]; then
  git add -u -- .github/workflows
fi

stamp_spec "$SOURCE_STAMP" "$TARGET_SHA" "$TARGET_TAG"
git add -- "$NS_DIR/SPEC"

if $NO_COMMIT; then
  echo ""
  echo "OK migration applied and staged (--no-commit); SPEC restamped to $TARGET_SHA"
  exit 0
fi

if git diff --cached --quiet; then
  echo "  nothing staged after the migration; no commit created"
  exit 0
fi

# Compose the commit body: description paragraph, then one bullet per staged
# path group from the migration surface, then the SPEC restamp bullet. Groups
# come straight from the staged file list; no symbol names are fabricated.
BODY="Migrates the vendored framework copy from $(git rev-parse --short "$BASE_SHA") to $TARGET_REF at $(git rev-parse --short "$TARGET_SHA") by a three way apply of the framework source diff. Consumer owned state under the vendored namespace stays outside the migration surface."
# Named SURFACE_GROUPS because GROUPS is a bash special read-only variable;
# assigning to it is silently ignored.
SURFACE_GROUPS=$(git diff --cached --name-only | grep -v "^$NS_DIR/SPEC$" \
  | sed -E "s|^($NS_DIR/[^/]+)/.*|\1|; s|^\.github/workflows/.*|.github/workflows|" \
  | sort | uniq -c | sort -rn)
BULLETS=""
while read -r count group; do
  [ -n "$group" ] || continue
  if [ "$count" -eq 1 ]; then
    BULLETS="$BULLETS- Updates 1 file under $group.
"
  else
    BULLETS="$BULLETS- Updates $count files under $group.
"
  fi
done <<EOF
$SURFACE_GROUPS
EOF
if [ "$TARGET_TAG" != "none" ]; then
  BULLETS="$BULLETS- Restamps SPEC to $(git rev-parse --short "$TARGET_SHA") (tag $TARGET_TAG)."
else
  BULLETS="$BULLETS- Restamps SPEC to $(git rev-parse --short "$TARGET_SHA")."
fi

# Hooks disabled for this machine-composed commit: the consumer's pre-commit
# scrub and message auto-fix would rewrite migrated vendored files and make
# the copy drift from the framework source.
git -c core.hooksPath=/dev/null commit -m "[REFACTOR] Sync vendored framework to $TARGET_REF" \
  -m "$BODY" -m "$BULLETS"

echo ""
echo "OK vendored framework synced to $TARGET_REF ($TARGET_SHA, tag: $TARGET_TAG)"
LEGACY_LANES=$(hg_legacy_requirement_lanes | tr '\n' ' ')
if [ -n "$(printf '%s' "$LEGACY_LANES" | tr -d ' ')" ]; then
  echo "   note: lanes allocated before per-lane requirement files still carry the shared"
  echo "   active-requirement and would collide on dev: $LEGACY_LANES"
  echo "   migrate them once: bash $NS_DIR/scripts/migrate-active-requirement.sh"
fi
echo "   commit: $(git rev-parse --short HEAD)"
