# bench loadbytes: bytes an agent is told to read, per task

Old arm: `~/.claude/skills/how-git/SKILL.md` + everything its On invoke mandates at `5028b58` (233184 B: loader, 3 memories, 13 git-* skills, Git_Strategy.md, RUNBOOK.md) + the row's how-* skills and memories. New arm: in-repo lean loader at `6095490` (6469 B) + the row's skills + `--help` of the row's tools. Zero model; rerun gives the same table.

| Task | Old B | New loader+skills B | New tool help B | New total B | Saved |
|---|---:|---:|---:|---:|---:|
| Compose a commit | 233184 | 14443 | 4487 | 18930 | 92% |
| Create a working branch | 233184 | 17201 | 2118 | 19319 | 92% |
| Merge a pool into dev | 233184 | 17520 | 5043 | 22563 | 90% |
| Release dev to main | 233184 | 30364 | 1465 | 31829 | 86% |
| Rewrite my own history | 237254 | 22043 | 0 | 22043 | 91% |
| Rebuild from bak zips | 234012 | 24174 | 0 | 24174 | 90% |
| Rebuild from working-tree folders | 234012 | 19341 | 5501 | 24842 | 89% |
| Replay or rebase across diverged history | 233184 | 14200 | 0 | 14200 | 94% |
| Verify compile, coverage or runtime | 233184 | 12271 | 2871 | 15142 | 94% |
| After a push | 233184 | 12609 | 2871 | 15480 | 93% |
| GitHub API call needing credentials | 234327 | 11477 | 0 | 11477 | 95% |
| Bootstrap a new repo | 252063 | 25175 | 2087 | 27262 | 89% |
| Adopt or migrate the framework | 233184 | 6469 | 5632 | 12101 | 95% |
| **All 13 tasks** | 3057140 | | | 259362 | 92% |
