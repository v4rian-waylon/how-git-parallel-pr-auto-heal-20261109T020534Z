#!/usr/bin/env bash
# required.offline-test-suites.sh - usr-layer wrapper for consumer repos. The canonical recipe
# ships in the namespace tree (the sys layer), which the dispatcher
# skips when the FRAMEWORK_REPO marker is absent; without this wrapper a
# consumer never reports the required status the branch rules demand.
# On the framework source repo the sys layer runs the canonical script
# itself and the matrix builder dedupes same-named checks in favour of
# sys, so this wrapper stays inert there; the marker guard below is the
# belt-and-suspenders second line.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
if [ -f "$ROOT/.io.v4rian.how-git/FRAMEWORK_REPO" ]; then
  echo "=> usr wrapper inert on the framework source (sys layer owns required.offline-test-suites)"
  exit 0
fi
exec bash "$ROOT/.io.v4rian.how-git/ci/tests/push/required.offline-test-suites.sh" "$@"
