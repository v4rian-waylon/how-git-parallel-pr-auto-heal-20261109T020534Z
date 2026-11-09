#!/usr/bin/env bash
# harness-smoke.sh - usr-layer push smoke test
#
# Demonstrates a consumer-owned check on the push trigger (every push
# to any pool/safety/feature branch except dev/main/tag which resolve
# to distinct triggers). The basename does NOT start with "required."
# so this check is informational only.

set -euo pipefail

echo "=> harness-smoke (usr/tests/push): dispatcher resolved this script and the runner executed it"
exit 0
