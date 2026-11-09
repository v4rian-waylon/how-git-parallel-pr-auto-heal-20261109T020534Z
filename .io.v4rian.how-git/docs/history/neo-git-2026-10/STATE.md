# neo-git state (2026-10-30)

dev on v4rian-io/neo-git, off-grid; pools n165 onward contiguous on dev (tags v2026.0.137 onward); main untouched (promotion is Joel's call).

Benchmark (bench-results/how-git-vs-neo-git.md): Fable -33% tokens, Opus -13%; neo-git 0 data-loss failures vs 1 in how-git; mandated protocol load -91%.

Agent hooks ship in-repo (.io.v4rian.how-git/agent-hooks, bin/install-agent-hooks for Claude Code and Codex). Development history lives in .io.v4rian.how-git/docs/history/neo-git-2026-10/.

Self-compliance audit (audit-self-compliance.md): 0 critical, 4 high, 5 medium, 6 low; remedies applied as fix-forward pools (n198 suite abort, n201 records and CHANGELOG) and ref cleanup (stray branches deleted after bundling, stale preflight backups purged, inherited merged pools vaulted, abandoned September n165 pair recorded); no history rewrite recommended. Grants for the two 10-30 rewrites recorded in DECISIONS.md.

Open: a plain `git commit` still needs the identity exported (use bin/smart-commit); connected-mode PR merges only announce who/approval; git-absorb pilot; Codex side untested inside Codex; CI bot identity path untested in a real Actions run; global how-git loader swap and .io.v4rian.neo-git rename wait for promotion.
