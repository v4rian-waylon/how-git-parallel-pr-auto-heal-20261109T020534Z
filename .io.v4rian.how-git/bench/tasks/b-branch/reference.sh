#!/usr/bin/env bash
set -euo pipefail
export GIT_AUTHOR_NAME="v4rian-waylon (Opus)" GIT_COMMITTER_NAME="v4rian-waylon (Opus)"
export GIT_AUTHOR_EMAIL=v4rian-waylon@users.noreply.github.com GIT_COMMITTER_EMAIL=v4rian-waylon@users.noreply.github.com
bash .io.v4rian.how-git/bin/create-pool-branch greet --no-jira --kind feature --requirement "Add a greet command." >/dev/null 2>&1
P=$(git for-each-ref --format='%(refname:short)' refs/heads/pool/ | grep '\.greet$')
git checkout -q "$P" 2>/dev/null
mkdir -p src tests
printf '#!/bin/sh\n# Greets the given name.\necho "Hello, ${1:-world}!"\n' > src/greet.sh
git add src/greet.sh
git commit -q -m "[NEW] Add the greet command" -m "Adds a shell command that greets its first argument, or the world when none is given."
printf '#!/bin/sh\nset -e\n[ "$(sh src/greet.sh)" = "Hello, world!" ]\n[ "$(sh src/greet.sh Ada)" = "Hello, Ada!" ]\necho ok\n' > tests/greet_test.sh
bash tests/greet_test.sh >/dev/null
git add tests/greet_test.sh
git commit -q -m "[TEST] Cover the greet command" -m "Asserts the default greeting and a named greeting, exiting non-zero on any mismatch."
printf '\n## Usage\n\n`bash src/greet.sh <name>` prints a greeting for the name.\n' >> README.md
git add README.md
git commit -q -m "[DOCS] Document greet usage in the README" -m "Adds a usage section that shows how to run the greet command."
S="safety/${P#pool/}"
git push -q origin "$P:refs/heads/$P" "$S:refs/heads/$S"
