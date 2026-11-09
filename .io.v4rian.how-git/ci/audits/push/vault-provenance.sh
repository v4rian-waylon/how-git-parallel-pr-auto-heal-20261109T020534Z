#!/usr/bin/env bash
# vault-provenance.sh - provenance flag for the carve out refs.
#
# vault/* creation and pool/*.reconcile.* creation are intentionally open
# so the CI claim performs them with its plain workflow token; both ref
# classes are frozen on touch, so an unexpected creator cannot mutate
# anything - but their existence should never pass silently. This audit
# runs on the push trigger: when the pushed ref is a vault or reconcile
# ref and the pushing actor is not github-actions[bot], it fails the
# check and names the actor, making dev created noise refs visible the
# moment they appear. Pushes by the CI identity pass quietly.
set -uo pipefail

REF="${GITHUB_REF:-}"
ACTOR="${GITHUB_ACTOR:-}"

case "$REF" in
  refs/heads/vault/*|refs/heads/pool/*.reconcile.*|refs/heads/pool/*/*.reconcile.*) ;;
  *)
    echo "=> vault-provenance: ref ${REF:-<none>} is not a carve out ref; nothing to flag"
    exit 0
    ;;
esac

if [ "$ACTOR" = "github-actions[bot]" ] || [ "$ACTOR" = "github-actions" ]; then
  echo "=> vault-provenance: $REF pushed by the CI identity; expected provenance"
  exit 0
fi

echo "X vault-provenance: $REF was pushed by '$ACTOR', not the CI identity." >&2
echo "  Carve out refs (vault/*, pool/*.reconcile.*) are created by the claim flow;" >&2
echo "  a human created ref here is noise at best and impersonation at worst." >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## :rotating_light: unexpected creator on a carve out ref"
    echo "\`$REF\` was pushed by \`$ACTOR\` instead of the CI identity. The ref is frozen (update and deletion locked) but should be reviewed and swept."
  } >> "$GITHUB_STEP_SUMMARY"
fi
exit 1
