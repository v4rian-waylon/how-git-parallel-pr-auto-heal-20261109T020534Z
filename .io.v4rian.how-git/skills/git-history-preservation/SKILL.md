---
name: git-history-preservation
description: User-authored commits are READ-ONLY. Never amend, retag, rebase, filter-branch, or rewrite the user's pre-existing chain - even with identical tree content, the SHA changes and that counts as touching. Only rewrite commits YOU produced in the current session(s). Project-agnostic - identifies user-vs-mine commits via heuristics (tag style, date boundary, reflog comparison). Invoke before any history rewrite operation; consult before any force-push.
---

# git-history-preservation - user-authored commits are read-only

The user's pre-existing commit chain is sacrosanct. Even rewrites that preserve tree content change the SHA and break references; the user does not consent to that.

## The rule

**Never amend, retag, rebase, filter-branch, or otherwise rewrite a commit the user authored**, unless they have explicitly named that specific commit and authorized the rewrite.

Identical tree + identical author/date + new SHA = still a rewrite. Still forbidden.

## How to identify user-authored commits (project-agnostic heuristics)

The boundary between "user's commits" and "my rebuild commits" varies per workspace. Use heuristics in order; never assume a fixed cutoff.

### Heuristic 1 - Title style

User-authored commits typically use **natural prose titles** without a `[TAG]` prefix:

- User: `Implement callback forwarding to bot for offer responses`
- Mine (rebuild): `[REFACTOR] BookingService routes callbacks through ...`

If the title starts with `[NEW]`, `[REFACTOR]`, `[DOCS]`, `[TEST]`, `[FIX]`, `[HOTFIX]`, `[MERGE]`, `[REVERT]`, `[REQ]`, `[MODE]`, that's a tag the audit lens would have produced - it's mine.

### Heuristic 2 - Date boundary

Find the date when the rebuild work began:

```bash
# Earliest commit dated within the rebuild session
git log --reverse --format='%ai %h %s' | head -5
# Or look at reflog timestamps
git reflog --date=iso --format='%gd %h %gs' | head -20
```

Commits dated BEFORE the rebuild's start are user's; commits dated DURING the rebuild's window are likely mine. The boundary is per-workspace; ask the user if unclear ("when did the rebuild work start?").

### Heuristic 3 - Author timezone

If the user works in one timezone (e.g., `-0800` PST) and rebuild agents authored in UTC (`+0000`), the timezone shift signals authorship. Not definitive on its own.

### Heuristic 4 - Reflog comparison

The local `git reflog --all` carries the actual user SHAs from before any rewrite, until GC. Compare a current commit's SHA against reflog entries with the same message:

```bash
TITLE="Implement callback forwarding to bot for offer responses"
git reflog --all --format='%h %ai %gs' | grep -F "$TITLE"
```

If the current commit's SHA differs from the reflog entry's SHA but the message is identical, the current is a rewrite - the user's original SHA in reflog is canonical.

### When in doubt

Treat the commit as user's and do not touch.

## Permitted operations on user-authored commits

- **Read**: `git show`, `git log`, `git diff`.
- **Reference**: branch off the user's commit (cut a new feature branch from their tip).
- **Merge into**: merge a new feature branch into a tip that includes their commits (does not rewrite their commits; appends new history).

## Forbidden operations on user-authored commits

- `git commit --amend` while their commit is HEAD.
- `git rebase` that includes their commit in the rewrite range.
- `git filter-branch --msg-filter` or `--commit-filter` that touches their commits.
- `git commit-tree` reconstructing their commit with a new SHA, even with identical message + tree.
- `git push --force[-with-lease]` overwriting a ref that points to their commit.

## Recovery when my rebuild accidentally rewrote user commits

If you discover a rewrite range touched user commits:

1. **Stop.** Do not push more rewrites.
2. Find the user's original SHAs via reflog and message search.
3. Verify trees match: `git cat-file -p <user-sha>^{tree}` vs `git cat-file -p <my-sha>^{tree}`.
4. Branch the user's original SHAs to safety refs locally (`git branch user-original-<topic> <sha>`).
5. Show the user the diff between rewrite and original; let them decide whether to restore.
6. If authorized: `git push --force origin <user-sha>:refs/heads/main`.

## What about my own commits?

My commits - those authored during the current rebuild session - are fair game for rewriting per `git-history-rewrite`. The distinction is who authored the content, not whose name is on the author line: agents commit as the origin org's account (Git_Strategy "Commit identity follows the origin's org") and only rebuilds of the user's own snapshots carry the user's name, so the author line alone does not decide.

The heuristic combination: title carries my tag prefix AND date is in the rebuild window → mine. Otherwise → user's.

## Pre-rewrite checklist

Before running `git filter-branch`, `git rebase`, `git commit --amend`, or `git push --force[-with-lease]`:

1. List every commit in the rewrite range: `git rev-list <range>`.
2. For each commit: title style, date, reflog presence - does it look user-authored?
3. If ANY commit in the range looks user-authored: stop. Either narrow the range or do not rewrite.
4. If all commits in the range are mine: proceed per `git-history-rewrite`.

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) - orchestrator; consults this skill before any rewrite.
- [`git-history-rewrite`](../git-history-rewrite/SKILL.md) - date-preserving mechanics for MY commits only.
- [`git-commit-audit`](../git-commit-audit/SKILL.md) - same lens applies to MY commits but never to the user's.
