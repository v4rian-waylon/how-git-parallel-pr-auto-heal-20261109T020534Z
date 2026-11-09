#!/usr/bin/env bash
# required.commit-audit.sh - push gate: every pushed commit passes the
# git-commit-audit lens.
#
# Usage:
#   .io.v4rian.how-git/ci/audits/push/required.commit-audit.sh   run the gate
#   .io.v4rian.how-git/ci/audits/push/required.commit-audit.sh -h|--help
# No arguments; run from inside the repo.
#
# How it runs:
#   ci-dispatch.yml runs every ci/audits/push/required.*.sh on each pushed
#   head SHA; the check posts under the file's basename minus .sh. The
#   required. prefix makes bin/bootstrap-ci bind it as a required status
#   check on PRs into dev. PRs reuse the push result for the head SHA; the
#   pr-open event does not rerun it. In off-grid mode bin/ci-local runs the
#   same scripts locally.
#
# Retry: delegates to scripts/workflows/audit-retry.sh --audit commit-audit, which
# retries only transient failures (exit 64, or a "RETRYABLE: <reason>" line on
# stderr) with 5 s doubling backoff capped at 300 s, MAX_ATTEMPTS (default 8).
# Any other non-zero exit fails fast on the first attempt.
#
# What it checks (scripts/audits/commit-audit.sh):
#   Range: GITHUB_EVENT_BEFORE..GITHUB_EVENT_AFTER when set (a zero BEFORE
#   falls back to the merge-base with origin/dev); otherwise every commit on
#   HEAD not on origin/dev.
#   Deterministic layer (hard gate, always runs): no em or en dash added.
#   Judgment layer: one claude -p call for the whole range with
#   skills/git-commit-audit/SKILL.md as context, one verdict per commit (tag
#   fit, atomicity, fabricated symbols, body versus diff). Without the
#   claude CLI or a credential (CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY)
#   it prints a WARN and does not fail: a missing credential never reds a push.
# Env: LIFECYCLE_TEST_MODE=1 skips the claude call; COMMIT_AUDIT_DRY_RUN=1
# prints the planned calls without running claude.
#
# Exit codes:
#   0  every commit passed (or the range is empty)
#   1  at least one commit failed; SHAs and reasons on stderr
#   2  usage or environment error (not a repo, skill missing)
#   64 transient failure after every retry

set -uo pipefail

case "${1:-}" in
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
esac
exec bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/workflows/audit-retry.sh" --audit commit-audit
