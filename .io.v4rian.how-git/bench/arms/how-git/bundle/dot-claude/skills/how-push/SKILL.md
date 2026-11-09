---
name: how-push
description: Only in a maintenance-mode repo where Joel asked for remote CI, run every gate locally before pushing, watch the runs the push fires and report red first. Elsewhere done means local suites, builds and runtime pass; never propose CI.
---

# how-push

**Default (prototyping, building from the ground up, every current repo):** remote CI is not part of the definition of done. Done = the local gates pass (unit suite, e2e, build, runtime boot per the repo's own macros). Do not wait on, monitor, or propose remote CI.

**Maintenance-mode repos where Joel asked for CI:**

1. Before `git push` or `gh pr create`, run locally every check the workflows run (`required.*.sh`, audits, suites), including model-judged audits. Token cost is not an excuse.
2. After the push, watch every run the SHA triggered: `gh run list --commit <sha>`, then `gh run watch <id>` in a background Bash and let the harness notify you. No sleep-polling loops.
3. On red: `gh run view <id> --log-failed`, fix, repeat. Report the outcome (green or red, with the run URL) as the closing line of the push.

Never let Joel find a red check first.
