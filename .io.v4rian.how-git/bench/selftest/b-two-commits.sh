# task: b-branch
# expect-fail: three-commits pushed greet-test-passes
# Hand-made pool name, everything in two commits, broken test, no push.
export GIT_AUTHOR_NAME="v4rian-waylon (Opus)" GIT_COMMITTER_NAME="v4rian-waylon (Opus)"
export GIT_AUTHOR_EMAIL=v4rian-waylon@users.noreply.github.com GIT_COMMITTER_EMAIL=v4rian-waylon@users.noreply.github.com
git checkout -q -b pool/v2026.0/n1.feature.greet 2>/dev/null; git branch safety/v2026.0/n1.feature.greet dev
mkdir -p src tests
printf 'echo "Hello, ${1:-world}!"\n' > src/greet.sh
printf 'exit 1\n' > tests/greet_test.sh
git add src tests; git commit -q -m "[NEW] Add greet and its test" -m "Adds the greet command and a test."
printf '\n## Usage\n\nbash src/greet.sh <name>\n' >> README.md
git add README.md; git commit -q -m "[DOCS] Document greet" -m "Adds usage."
