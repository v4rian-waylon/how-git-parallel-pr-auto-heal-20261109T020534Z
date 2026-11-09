#!/usr/bin/env bash
# verify-actor-admin.sh — body of the "actor must be admin" gate used by
# the workflow_dispatch entry point on claim-on-merge-dev,
# claim-on-merge-main, and (potentially) other admin-only workflows.
#
# Reads:
#   GH_TOKEN              token with collaborators:read scope
#   ACTOR                 the workflow.actor (github.actor) value
#   GITHUB_REPOSITORY     owner/repo set by the runner
#
# Exits non-zero with a clear message when the actor is not admin.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${ACTOR:?ACTOR is required (set from github.actor)}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required (set by the runner)}"

echo "→ checking admin permission of actor '$ACTOR' on $GITHUB_REPOSITORY"
PERM=$(gh api "repos/${GITHUB_REPOSITORY}/collaborators/${ACTOR}/permission" --jq '.permission' 2>/dev/null || echo "unknown")
echo "→ actor permission = $PERM"

if [ "$PERM" != "admin" ]; then
  echo "✗ refusing: actor '$ACTOR' has permission '$PERM' (admin required)" >&2
  exit 1
fi

echo "✓ admin permission confirmed"
