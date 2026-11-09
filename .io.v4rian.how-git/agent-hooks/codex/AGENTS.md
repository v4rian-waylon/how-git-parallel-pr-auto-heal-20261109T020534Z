## how-git protocol guards (installed by bin/install-agent-hooks)

- Before any destructive git command (reset --hard, checkout -f, clean -f, branch -D, rebase,
  filter-branch, stash drop/clear, reflog expire, gc --prune, update-ref -d, force push) run
  `@HOOK_DIR@/git-preflight.sh <repo> "<reason>"`, or chain it with `&&` in the same
  command. The PreToolUse hook denies the command otherwise.
- Never push to main, never `git push --force` (use `--force-with-lease` after a preflight),
  never delete a remote repo, never `git add -A` or `git add .` (stage files by name).
- Delete files by moving them to the Trash; `rm` is allowed only under a temp root.
- Never print credential files (.env, .auth/, keys/, *.p8, *.p12, *.pem) into the session.
- Never edit a vendored `.io.v4rian.how-git/` copy; change the framework repo and run
  `.io.v4rian.how-git/bin/sync-framework <ref>`.
- A deny reason names the fix: run it, then retry the exact command.
