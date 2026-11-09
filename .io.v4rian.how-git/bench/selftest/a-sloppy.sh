# task: a-commit
# expect-fail: pushed identity
# Untagged message, ambient identity, hooks skipped, never pushed.
git add src tests
git commit -q --no-verify -m "add sum stuff"
