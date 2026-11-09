# neo-git development history (2026-10)

Records of the neo-git fork of how-git, 2026-10-29 to 2026-10-30, copied from the out-of-repo work folder. They are historical: written as they were at the time, with only absolute workspace paths shortened to `<workspace>`, two console support codes redacted from the Jev evaluation, and dashes normalised by the pre-commit scrub. Paths such as `bench-results/` or `resolutions/` inside them point at that work folder and are not part of this repo.

## Files

- `DECISIONS.md`: Joel's fork, scope and merge-grant decisions of 2026-10-29.
- `ROADMAP.md`: the pool-by-pool plan that turned the decisions into branches.
- `STATE.md`: final state at v2026.0.169, final suite counts, open items.
- `MERGE-NOTES.md`: conflict resolutions at landing, the pool id incident and the run 2 resolutions.
- `how-git-requests-ledger.md`: every how-git bug report and feature request read from local repos, with status.
- `friction-ledger.md`: friction points mined from Claude sessions, ranked, with fixes and what stayed open.
- `jev-evaluation.md`: evaluation of Jev and open-source alternatives for speed and token cost.
- `audit-n165.md`, `audit-n165-r2.md`: audits of the allocator clone-ref fix branch.
- `audit-pending-branches.md`: audit of the unmerged September work (allocator and reconstruct).
- `audit-self-compliance.md`: audit of neo-git against its own spec at each point in time, with remedies.
- `audit-claim-data-safety.md`, `audit-claim-data-safety-r2.md`: audits of claim and data-loss handling.
- `audit-hook-correctness.md`, `-r2.md`, `-r3.md`: audits of the githooks and shared library.
- `audit-ghost-tools.md`, `audit-ghost-tools-r2.md`: audits of the ghost-tool and workflow branch.
- `audit-docs-lanes.md`, `audit-docs-lanes-r2.md`: audits of the spec-contradiction, lean-skills and lazy-loader docs lanes.
- `audit-reconstruct.md`, `-r2.md`, `-r3.md`: audits of the reconstruct tool.
- `how-git-vs-neo-git.md`: agent-runner benchmark result, how-git vs neo-git.
- `loadbytes.md`: deterministic protocol load per task type, both arms.
- `baseline-summary.md`: the headless baseline of how-git 5028b58 (36 runs).
- `agent-runs-opus.jsonl`, `agent-runs-fable.jsonl`: raw rows of the agent-runner benchmark per model.
- `how-git-token-audit-2026-10-29.pdf`: the source token audit that `DECISIONS.md` selects its scope from.

## Timeline

- 2026-10-29: fork of how-git dev 5028b58 (v2026.0.136) after the token audit; ledgers and Fable audits of the pending September n165 branch and reconstruct work.
- 2026-10-29: pools landed on dev from n165 to n188 (v2026.0.137 to .160): allocator clone refs, ghost tools, benchmark harness, claim data safety, hook correctness, reconstruct, contradiction fixes, lean skills, lazy loader, identity, self-documenting tools, consistency lint. Audit rounds r2 and r3 ran against these lanes.
- 2026-10-29: pool id incident, n1001 to n1007 renumbered to n167 to n173 with a preflight ref and bak zip.
- 2026-10-30 12:15: n191 and n192 renamed n190 and n191 after an allocation out of order (RUNBOOK "Renumber of n191 and n192").
- 2026-10-30 16:33: n166 to n197 renamed n165 to n196 so ids are contiguous (RUNBOOK "Renumber of n166 to n197").
- 2026-10-30 to 31: self-compliance audit and its remedies, pools n198 to n204; stale backups purged on Joel's instruction (`DECISIONS.md`).
- 2026-10-30: n189 to n197 (v2026.0.161 to .169): identity gate, merge policy and warp mode, merge body in the hook, restore exclusion, bench agent runner, benchmark-found bug fixes, friction fixes, rewrite-check patches.
- 2026-10-30: agent-runner benchmark: Fable -33% tokens, Opus -13%, mandated protocol load -91%, 0 data-loss failures against 1 for how-git.
