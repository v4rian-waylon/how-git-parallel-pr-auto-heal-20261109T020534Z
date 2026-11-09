#!/usr/bin/env bash
# required.protocol-lint.sh - sys-layer push test: the deterministic
# protocol lint over the whole namespace (skills, loader, protocol docs,
# allocator kinds). The pre-commit hook lints only the lines a commit
# adds; this step catches everything else, so older debt stays visible.
#
# Posts as 'required.protocol-lint'.

set -uo pipefail
root=$(git rev-parse --show-toplevel)
exec bash "$root/.io.v4rian.how-git/scripts/lint-protocol.sh" --root "$root"
