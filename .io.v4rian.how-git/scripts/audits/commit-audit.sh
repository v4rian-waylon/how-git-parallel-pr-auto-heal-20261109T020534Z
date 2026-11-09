#!/usr/bin/env bash
# commit-audit.sh — push-trigger audit that runs the git-commit-audit
# lens against every commit landed by the current push.
#
# The lens lives at .io.v4rian.how-git/skills/git-commit-audit/SKILL.md
# and covers atomicity, title format, body shape, bullet style,
# fabrication detection, file hygiene, branching, and merge format.
# In the real (non-test) path, semantic judgment runs through
# claude_judge_commit_range (see scripts/_lib.sh) which invokes
# `claude -p` EXACTLY ONCE for the WHOLE push range — one process for
# N commits, not one per commit — with the SKILL.md body as the system
# context and the full per-commit triple for every SHA, then parses one
# AUDIT_PASS / AUDIT_FAIL verdict line per commit from the reply. The
# per-commit judgment is preserved verbatim (same lens, same per-commit
# verdicts); only the process count drops from N to 1. This adds the
# judgment layer that catches tag fit (e.g. [NEW] vs [REFACTOR]
# boundary), fabrication of method or symbol names in bullets, non
# atomic mixing, and body-versus-diff contradiction, failures the
# deterministic structural lens by itself cannot detect.
#
# Under LIFECYCLE_TEST_MODE the helper short-circuits to a canned
# outcome so the offline lifecycle suite exercises the wiring
# without a network round trip or API spend. When the `claude` CLI
# is unavailable, or when neither CLAUDE_CODE_OAUTH_TOKEN (preferred,
# Max-plan OAuth) nor ANTHROPIC_API_KEY (direct API key) is set, the
# helper emits a visible WARN banner on stderr and returns 0 so a
# missing credential never red-checks a push; the structural lens
# that runs alongside this audit stays the hard gate.
#
# Push-range resolution order:
#
#   1. GITHUB_EVENT_BEFORE + GITHUB_EVENT_AFTER (set by the workflow
#      from github.event.before / github.event.after). When BEFORE
#      is the zero-SHA (a brand-new branch push), the range falls
#      back to merge-base with origin/dev.
#   2. When the env pair is absent (local invocation, dry-run), the
#      range walks every commit reachable from HEAD that is NOT
#      reachable from origin/dev. This is the "branch's own commits"
#      definition the auto-rebase ladder already uses.
#
# Exit code propagation:
#
#   0 — every commit in range passed the lens (or the range is
#       empty, e.g. a push that only moves an existing tip with no
#       new commits).
#   1 — at least one commit failed the lens. The script prints the
#       offending commit SHAs and the lens-reported reason to stderr
#       so the CI log surfaces the specific failures.
#   2 — usage / environment error (missing git repo, missing skill).
#
# Env knobs:
#
#   LIFECYCLE_TEST_MODE=1   bypass real claude for the per-commit lens
#                           pass; the deterministic em-dash gate runs
#                           regardless of this knob because it costs
#                           nothing and is the only defence-in-depth
#                           against a missed or bypassed pre-commit
#                           scrub.
#   COMMIT_AUDIT_DRY_RUN=1  print the planned per-commit invocations
#                           but do not call claude; useful for local
#                           preview without spending API budget.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "X commit-audit: not inside a git repository" >&2
  exit 2
fi



# Source the shared helper library so the worker can call
# claude_judge_commit. The library lives one directory up from this
# script; resolving it from the script's own path (the convention across
# scripts/) keeps it stable under any invocation cwd and never loads an
# older vendored copy from the repo being audited.
LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"
if [ ! -f "$LIB_PATH" ]; then
  echo "X commit-audit: shared library missing at $LIB_PATH" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$LIB_PATH"

# Lens resolution honors the user-space override tree (resolve_skill).
SKILL_PATH=$(resolve_skill git-commit-audit)
if [ ! -f "$SKILL_PATH" ]; then
  echo "X commit-audit: git-commit-audit skill missing at $SKILL_PATH" >&2
  exit 2
fi

ZERO_SHA="0000000000000000000000000000000000000000"

resolve_range() {
  local before="${GITHUB_EVENT_BEFORE:-}"
  local after="${GITHUB_EVENT_AFTER:-}"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$ZERO_SHA" ]; then
    git -C "$REPO_ROOT" rev-list --reverse --no-merges "${before}..${after}" 2>/dev/null
    return
  fi
  # Fallback: branch's own commits relative to the closest sensible
  # base. The preferred order is origin/dev > dev > origin/main > main
  # so that under normal operation the gate sees only the developer's
  # own pool-branch commits, and under the lifecycle test scaffold
  # (which sets up `main` and pushes to a bare origin without dev) the
  # gate still resolves to a meaningful range rather than auditing the
  # template-import bootstrap commit, which carries every pre-existing
  # em-dash in the README and workflow files. When even main is
  # absent the repo is in its bootstrap state and the range is empty.
  local base_ref=""
  for cand in "origin/dev" "dev" "origin/main" "main"; do
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
      base_ref="$cand"
      break
    fi
  done
  if [ -z "$base_ref" ]; then
    return
  fi
  # If HEAD is identical to the base (we ARE on the base ref, or have
  # not yet diverged), the range is empty; rev-list returns nothing.
  git -C "$REPO_ROOT" rev-list --reverse --no-merges "${base_ref}..HEAD" 2>/dev/null
}

audit_commit_canned() {
  local sha="$1"
  local subj
  subj=$(git -C "$REPO_ROOT" log -1 --format='%s' "$sha")
  echo "→ commit-audit [canned] $sha $subj"
  return 0
}

# Real per-commit audit. Retained for callers / tests that exercise a
# single commit; delegates to the shared claude_judge_commit helper in
# _lib.sh. The batched real path below uses audit_commit_range instead so
# the whole push range costs ONE claude invocation.
audit_commit_real() {
  local sha="$1"
  claude_judge_commit "$sha" "$SKILL_PATH"
}

# Real batched audit. Delegates the WHOLE push range to the shared
# claude_judge_commit_range helper in _lib.sh, which spins up `claude -p`
# EXACTLY ONCE for all commits — one process for N commits, not one per
# commit — and parses one AUDIT_PASS / AUDIT_FAIL verdict per commit. The
# helper handles the credential-missing fallback, the test-mode
# short-circuit, the dry-run preview, and the per-sha parse; the worker
# only forwards the newline-separated SHAs + lens path and propagates the
# rc. The per-commit judgment is preserved verbatim; only the invocation
# count drops from N to 1.
audit_commit_range() {
  local shas="$1"
  claude_judge_commit_range "$shas" "$SKILL_PATH"
}

# Files that legitimately carry em-dash or en-dash bytes as data
# (replacement-argument literals in the scrub library, gate-pattern
# literals in this very worker, em-dash fixtures in the lifecycle
# tests). The list mirrors the pre-commit hook's `_skip_path` allowlist
# so the local scrub and the push-gate agree on which files are opted
# out of the em-dash ban.
_em_dash_skip_path() {
  case "$1" in
    .io.v4rian.how-git/scripts/lib/auto-fix-commit-message.sh) return 0 ;;
    .io.v4rian.how-git/githooks/pre-commit) return 0 ;;
    .io.v4rian.how-git/test/test-hooks.sh) return 0 ;;
    .io.v4rian.how-git/test/test-lifecycle.sh) return 0 ;;
    .io.v4rian.how-git/framework-tests/test-hooks.sh) return 0 ;;
    .io.v4rian.how-git/framework-tests/test-lifecycle.sh) return 0 ;;
    .io.v4rian.how-git/scripts/audits/commit-audit.sh) return 0 ;;
  esac
  return 1
}

# Defence-in-depth em-dash gate. The pre-commit hook scrubs em-dashes
# (U+2014) and en-dashes (U+2013) from staged files before the commit
# lands; this gate catches the case where the hook was bypassed (e.g.
# `git commit --no-verify`, a broken hook, or a commit landed via the
# GitHub web UI) and the offending bytes slipped into the push range.
#
# The gate walks every SHA in the resolved range, runs
# `git show --no-color --no-renames` to inspect the unified diff,
# tracks the current file via `+++ b/<path>` headers, and inspects
# every added line (`^+`, but not the `+++` header) for the U+2014 or
# U+2013 byte sequences. Hits accumulate a failure count and report
# the offending SHA, file, and line; an empty range or a range that
# only touches opt-out files returns success. Implemented in pure
# bash/grep so it adds no runtime dependency beyond what the surrounding
# script already requires.
scan_em_dashes_in_range() {
  local hits=0
  local sha file diff_line
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    file=""
    fenced=""
    new_line=0
    # `git show -U0` prints the unified diff with no context; we parse one
    # line at a time so the gate works on bash 3.2 (macOS default) where
    # mapfile and readarray are not portable. Hunk headers give the new
    # line number of each added line, so a markdown line inside a fenced
    # code block (hg_dash_fenced_lines) is skipped like the scrub skips it.
    while IFS= read -r diff_line; do
      case "$diff_line" in
        "+++ b/"*)
          file="${diff_line#+++ b/}"
          fenced=""
          case "$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')" in
            *.md|*.markdown|*.mdx)
              fenced=" $(git -C "$REPO_ROOT" show "$sha:$file" 2>/dev/null | hg_dash_fenced_lines - | tr '\n' ' ') "
              ;;
          esac
          continue
          ;;
        "+++ /dev/null"|"+++ "*)
          file=""
          continue
          ;;
        "@@ "*)
          new_line=$(printf '%s' "$diff_line" | sed -E 's/^@@ -[0-9,]+ \+([0-9]+).*/\1/')
          new_line=$((new_line - 1))
          continue
          ;;
        +*)
          case "$diff_line" in +++*) ;; *) new_line=$((new_line + 1)) ;; esac
          ;;
      esac
      # Only inspect added lines (`+<content>`), not metadata (`+++`).
      case "$diff_line" in
        +++*|"") continue ;;
        +*) : ;;
        *) continue ;;
      esac
      [ -n "$file" ] || continue
      if _em_dash_skip_path "$file"; then
        continue
      fi
      # Same file-type rule as the pre-commit scrub (hg_dash_rule_applies
      # in _lib.sh): the dash ban covers prose; code and data keep bytes.
      if ! hg_dash_rule_applies "$file" "$REPO_ROOT"; then
        continue
      fi
      case "$fenced" in *" $new_line "*) continue ;; esac
      # Fast byte-level check; LC_ALL=C keeps grep in single-byte mode
      # so the UTF-8 envelope of U+2014 / U+2013 is matched literally.
      if printf '%s' "$diff_line" | LC_ALL=C grep -q -e $'\xe2\x80\x94' -e $'\xe2\x80\x93'; then
        hits=$((hits + 1))
        echo "X commit-audit [em-dash] $sha $file" >&2
        printf '    %s\n' "$diff_line" >&2
      fi
    done < <(git -C "$REPO_ROOT" show -U0 --no-color --no-renames "$sha" 2>/dev/null)
  done <<< "$1"
  return "$hits"
}

# Portable replacement for `mapfile` (bash 4+) so the script runs
# under macOS bash 3.2 in addition to CI's bash 5+.
SHAS=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  SHAS="${SHAS}${line}
"
done < <(resolve_range)

if [ -z "$SHAS" ]; then
  echo "→ commit-audit: empty push range; nothing to audit"
  exit 0
fi

COUNT=$(printf '%s' "$SHAS" | grep -c .)
echo "→ commit-audit: auditing $COUNT commit(s) via git-commit-audit lens"

# Deterministic em-dash gate runs first so a missed local scrub fails
# the audit even under LIFECYCLE_TEST_MODE where the lens pass is canned.
# Continue past hits so the operator sees both em-dash failures and any
# downstream lens failures in a single run.
EM_DASH_HITS=0
scan_em_dashes_in_range "$SHAS" || EM_DASH_HITS=$?
if [ "$EM_DASH_HITS" -gt 0 ]; then
  echo "X commit-audit: $EM_DASH_HITS em-dash / en-dash addition(s) in push range" >&2
fi

# Deterministic message gate: the same rules commit-msg and pre-push apply
# (hg_message_violations in _lib.sh), so a --no-verify or web-UI commit in
# the push range still meets them. Runs regardless of LIFECYCLE_TEST_MODE.
MSG_HITS=0
MSG_TMP=$(mktemp -t commit-audit-msg.XXXXXX)
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  git -C "$REPO_ROOT" log -1 --format=%B "$sha" > "$MSG_TMP"
  if ! v=$(hg_message_violations "$MSG_TMP"); then
    MSG_HITS=$((MSG_HITS + 1))
    echo "X commit-audit [message] $sha $(git -C "$REPO_ROOT" log -1 --format=%s "$sha")" >&2
    printf '%s\n' "$v" | sed 's/^/    /' >&2
  fi
done <<< "$SHAS"
rm -f "$MSG_TMP"
if [ "$MSG_HITS" -gt 0 ]; then
  echo "X commit-audit: $MSG_HITS commit message(s) in push range break the message rules" >&2
fi

FAILED=0
if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
  # Test-mode keeps the canned PER-COMMIT loop so the offline lifecycle
  # suite exercises the range resolution + per-commit banner wiring
  # without a network round trip or API spend.
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    audit_commit_canned "$sha" || FAILED=$((FAILED + 1))
  done <<< "$SHAS"
else
  # Real path: ONE claude invocation for the WHOLE range via
  # audit_commit_range -> claude_judge_commit_range. FAILED is set from
  # the single call's rc (non-zero if any commit's verdict was AUDIT_FAIL).
  if ! audit_commit_range "$SHAS"; then
    FAILED=1
  fi
fi

if [ "$EM_DASH_HITS" -gt 0 ] || [ "$MSG_HITS" -gt 0 ] || [ "$FAILED" -gt 0 ]; then
  if [ "$FAILED" -gt 0 ]; then
    if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
      echo "X commit-audit: $FAILED of $COUNT commit(s) failed the lens" >&2
    else
      # Real path runs ONE range invocation; per-commit FAIL lines are
      # already printed by claude_judge_commit_range, so report at the
      # range level rather than a misleading "1 of N" count.
      echo "X commit-audit: one or more of $COUNT commit(s) failed the lens (see per-commit FAIL lines above)" >&2
    fi
  fi
  exit 1
fi

echo "✓ commit-audit: every commit in range passed the lens and the em-dash gate (messages: rules clean)"
exit 0
