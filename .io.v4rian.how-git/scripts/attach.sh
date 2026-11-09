#!/usr/bin/env bash
# attach.sh - mid-life adoption: vendor the framework into an existing repo.
#
# Runs FROM a framework/how-git checkout (this checkout is the SOURCE).
# Copies the vendored .io.v4rian.how-git/ directory into an existing
# target repository, wires the acceptance workflows, appends the
# framework .gitignore entries, seeds a local dev branch, activates the
# hooks via the target copy's heal.sh, stamps SPEC provenance, and
# records everything as one [NEW] commit in the target.
#
# The target must NOT already carry a vendored copy - updating an
# existing copy is bin/sync-framework's job, not attach's.
#
# Usage:
#   attach.sh <target-repo-path>              do the adoption
#   attach.sh <target-repo-path> --no-commit  stage in the target, skip the commit
#   attach.sh <target-repo-path> --dry-run    print every planned action, change nothing
#   attach.sh -h | --help                     print this help
#
# Refuses (exit 2) when the target is not a git repo, has no commits, is
# dirty, already carries the vendored copy, or already has workflows with
# framework names, and when the source checkout is incomplete: each would
# make the single attach commit non-atomic or overwrite consumer files.
#
# Exit codes:
#   0  attached (or --dry-run plan printed, or help)
#   1  heal.sh did not activate the hooks in the target, or a git step failed
#   2  usage error or a refused precondition (banner names the fix)

set -euo pipefail

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS_DIR=$(basename "$(dirname "$SCRIPT_DIR")")

# The source is the framework checkout this script ships inside of.
SRC_ROOT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$SRC_ROOT" ]; then
  SRC_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
fi
SRC_NS="$SRC_ROOT/$NS_DIR"

# shellcheck source=_lib.sh
. "$SCRIPT_DIR/_lib.sh"

TARGET_ARG=""
NO_COMMIT=false
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --no-commit) NO_COMMIT=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    -h|--help)   usage ;;
    -*)          echo "X unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -n "$TARGET_ARG" ]; then
        echo "X unexpected extra argument: $1" >&2
        exit 2
      fi
      TARGET_ARG="$1"; shift ;;
  esac
done

if [ -z "$TARGET_ARG" ]; then
  precondition_banner "attach.sh" \
    "no target repository path given." \
    "usage: attach.sh <target-repo-path> [--no-commit] [--dry-run]"
  exit 2
fi

# ---------------------------------------------------------------------------
# Preconditions (read-only; every failure exits 2)
# ---------------------------------------------------------------------------

# 1. Target is a git repo with at least one commit (dev seeds at HEAD).
TGT_ROOT=$(git -C "$TARGET_ARG" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$TGT_ROOT" ]; then
  precondition_banner "attach.sh" \
    "target '$TARGET_ARG' is not a git repository." \
    "attach adopts an EXISTING repo; run git init (with one commit) first," \
    "or use the template paths in $NS_DIR/README.md for brand-new projects."
  exit 2
fi
if ! git -C "$TGT_ROOT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  precondition_banner "attach.sh" \
    "target '$TGT_ROOT' has no commits (unborn HEAD)." \
    "attach seeds the dev branch at the current HEAD; make an initial" \
    "commit in the target, then re-run attach."
  exit 2
fi

# 2. Target does not already carry a vendored framework copy.
if [ -e "$TGT_ROOT/$NS_DIR" ]; then
  precondition_banner "attach.sh" \
    "target '$TGT_ROOT' already contains $NS_DIR/." \
    "attach is the first-time adoption path; to update an existing" \
    "vendored copy use bin/sync-framework instead."
  exit 2
fi

# 3. Target working tree is clean.
if [ -n "$(git -C "$TGT_ROOT" status --porcelain)" ]; then
  precondition_banner "attach.sh" \
    "target '$TGT_ROOT' has a dirty working tree." \
    "commit or stash the target's changes so the attach commit stays" \
    "atomic, then re-run attach."
  exit 2
fi

# 4. The source checkout carries a complete framework directory.
MISSING_PARTS=""
for probe in scripts/_lib.sh scripts/heal.sh githooks bin MODE; do
  [ -e "$SRC_NS/$probe" ] || MISSING_PARTS="$MISSING_PARTS $probe"
done
if [ ! -d "$SRC_NS" ] || [ -n "$MISSING_PARTS" ]; then
  precondition_banner "attach.sh" \
    "source checkout '$SRC_ROOT' does not carry a complete $NS_DIR/." \
    "missing:${MISSING_PARTS:- $NS_DIR}" \
    "run attach from a healthy framework checkout."
  exit 2
fi

# 5. No workflow filename collisions. Checked before ANY copy so a
#    collision aborts the whole adoption rather than leaving a partial one.
# WORKFLOWS is a newline-joined string (not an array) so the script stays
# bash 3.2 safe under set -u even when the source ships no workflows.
WORKFLOWS=""
WORKFLOW_COUNT=0
COLLISIONS=""
for wf in "$SRC_ROOT/.github/workflows/"*.yml; do
  [ -e "$wf" ] || continue
  wf_name=$(basename "$wf")
  WORKFLOWS="$WORKFLOWS$wf_name"$'\n'
  WORKFLOW_COUNT=$((WORKFLOW_COUNT + 1))
  if [ -e "$TGT_ROOT/.github/workflows/$wf_name" ]; then
    COLLISIONS="$COLLISIONS $wf_name"
  fi
done
if [ -n "$COLLISIONS" ]; then
  precondition_banner "attach.sh" \
    "target already has workflows with framework names:" \
    " $COLLISIONS" \
    "rename or remove the colliding target workflows, then re-run attach." \
    "nothing was copied."
  exit 2
fi

# ---------------------------------------------------------------------------
# Provenance inputs (read-only; shared by dry-run and real run)
# ---------------------------------------------------------------------------
SRC_URL=$(git -C "$SRC_ROOT" config --get remote.origin.url 2>/dev/null || true)
[ -n "$SRC_URL" ] || SRC_URL="$SRC_ROOT"
SRC_URL_ACCESS="$SRC_URL"
# The origin URL can embed user:token@ (an authenticated clone). SPEC is
# committed and the plan is printed, so SRC_URL is the credential-free form;
# SRC_URL_ACCESS keeps the original only to query the source (ls-remote,
# fetch) and is never printed or written.
SRC_URL=$(hg_strip_url_credentials "$SRC_URL")
SRC_SHA=$(git -C "$SRC_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
SRC_TAG=$(git -C "$SRC_ROOT" describe --tags --exact-match HEAD 2>/dev/null || echo none)

# SPEC ref= must name a commit the recorded source actually has, or
# sync-framework cannot find its base later. When HEAD carries a tag, stamp
# the commit that tag resolves to AT THE SOURCE (a local tag can point at a
# rewritten twin of the published commit). The published commit is used
# only when its vendored tree matches the local one; otherwise, or when the
# tag is not published, the local SHA stays and the plan says why.
SRC_SHA_NOTE=""
if [ "$SRC_TAG" != "none" ] && [ "$SRC_URL_ACCESS" != "$SRC_ROOT" ]; then
  PUB_SHA=$(hg_source_tag_sha "$SRC_URL_ACCESS" "$SRC_TAG")
  if [ -z "$PUB_SHA" ]; then
    SRC_SHA_NOTE="tag $SRC_TAG is not published at the source; SPEC ref is the local SHA"
  elif [ "$PUB_SHA" != "$SRC_SHA" ]; then
    # Read-only on the source checkout: the published tree is read from a
    # throwaway fetch (hg_source_tree_at), never fetched into SRC_ROOT.
    PUB_TREE=$(hg_source_tree_at "$SRC_URL_ACCESS" "$PUB_SHA" "$NS_DIR" || true)
    LOCAL_TREE=$(git -C "$SRC_ROOT" rev-parse --verify --quiet "HEAD:$NS_DIR" 2>/dev/null || true)
    if [ -n "$PUB_TREE" ] && [ "$PUB_TREE" = "$LOCAL_TREE" ]; then
      SRC_SHA_NOTE="tag $SRC_TAG resolves to $PUB_SHA at the source (local $SRC_SHA, same tree); stamping the source's SHA"
      SRC_SHA="$PUB_SHA"
    else
      SRC_SHA_NOTE="tag $SRC_TAG resolves to $PUB_SHA at the source but its $NS_DIR/ tree differs from local HEAD (or could not be fetched); SPEC ref is the local SHA"
    fi
  fi
fi

# Framework .gitignore entries the target is missing (pattern lines only;
# comments and blanks are prose, not entries). Newline-joined string for
# the same bash 3.2 set -u safety as WORKFLOWS.
GITIGNORE_MISSING=""
GITIGNORE_MISSING_COUNT=0
if [ -f "$SRC_ROOT/.gitignore" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if [ -f "$TGT_ROOT/.gitignore" ] && grep -qxF "$line" "$TGT_ROOT/.gitignore"; then
      continue
    fi
    GITIGNORE_MISSING="$GITIGNORE_MISSING$line"$'\n'
    GITIGNORE_MISSING_COUNT=$((GITIGNORE_MISSING_COUNT + 1))
  done < "$SRC_ROOT/.gitignore"
fi

DEV_EXISTS=false
if git -C "$TGT_ROOT" rev-parse --verify --quiet refs/heads/dev >/dev/null 2>&1; then
  DEV_EXISTS=true
fi

# ---------------------------------------------------------------------------
# Dry run: print the plan, mutate nothing
# ---------------------------------------------------------------------------
if $DRY_RUN; then
  echo "[dry-run] attach plan (source: $SRC_ROOT -> target: $TGT_ROOT):"
  echo "  1. copy $NS_DIR/ into the target, excluding FRAMEWORK_REPO, SPEC, active-requirement, requirements/, .local/, __pycache__ (exec bits preserved)"
  echo "  2. reset $NS_DIR/MODE to 'connected' and $NS_DIR/WARP to 'off'"
  echo "  3. copy $WORKFLOW_COUNT workflow file(s) into .github/workflows/: $(printf '%s' "$WORKFLOWS" | tr '\n' ' ')"
  if [ "$GITIGNORE_MISSING_COUNT" -gt 0 ]; then
    echo "  4. append $GITIGNORE_MISSING_COUNT missing framework entrie(s) to .gitignore: $(printf '%s' "$GITIGNORE_MISSING" | tr '\n' ' ')"
  else
    echo "  4. .gitignore already carries every framework entry (no append)"
  fi
  if $DEV_EXISTS; then
    echo "  5. dev branch already exists (no seed)"
  else
    echo "  5. seed local dev branch at current HEAD (no push)"
  fi
  echo "  6. run $NS_DIR/scripts/heal.sh from the target root and verify core.hooksPath"
  echo "  7. stamp $NS_DIR/SPEC: source=$SRC_URL ref=$SRC_SHA tag=$SRC_TAG"
  [ -z "$SRC_SHA_NOTE" ] || echo "     ($SRC_SHA_NOTE)"
  echo "  8. stage $NS_DIR/, the workflow files, and .gitignore by name"
  if $NO_COMMIT; then
    echo "  9. skip the commit (--no-commit)"
  else
    echo "  9. commit: [NEW] Attach io.v4rian.how-git framework scaffolding"
  fi
  echo "[dry-run] nothing was changed."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Vendored directory copy
# ---------------------------------------------------------------------------
echo "-> copying $NS_DIR/ into $TGT_ROOT"
cp -Rp "$SRC_NS" "$TGT_ROOT/$NS_DIR"
rm -f "$TGT_ROOT/$NS_DIR/FRAMEWORK_REPO" "$TGT_ROOT/$NS_DIR/active-requirement"
# Lane requirement files are the source repo's own branch state.
rm -rf "$TGT_ROOT/$NS_DIR/requirements"
find "$TGT_ROOT/$NS_DIR" -name SPEC -type f -delete
find "$TGT_ROOT/$NS_DIR" -type d \( -name '.local' -o -name '__pycache__' \) -prune -exec rm -rf {} +

# ---------------------------------------------------------------------------
# 2. MODE and WARP reset
# ---------------------------------------------------------------------------
echo "-> resetting $NS_DIR/MODE to connected"
printf 'connected\n' > "$TGT_ROOT/$NS_DIR/MODE"
# Warp is the source repo's own prototyping switch; a consumer starts with
# MERGE_POLICY in force and flips warp itself (bin/warp).
echo "-> resetting $NS_DIR/WARP to off"
printf 'off\n' > "$TGT_ROOT/$NS_DIR/WARP"

# ---------------------------------------------------------------------------
# 3. Workflows
# ---------------------------------------------------------------------------
echo "-> copying $WORKFLOW_COUNT workflow file(s) into .github/workflows/"
mkdir -p "$TGT_ROOT/.github/workflows"
while IFS= read -r wf_name; do
  [ -n "$wf_name" ] || continue
  cp -p "$SRC_ROOT/.github/workflows/$wf_name" "$TGT_ROOT/.github/workflows/$wf_name"
done <<< "$WORKFLOWS"

# ---------------------------------------------------------------------------
# 4. .gitignore append (never rewrites or reorders existing content)
# ---------------------------------------------------------------------------
if [ "$GITIGNORE_MISSING_COUNT" -gt 0 ]; then
  echo "-> appending $GITIGNORE_MISSING_COUNT framework entrie(s) to .gitignore"
  if [ -s "$TGT_ROOT/.gitignore" ] && [ "$(tail -c1 "$TGT_ROOT/.gitignore" | wc -l)" -eq 0 ]; then
    printf '\n' >> "$TGT_ROOT/.gitignore"
  fi
  {
    printf '\n# io.v4rian.how-git framework entries\n'
    printf '%s' "$GITIGNORE_MISSING"
  } >> "$TGT_ROOT/.gitignore"
else
  echo "-> .gitignore already carries every framework entry"
fi

# ---------------------------------------------------------------------------
# 5. dev branch seed
# ---------------------------------------------------------------------------
if $DEV_EXISTS; then
  echo "-> dev branch already exists"
else
  echo "-> seeding local dev branch at current HEAD"
  git -C "$TGT_ROOT" branch dev
fi

# ---------------------------------------------------------------------------
# 6. Heal (activates hooks) + hooksPath verification
# ---------------------------------------------------------------------------
echo "-> running the target copy's heal.sh"
(cd "$TGT_ROOT" && bash "$NS_DIR/scripts/heal.sh")
HOOKS_PATH=$(git -C "$TGT_ROOT" config core.hooksPath 2>/dev/null || true)
if [ "$HOOKS_PATH" != "$NS_DIR/githooks" ]; then
  echo "X attach: heal did not set core.hooksPath (got '${HOOKS_PATH:-unset}', want '$NS_DIR/githooks')" >&2
  exit 1
fi
echo "-> verified core.hooksPath = $HOOKS_PATH"

# ---------------------------------------------------------------------------
# 7. SPEC provenance stamp (from within the target)
# ---------------------------------------------------------------------------
echo "-> stamping SPEC provenance (source=$SRC_URL ref=$SRC_SHA tag=$SRC_TAG)"
[ -z "$SRC_SHA_NOTE" ] || echo "   $SRC_SHA_NOTE"
(cd "$TGT_ROOT" && stamp_spec "$SRC_URL" "$SRC_SHA" "$SRC_TAG")

# ---------------------------------------------------------------------------
# 8. Stage by name; commit unless --no-commit
# ---------------------------------------------------------------------------
echo "-> staging $NS_DIR/, workflow files, and .gitignore by name"
git -C "$TGT_ROOT" add "$NS_DIR"
while IFS= read -r wf_name; do
  [ -n "$wf_name" ] || continue
  git -C "$TGT_ROOT" add ".github/workflows/$wf_name"
done <<< "$WORKFLOWS"
git -C "$TGT_ROOT" add .gitignore

if $NO_COMMIT; then
  echo "-> --no-commit: leaving the attach staged in the target"
else
  echo "-> committing the attach in the target"
  COMMIT_MSG_FILE=$(mktemp -t attach-commit.XXXXXX)
  cat > "$COMMIT_MSG_FILE" <<EOF
[NEW] Attach io.v4rian.how-git framework scaffolding

Adopts the io.v4rian.how-git framework in this repository. The vendored
copy arrives in connected mode with its provenance stamped in SPEC, the
acceptance workflows ride along under .github/workflows, and the
framework ignore entries join the root .gitignore.

- .io.v4rian.how-git
  - Vendors the framework scripts, hooks, workflows engine, and skills from the source checkout.
  - Records source, ref, and tag provenance in SPEC.
- .github/workflows
  - Copies the framework acceptance dispatchers.
- .gitignore
  - Adds the framework entries missing from the existing file.
EOF
  # The vendored copy must land byte for byte as the source carries it.
  # heal.sh just activated the target's hooks; their pre-commit scrub and
  # message auto-fix would rewrite vendored files (dashes in prose) and
  # make the copy drift from canonical, so this one machine-composed
  # commit runs with hooks disabled.
  git -C "$TGT_ROOT" -c core.hooksPath=/dev/null commit -F "$COMMIT_MSG_FILE"
  rm -f "$COMMIT_MSG_FILE"
fi

# ---------------------------------------------------------------------------
# 9. Next steps
# ---------------------------------------------------------------------------
echo ""
echo "ok: framework attached to $TGT_ROOT"
echo ""
echo "next steps:"
echo "  connected (GitHub remote):  bin/bootstrap-ci    # seed dev remotely, rules, required checks"
echo "  off-grid (no forge):        bin/set-mode off-grid"
echo "  docs:                       $NS_DIR/docs/RUNBOOK.md"
