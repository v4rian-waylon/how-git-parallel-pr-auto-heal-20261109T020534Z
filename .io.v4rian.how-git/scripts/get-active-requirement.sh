#!/usr/bin/env bash
# get-active-requirement.sh — fetch the active-requirement document for a
# pool/* branch.
#
# Auditors and the smart-commit tool call this script when they invoke
# claude on behalf of work happening on a pool branch. The output is the
# verbatim requirement text the allocator stamped on the branch at
# creation time. Claude reads that text and treats it as the canonical
# intent for the branch.
#
# Sources, in order (the first non-empty one wins):
#
#   1. The lane's own file .io.v4rian.how-git/requirements/<key> at the
#      branch tip, where <key> is the branch name with "/" as "__"
#      (hg_requirement_path in _lib.sh). One path per lane, so parallel
#      lanes never collide on it and a lane that merges dev still reads
#      its own.
#
#   2. The first [REQ] commit on the pool branch reachable from the
#      branch tip but not from origin/dev (the allocator's initial
#      commit by construction): the requirements file it added, read at
#      the tip (so a SHA or a detached HEAD gets the verbatim text too),
#      else its body for legacy lanes.
#
#   3. Legacy: the single shared .io.v4rian.how-git/active-requirement
#      file that allocators before the per-lane layout wrote. Read last
#      because after a merge it can carry another lane's text.
#
# Behaviour:
#
#   - Prints the requirement text on stdout, no trailing decoration,
#     no banners. Suitable for piping straight into a claude prompt
#     template.
#   - Exits 0 when a requirement was found.
#   - Exits 0 with empty stdout when the branch has no requirement
#     attached (legacy branches that predate this step, or branches
#     allocated without --requirement). The caller decides whether
#     to proceed without context or to surface the absence.
#   - Exits 2 only on a usage error (missing/invalid branch arg).
#
# Usage:
#   .io.v4rian.how-git/scripts/get-active-requirement.sh <pool-branch>
#
# Examples:
#   .io.v4rian.how-git/scripts/get-active-requirement.sh pool/n51.feature.PROJ-7-parser
#   .io.v4rian.how-git/scripts/get-active-requirement.sh HEAD
#   REQ=$(.io.v4rian.how-git/scripts/get-active-requirement.sh "$BRANCH")
#   claude -p "Active requirement: $REQ"$'\n\n'"...rest of prompt..."

set -uo pipefail

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo "get-active-requirement: missing branch argument" >&2
  echo "usage: $(basename "$0") <pool-branch|HEAD|sha>" >&2
  exit 2
fi

BRANCH="$1"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "get-active-requirement: not inside a git repo" >&2
  exit 2
fi

cd "$REPO_ROOT"

# The _lib.sh shipped beside this script (one convention across scripts/):
# a tool run from the framework tree against an older consumer must not
# load that consumer's vendored copy.
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# Branch name for the per-lane key: HEAD and remote-tracking refs
# (origin/pool/...) resolve to the plain pool branch name.
BRANCH_NAME=$(git rev-parse --symbolic-full-name "$BRANCH" 2>/dev/null || true)
case "$BRANCH_NAME" in
  refs/heads/*)   BRANCH_NAME="${BRANCH_NAME#refs/heads/}" ;;
  refs/remotes/*) BRANCH_NAME="${BRANCH_NAME#refs/remotes/}"; BRANCH_NAME="${BRANCH_NAME#*/}" ;;
  *)              BRANCH_NAME="" ;;
esac

# ---------------------------------------------------------------------------
# Source 1: the lane's own requirement file (cheap path)
# ---------------------------------------------------------------------------
# `git show <branch>:<path>` is the most portable way to read a tracked
# file at a ref without checking the branch out. Silently swallow stderr;
# absence of the file is a normal outcome, not an error.
if [ -n "$BRANCH_NAME" ]; then
  FILE_CONTENT=$(git show "${BRANCH}:$(hg_requirement_path "$BRANCH_NAME")" 2>/dev/null || true)
  if [ -n "$FILE_CONTENT" ]; then
    printf '%s' "$FILE_CONTENT"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Source 2: initial [REQ] commit body (fallback)
# ---------------------------------------------------------------------------
# Walk the branch's history back to the first commit reachable from the
# branch tip but not reachable from origin/dev (or local dev). That
# commit is the allocator's initial [REQ] commit by construction. Skip
# any [MERGE] commits that may appear if the branch has been merged
# back-and-forth.
BASE_REF=""
for candidate in origin/dev dev; do
  if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
    BASE_REF="$candidate"
    break
  fi
done

if [ -n "$BASE_REF" ]; then
  FIRST_REQ_SHA=""
  while read -r sha; do
    [ -z "$sha" ] && continue
    subj=$(git log -1 --format=%s "$sha" 2>/dev/null || true)
    if [ "${subj#\[REQ\] active-requirement:}" != "$subj" ]; then
      FIRST_REQ_SHA="$sha"
      break
    fi
  done < <(git rev-list --reverse "$BRANCH" "^$BASE_REF" 2>/dev/null || true)

  if [ -n "$FIRST_REQ_SHA" ]; then
    # No branch name resolved (a SHA, a detached HEAD): the [REQ] commit
    # names the lane's file itself. Read that file at $BRANCH so the text
    # is the verbatim one, as it is by name.
    REQ_FILE=$(git diff-tree --no-commit-id --name-only --diff-filter=A -r "$FIRST_REQ_SHA" -- "$HG_REQUIREMENTS_DIR" 2>/dev/null | head -1)
    if [ -n "$REQ_FILE" ]; then
      FILE_CONTENT=$(git show "${BRANCH}:${REQ_FILE}" 2>/dev/null || true)
      if [ -n "$FILE_CONTENT" ]; then
        printf '%s' "$FILE_CONTENT"
        exit 0
      fi
    fi
    # Legacy lanes: print the commit BODY only (skip subject + blank
    # separator), the requirement text per the allocator's composition
    # rule (rule-scrubbed since the per-lane layout).
    git log -1 --format='%b' "$FIRST_REQ_SHA"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Source 3: legacy shared file (lanes allocated before the per-lane layout)
# ---------------------------------------------------------------------------
# Only when the lane itself wrote it: a copy inherited unchanged from dev
# (left there by an older merged lane) is another lane's text.
LEGACY_BLOB=$(git rev-parse -q --verify "${BRANCH}:${HG_LEGACY_REQUIREMENT}" 2>/dev/null || true)
if [ -n "$LEGACY_BLOB" ]; then
  LEGACY_BASE_BLOB=""
  for candidate in origin/dev dev; do
    if FORK=$(git merge-base "$BRANCH" "$candidate" 2>/dev/null); then
      LEGACY_BASE_BLOB=$(git rev-parse -q --verify "${FORK}:${HG_LEGACY_REQUIREMENT}" 2>/dev/null || true)
      break
    fi
  done
  if [ "$LEGACY_BLOB" != "$LEGACY_BASE_BLOB" ]; then
    git cat-file blob "$LEGACY_BLOB"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# No requirement available — exit 0 with empty stdout. The caller is
# expected to handle the empty case (proceed without context OR refuse).
# ---------------------------------------------------------------------------
exit 0
