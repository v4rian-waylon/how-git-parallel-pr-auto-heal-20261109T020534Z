---
name: git-shuttle
description: Rebuild atomic git history from working-tree folders the user drops in the workspace's inbound shuttle (full multi-snapshot rebuild, or code-versioning one folder of uncommitted work). Folders may lack .git, nest many repos, or have no target repo yet. A preamble asks for every path, mapping and grant (identity and dates are derived by rule); content-hash matching finds the parent commit, a cross-repo check skips already integrated files, orphans go to the mainline or an archival branch (never lost), and the diff is atomized per the git-* lenses. Project-agnostic.
---

# git-shuttle - rebuild git history from working-tree folders

Sister of `git-snapshots` (which walks `BAK *.zip` chains): here the source is one or more working-tree folders, usually in the inbound shuttle, possibly without `.git/`, nested, or with no target repo yet (init, clone or path-mapped attach). Two modes share one flow: a **full rebuild** of several dated snapshots, or **code-versioning** one folder of in-flight work into its repo without faking history. The resulting log reads like normal development: no mention of shuttles, snapshots, rebuilds or zips.

## Principles (binding)

1. **Ask for every path, repo mapping and grant; assume none.** The most likely guess has caused data loss before. Identity (Step 3) and timestamps (Step D.7) are derived by rule, not asked.
2. **Every question invites "Other, tell me what I'm missing"** explicitly in its wording; a user's free-form answer is the canonical structure, recorded verbatim under `user_clarifications[]` in `BACKUP.manifest.json`.
3. **The working tree is irreplaceable work.** Default to surfacing findings and asking, not executing.
4. **Lossless.** Every byte of every snapshot ends reachable from at least one branch; nothing is dropped silently.
5. **Integrated vs orphan.** A blob present anywhere in the related repos' `--all` history is integrated (skip it); any other file is an orphan needing an explicit mainline or archival decision.

Halts reach the user through the workspace's own channel (chat question, or a voice call when the workspace provides `voice-ask`); independent work (scanning, matching, backups) continues meanwhile.

## Preamble (once per invocation, in order)

**Step 1 - Scan.** Ask for the scan root (default `<workspace>/shuttle.i/` when non-empty; or the workspace; or a path given earlier). Scan ~4 levels deep and classify each directory: bare repo, working tree with `.git/` (harvest branches, remotes, HEAD), working tree without `.git/` (the common case), expanded zip (note the origin), or container of sibling snapshots (recurse). Show the list (name, file count, size, mtime, git state) and ask: process all, pick a subset, look elsewhere, or Other. A folder that maps to no known repo is asked about: snapshot of which repo, new repo via `git init`, mistaken drop, or Other.

**Step 2 - Target repo per snapshot.** Surface candidates, never auto-pick: name match with a workspace repo, a mapping in the workspace `CLAUDE.md`, the snapshot's own `origin`, a mapping the user stated. Options: each workspace repo (path, branch, HEAD), clone from URL, `git init` a new repo, attach with a path prefix, Other.
- **Init:** the user names the path; the root commit lands on `dev` directly (no empty commit) and `main` fast-forwards to it.
- **Clone:** the URL verbatim from the user, the destination confirmed, the credential account chosen by the user (each `gh auth status` account and matching credential helper entry, or manual; never the host default silently); Step 4's probe runs first (a private clone hangs like a push), then `gh repo clone` or `git clone`, then redo Step 2.
- **Attach:** the user picks the repo and the subfolder the snapshot root maps to (`--path-prefix` for the Step C tools).

**Step 3 - Author identity (derived, not asked).** Rule: `docs/Git_Strategy.md` "Commit identity follows the origin's org". Dropped snapshots are the user's own work, so commits are authored as the user: take the identity from the latest `.ag-git-shuttle/runs/*/BACKUP.manifest.json` `author_identity_override` grant, else from the workspace memory or `CLAUDE.md` naming the rebuild author; work that is not the user's takes the origin org's account. Ask only when no source names the user. Export it as `GIT_AUTHOR_*` and `GIT_COMMITTER_*` per commit; never read or change `git config user.*`.

**Step 4 - Push policy.** Ask: push after every audited git action, or local only. If pushing, probe credentials now and halt until they work: `gh auth status` (non-hanging), `git credential fill` only under a manual timeout, `ssh -T -o ConnectTimeout=5 -o BatchMode=yes git@<host>` for SSH remotes; on a hang or failure surface the exact login command. Credential discovery: `git-token-discovery`.

**Step 5 - dev/main grant.** For a target with `dev` or `main`: merge into them, or keep everything on parallel branches (Step D.5)? Writing existing `dev`/`main` needs the user's verbatim grant; record wording, scope and repos in `BACKUP.manifest.json` `user_grants[]`. No grant means parallel branches only. A freshly initialized repo needs none.

**Step 6 - Confirm.** Summarize snapshot → target (and prefix), identity, push policy and credential status, grant scope, placement strategy (Step D.5), timestamp rule (Step D.7). Wait for an explicit yes; no questions after it except for an irreversible step.

**Step 7 - Call before executing.** The run rewrites at scale, so after the text confirmation also reach the user by voice where the workspace has `voice-ask` (scope, strategy, 2-4 lettered options, "or something else"); a voice answer is binding and a barge-in restarts the confirmation.

## Methodology (per snapshot)

Snapshots targeting the same repo run in chronological order (folder mtime or the user's order), each against the commits the previous one added.

**A - Backup** (`git-snapshot-preflight`): `cp -pR` each snapshot to `<run-dir>/BACKUP/source-snapshots/`; `git clone --mirror` each target to `<run-dir>/BACKUP/target-repos/`; when pushing, push a `preflight-bak-YYYY-MM-DD/NN` branch before any commit and never delete or force it.

**B - Scope** (`git-coverage-audit`): in-scope files are the walk `.io.v4rian.how-git/skills/git-shuttle/tools/_snapshot-scope.sh` performs (no `.git/`, `node_modules/`, `dist/`, `build*/`, lock files, `*.log`, `.DS_Store`, `.session`, `*.bak`, `*_old.qml`); pass the workspace `CLAUDE.md` banned names as `--extra-exclude`. Apply the path prefix. Write `coverage.txt`.

**C - Parent commit.** Run `.io.v4rian.how-git/skills/git-shuttle/tools/content-match.sh <snapshot> <target>` (deterministic; `--help` lists flags). Pick C*:

| Top match | Decision |
|---|---|
| 100% | Already represented; `parent.txt` with `clean=true`, skip D-G. |
| ≥90%, unambiguous | C* is the parent; small diff. |
| <90%, unambiguous | C* is the parent; note the divergence. |
| Ties | Earliest author date among them; note the ambiguity. |
| below ~30% | Likely pre-dates a refactor or split: run C.5 before deciding; halt and ask only if C.5 cannot explain it. |

**C.5 - Cross-repo check.** Run `.io.v4rian.how-git/skills/git-shuttle/tools/integration-check.sh <snapshot> <repo,repo,...>` over the target, sibling repos the user named, lineage the workspace `CLAUDE.md` declares (ask when lineage is unknown). INTEGRATED files (blob already in some repo's history; record where) are skipped; NEW files are orphans. Write `integration.tsv` and `integration-summary.md`.

**D - Diff** C* vs snapshot for the orphans: NEW, MODIFIED, DELETED into `diff.txt`.

**D.5 - Placement**, one strategy per run, from the preamble:
- **P-1 parallel branches (default).** Build `dev_2` from `dev` (or `main`) and `main_2` from `main`; every working branch is cut from and merged `--no-ff` into `dev_2`. The user, never the skill, reviews and promotes `_2` → canonical and deletes the `_2` refs; the skill never force-pushes `dev` or `main`.
- **P-2 direct mainline.** Same, into the existing `dev` then `main`; only with the Step 5 grant and only when the user names it.
- **P-3 archival.** Work that is deliberately dead-ended lands on a pushed `archival/<name>` branch off C* and never merges; only when the user names the files or confirms the judgment.
Write `judgment.md`: strategy, orphans, reasoning per cluster.

**D.6 - Atomize** per `git-strategy-audit` and `git-commit-audit`: same subsystem or import graph → one feature; a new dependency with its users → one "introduce X" feature; docs alone → `[DOCS]`; stray tweaks → `[FIX]` or `[REFACTOR]`; cleanup → `[REFACTOR]`, last. Every cluster, a single commit included, gets its own working branch in the target's model (allocator `pool/nN.kind.name` on v4rian repos; `feature/*` only on legacy-model repos); names describe the feature, never the mechanism. Write `plan.md`: commits in chronological order with files, branch and timestamp.

**D.7 - Timestamps**, per orphan file, into `timestamps.tsv` (`path, raw, adjusted, reason`):
1. Raw: mtime; else birth time (`stat -f '%B'`, GNU `stat -c '%W'`); else the folder's birth time.
2. Render with the source's real offset: `date -r <epoch> '+%Y-%m-%dT%H:%M:%S%z'`, GNU `date -d @<epoch> ...` (DST correct); never a fixed zone, never asked; ref and zip names stay UTC `Z`.
3. Sub-HEAD orphan (raw < target HEAD date, blob nowhere in history): HEAD date + 1 day, keeping the raw time of day, so leftover work lands after HEAD.
4. Blob already in history (slipped past C.5): the first occurrence commit's date.
5. Otherwise the raw time.
Commits follow ascending timestamps; an earlier orphan from a later cluster fires first as its own commit so the branch log stays monotonic. Each commit's author and committer date is the latest timestamp among its files.

**E - Commit**, in plan order: stage by name; apply `git-commit-audit` A-J; write in the moment, as the author would have on that date (no "era", "pre-X", "later refactored to", "before the extraction"); export the Step 3 identity and the D.7 date for author and committer; when pushing, push at once and verify the remote tip equals local, halting on mismatch.

**F - Merge** each working branch `--no-ff` into `dev_2` (P-1) or `dev` (P-2) per `git-merge-audit` (body: paragraph then nested list, no rebuild words; date = the branch's latest content commit). P-1: fast-forward `main_2` to `dev_2` and push it; never touch `dev`/`main`. P-2: merge `dev` into `main` `--no-ff`; the claim tags on v4rian repos, a legacy repo is tagged by hand after every audit passes. P-3: push the archival branch alone.
- After `git commit-tree` + `git update-ref` replays, run `git reset --hard dev_2` before any file operation (the worktree is not updated; symptom: `cp: No such file or directory`).
- Re-pushing `_2` branches: `--force-with-lease=<branch>:<sha from a fresh git ls-remote>`; the bare form bounces as "stale info".
- When pushing, every action pushes within seconds; never batch.

**G - Verify:** `git-coverage-audit` (tree byte-identical to the snapshot minus banned files), `git-compile-audit` and `git-runtime-audit` where the repo type supports them. On failure halt, report, and either ask or roll back from the mirror; never skip an audit.

## Output and state

`<workspace>/.ag-git-shuttle/runs/<run-id>/`: `BACKUP.manifest.json` (verbatim grants, blast radius, identity), `BACKUP/{source-snapshots,target-repos}/` (the only rollback: fetch from the mirror, `git update-ref` per branch), `snapshots/<name>/{coverage.txt, content-match.tsv, parent.txt, integration.tsv, integration-summary.md, diff.txt, judgment.md, plan.md, timestamps.tsv, ledger.md}`, `log/orchestrator.log`, `tools/` (link to the skill's tools) and `REPORT.md`: per snapshot C*, file counts, branches, commit and merge SHAs, tag, push state, `clean=true` when fully matched; per target the final dev, main and tag; every grant verbatim; every mid-run halt. Deliver REPORT.md with each plan, parent and ledger to the outbound shuttle.

## Banned (beyond the workspace bans)

- Touching user-authored commits (`git-history-preservation`); a needed rewrite goes to the user first (`git-history-rewrite`).
- Hardcoded paths, identities or grants in the skill.
- Inferring a `dev`/`main` grant; force-push without `--with-lease`; ever force-pushing `main`.
- Pushing before Step 4's credential probe passed.

## git-shuttle or git-snapshots

| Source | Use |
|---|---|
| Chain of `BAK *.zip` files | `git-snapshots` |
| Loose working-tree folder(s), a single folder, or no repo yet | git-shuttle |
| Zips and folders | `git-snapshots` for the zips, then git-shuttle |

Both use the same lens stack: `git-commit-audit`, `git-merge-audit`, `git-strategy-audit`, `git-coverage-audit`, `git-compile-audit`, `git-runtime-audit`, `git-snapshot-preflight`.
