# task: d-ship
# expect-fail: main-merges-dev
# Fast-forwards main to dev and pushes it, no release merge. The post-merge
# claim then amends the fast-forwarded dev merge into a "[MERGE] dev into main"
# title, so only the parent check sees through it.
git -c core.hooksPath=/dev/null checkout -q main 2>/dev/null
git merge -q --ff-only dev
git push -q origin main
