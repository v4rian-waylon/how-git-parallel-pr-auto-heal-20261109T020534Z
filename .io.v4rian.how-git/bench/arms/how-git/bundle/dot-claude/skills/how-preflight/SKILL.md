---
name: how-preflight
description: Run `~/.claude/hooks/git-preflight.sh <repo> "<reason>"` before any destructive repo or working-tree operation the guard hook cannot see (orphan rebuild, restructure, mass overwrite, deleting builds), and follow the verified procedure for an authorised rewrite of published history.
---

# how-preflight

Tool and enforcement per CLAUDE.md rule 12: `~/.claude/hooks/git-preflight.sh <repo-path> "<reason>"` snapshots the full working tree (tracked + untracked, secrets, `build/` and `node_modules/` excluded) into a `preflight-bak-YYYY-MM-DD/NN` ref pushed to origin plus a bak zip in `local_stage/baks/` mirrored to `shuttle.o/baks/`; `guard-destructive.sh` denies destructive git until both exist and are under 12 h old.

**Run it yourself first** when the guard cannot see the risk: orphan rebuilds, mass `mv`/overwrite, restructures replacing many files, deleting built `.app`s (trash them, or copy to the shuttle first). If origin is unreachable the ref stays local-only; say so.

**Never** delete, rewrite or force-push against a `preflight-bak-*` ref. A `git bundle` backs up commits, not your work.

## Rewriting published history (only when authorised)

Published history is rewritten only with Joel's explicit grant for that ref (`git-history-preservation`). When granted:

1. `~/.claude/hooks/git-preflight.sh <repo> "rewrite <branch>"` first; that ref plus zip is the backup, not a `/tmp` bundle and not the reflog. Note the original tip SHA.
2. Read the in-repo lens (`.io.v4rian.how-git/skills/git-commit-audit/SKILL.md`, never memory), reset to the merge-base, replay commit by commit: split where atomicity demands, rewrite bodies where the lens fails, audit each commit before the next. No intermediate pushes.
3. Before pushing: tree equality with the original tip (`git rev-parse <sha>^{tree}`, flag intended drift), every local audit under `.io.v4rian.how-git/ci/audits/`, the full test suite, the coverage delta. Local green is the completion gate; remote CI is not (`how-push` covers the few maintenance repos that have it).
4. `EXPECTED=$(git ls-remote origin refs/heads/<branch> | cut -f1)` taken fresh, then `git push --force-with-lease=refs/heads/<branch>:$EXPECTED origin <branch>`. Never bare `--force`, never bare `--force-with-lease`.
5. `git fetch origin <branch>`, then compare the full chain: `git log --format=%H <base>..HEAD` must equal `<base>..FETCH_HEAD` SHA-for-SHA. Tip equality alone is insufficient.
6. Only after step 5 matches, clear temporary state (scratch worktrees, patch dirs) with `/usr/bin/trash`. The `preflight-bak-*` ref stays.

Cure when this was skipped: `how-rescue`.

## Splitting a published monolith into replayed commits

When one published commit imported a whole tree from another repo (a "cut"), rebuild it from the source repo's own commits instead of hand-splitting: plumbing only (`commit-tree`, a temp `GIT_INDEX_FILE`, `read-tree --prefix`), in a `--shared` scratch clone.
- Per source commit, export the source subtree, apply the same rename/format the cut applied, and commit that state; skip source commits that never touched the subtree; keep the original body under a provenance line, since its receipts were run in the source repo.
- Measure the residual first (renamed final source tree vs the cut tree) and turn each residual concept into its own commit; assert the last replay's tree equals the cut's tree before continuing.
- Later commits keep their trees verbatim, except content that pins rewritten SHAs (pubspec `ref:`, Cargo.lock `#sha`): rewrite those blobs with the old→new map, oldest first. Map abbreviated SHAs in messages too.
- Annotated tags: rebuild with `git mktag`, keeping the original tagger date and message. Push every ref in one `git push` with one explicit `--force-with-lease=<ref>:<old>` per ref, after checking `ls-remote` still shows each old value. Write that script in bash: zsh arrays are 1-indexed.
- Afterwards, repoint local pool/safety branches through the map, and notify consumers that pin the rewritten tags by SHA.
