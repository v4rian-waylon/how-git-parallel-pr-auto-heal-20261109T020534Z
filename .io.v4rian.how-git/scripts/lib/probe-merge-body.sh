#!/usr/bin/env bash
# probe-merge-body.sh - print the ruled merge body (git-merge-audit rule 5)
# that the operator-run e2e scripts give their probe merges, so the
# commit-msg, pre-push and claim merge message gates accept them.
#
# Usage: probe-merge-body.sh [<probe name>]
name="${1:-probe}"
printf '%s\n' "Lands the ${name} change for the end to end run." '' \
  '- Probe.' "    - ${name}: adds one probe file to exercise the merge and claim path."
