#!/usr/bin/env bash
# ci-dispatch.sh - body of the ci-dispatch workflow.
#
# Walks the usr-layer (repo-root ci/) and the sys-layer
# (.io.v4rian.how-git/ci/) for a given trigger, runs each .sh as a
# separate status check, and reports the per-check outcome via the
# GitHub Checks / Statuses API. The dispatcher is what makes the
# layered ci/{tests,audits}/{trigger}/*.sh convention visible to
# branch protection: every script's basename (minus .sh) becomes the
# check context name, and any file whose basename starts with
# required. is intended to be bound as a required status check by
# bin/bootstrap-ci step 5.
#
# Two layers feed the walk:
#   - usr layer (repo-root ci/) runs on every repo, always.
#   - sys layer (.io.v4rian.how-git/ci/) runs ONLY when the
#     FRAMEWORK_REPO marker is present at .io.v4rian.how-git/
#     FRAMEWORK_REPO. The marker is the same source of truth that
#     gates the offline-test workflow per pool/n45.
#
# Per-trigger sub-dirs the dispatcher knows about:
#   push, pr-open, pr-merge-dev, pr-merge-main, tag
#
# Invocation:
#   ci-dispatch.sh --trigger <trigger> [--layer usr|sys|both]
#                  [--kind tests|audits|both]
#                  [--list]
#
# --layer / --kind narrow the walk for the GitHub matrix job (one
# matrix entry per (layer, kind, script) tuple). --list emits the
# discovered scripts in TAB-separated form (layer<TAB>kind<TAB>path
# <TAB>check_name<TAB>required) so the workflow's pre-step can
# generate the matrix.
#
# Exit code:
#   0   every selected script exited 0 (or the selection was empty)
#   non-zero  at least one script failed
#
# Environment passed to each script:
#   CI_TRIGGER       same value as --trigger
#   CI_LAYER         usr | sys
#   CI_KIND          tests | audits
#   CI_CHECK_NAME    basename minus .sh (e.g. required.compile)
#   CI_REQUIRED      true when basename matches required.*, else false

set -uo pipefail

TRIGGER=""
LAYER_FILTER="both"
KIND_FILTER="both"
MODE="run"  # run | list

while [ $# -gt 0 ]; do
  case "$1" in
    --trigger) TRIGGER="$2"; shift 2 ;;
    --layer)   LAYER_FILTER="$2"; shift 2 ;;
    --kind)    KIND_FILTER="$2"; shift 2 ;;
    --list)    MODE="list"; shift ;;
    -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "X ci-dispatch.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

if [ -z "$TRIGGER" ]; then
  echo "X ci-dispatch.sh: --trigger <name> is required" >&2
  exit 2
fi

case "$TRIGGER" in
  push|pr-open|pr-merge-dev|pr-merge-main|tag) ;;
  *) echo "X ci-dispatch.sh: unknown trigger '$TRIGGER' (want push, pr-open, pr-merge-dev, pr-merge-main, tag)" >&2; exit 2 ;;
esac

case "$LAYER_FILTER" in
  usr|sys|both) ;;
  *) echo "X ci-dispatch.sh: --layer must be usr, sys, or both (got '$LAYER_FILTER')" >&2; exit 2 ;;
esac

case "$KIND_FILTER" in
  tests|audits|both) ;;
  *) echo "X ci-dispatch.sh: --kind must be tests, audits, or both (got '$KIND_FILTER')" >&2; exit 2 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MARKER="$REPO_ROOT/.io.v4rian.how-git/FRAMEWORK_REPO"

# Compose the layer list once. The sys layer is unconditionally
# skipped when the FRAMEWORK_REPO marker is absent - this is the
# whole consumer-vs-source split the directory layout exists to
# express.
LAYERS=()
if [ "$LAYER_FILTER" = "usr" ] || [ "$LAYER_FILTER" = "both" ]; then
  LAYERS+=("usr")
fi
if [ "$LAYER_FILTER" = "sys" ] || [ "$LAYER_FILTER" = "both" ]; then
  if [ -f "$MARKER" ]; then
    LAYERS+=("sys")
  else
    if [ "$MODE" = "run" ]; then
      echo "=> ci-dispatch: sys layer requested but FRAMEWORK_REPO marker absent; skipping sys"
    fi
  fi
fi

KINDS=()
if [ "$KIND_FILTER" = "tests" ] || [ "$KIND_FILTER" = "both" ]; then
  KINDS+=("tests")
fi
if [ "$KIND_FILTER" = "audits" ] || [ "$KIND_FILTER" = "both" ]; then
  KINDS+=("audits")
fi

# Resolve a (layer, kind) tuple to the on-disk directory.
layer_dir() {
  local layer="$1" kind="$2"
  case "$layer" in
    usr) echo "$REPO_ROOT/ci/$kind/$TRIGGER" ;;
    sys) echo "$REPO_ROOT/.io.v4rian.how-git/ci/$kind/$TRIGGER" ;;
  esac
}

# Enumerate matched scripts. The output is TAB-separated lines:
#   layer<TAB>kind<TAB>script_path<TAB>check_name<TAB>required<TAB>basename
enumerate() {
  local layer kind dir f bn name req
  for layer in ${LAYERS[@]+"${LAYERS[@]}"}; do
    for kind in ${KINDS[@]+"${KINDS[@]}"}; do
      dir=$(layer_dir "$layer" "$kind")
      [ -d "$dir" ] || continue
      # Iterate via find so a missing-shell-glob does not produce a
      # literal '*' entry. Sort for deterministic order across runs.
      while IFS= read -r f; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        case "$bn" in
          .*) continue ;;  # skip hidden files like .gitkeep
        esac
        # check_name is the basename minus the trailing .sh
        name="${bn%.sh}"
        if [ "$name" = "$bn" ]; then
          # not a .sh - skip (README.md, .gitkeep, etc.)
          continue
        fi
        case "$bn" in
          required.*) req="true" ;;
          *)          req="false" ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$layer" "$kind" "$f" "$name" "$req" "$bn"
      done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort)
    done
  done

  # Consumer claim exception: the merge claims (amend, tag mint/promote,
  # vault/archive) are LIFECYCLE, not framework self-tests - yet they ship
  # only in the sys tree, which consumers skip. Without this carve-out no
  # consumer ever gets a merge claim or a version tag (verified live:
  # "no scripts matched trigger=pr-merge-main" on a consumer release).
  # Framework repos (marker present) already enumerated sys above.
  if [ ! -f "$MARKER" ]; then
    case "$TRIGGER" in
      pr-merge-dev|pr-merge-main)
        local cf="$REPO_ROOT/.io.v4rian.how-git/ci/audits/$TRIGGER/required.claim.sh"
        if [ -f "$cf" ]; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "sys" "audits" "$cf" "required.claim" "true" "required.claim.sh"
        fi
        ;;
    esac
  fi
}

if [ "$MODE" = "list" ]; then
  enumerate
  exit 0
fi

# Run mode: invoke every enumerated script in order, capture per-script
# exit code, summarize at the end. The workflow itself fans out one
# matrix job per script so this run mode is most useful for local
# operator runs and for the case where the matrix is collapsed (e.g.
# a small ci-dispatch invocation from an off-grid laptop).
overall=0
total=0
passed=0
failed_names=()

while IFS=$'\t' read -r layer kind script name req bn; do
  total=$((total + 1))
  echo
  echo "=== ci-dispatch [$TRIGGER] $layer/$kind/$bn (required=$req) ==="
  CI_TRIGGER="$TRIGGER" \
  CI_LAYER="$layer" \
  CI_KIND="$kind" \
  CI_CHECK_NAME="$name" \
  CI_REQUIRED="$req" \
  bash "$script"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    passed=$((passed + 1))
    echo "=== PASS $name ==="
  else
    overall=1
    failed_names+=("$name (rc=$rc)")
    echo "=== FAIL $name (rc=$rc) ==="
  fi
done < <(enumerate)

echo
echo "=========================================================="
echo "  ci-dispatch [$TRIGGER]: $passed passed, $((total - passed)) failed (of $total)"
if [ "$overall" -ne 0 ]; then
  echo
  echo "Failed checks:"
  for n in ${failed_names[@]+"${failed_names[@]}"}; do echo "  - $n"; done
fi
exit "$overall"
