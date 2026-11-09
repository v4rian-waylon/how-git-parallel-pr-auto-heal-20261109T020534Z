# Audit: docs lanes (local/spec-contradictions 14 + local/lean-skills 5 + local/lazy-loader 3, stacked on dev 5028b58)

Auditor: Fable 5.1, read-only, 2026-10-29. Worktree `$TMPDIR/aud-docs` at 8ab8932 (removed after the run); scratch repos under `$TMPDIR/aud-amend*`. Paths relative to `.io.v4rian.how-git/` at 8ab8932 unless stated. Rulings: `.neo-git-work/DECISIONS.md`.

## Suites (VERIFIED, worktree at 8ab8932)

- `framework-tests/test-hooks.sh`: 60 passed, 0 failed (rc 0).
- `framework-tests/test-lifecycle.sh`: 407 passed, 0 failed (rc 0), single sequential run (the suite is not parallel-safe per the roadmap backlog). Counts differ from the hook-correctness lane's 62/417 because this lane stacks on dev alone and does not carry that lane's new tests.
- New test `test_lean_loader_names_only_real_skills_and_tools` discriminates (each run with `--filter "lean loader"` on a mutated tree, then `git checkout --`): skill gains `[[feedback_x]]` → `0 passed, 1 failed` ("skills point at memory notes"); loader names `bin/statuz` → fail ("missing tool"); loader names `git-nope` → fail ("missing skill"). Gap: loader naming `skills/git-shuttle/tools/nope.sh` → `1 passed` (see DL-04).

## Findings

### DL-01 [MEDIUM] Ruling 4 unified the merge and PR body shape without checking the shipped PR path, which produces a different shape
- `skills/git-merge-audit/SKILL.md:26` ("every merge ... and its PR body: a 1-3 sentence macro paragraph, one blank line, then a nested list"), `:93` (character-identical parity), `skills/how-git/SKILL.md` Rules "Merge body, every merge and its PR body".
- Evidence VERIFIED by reading: `scripts/claim-dev-merge.sh:201-268` in connected mode takes the merge body from `gh pr view --json body` and then **prepends** `PR #N https://github.com/<owner>/<repo>/pull/N` as the first body paragraph (`:258-268`), so the merge body is never character-identical to the PR body and its first paragraph is a backreference, not the macro paragraph. `scripts/validate-pr-open.sh:312` runs `auto_fix_message` over the PR body (bullet verb rewrite, sentence cap). `.github/PULL_REQUEST_TEMPLATE.md` seeds the PR body with `## Summary` ("One to five sentences"), `## Cause + Fix`, `## Changes` markdown headers and "plain bullets": a PR written from the template and copied into the merge carries headers and a flat list the merge shape forbids. Ruling 4 asked to "first verify the three rules are a real contradiction and not different situations (e.g. merge vs PR vs dev->main)"; commit 47dae4a checked pool-vs-main altitude (rule 7) only. Runtime UNVERIFIED (no gh call made); the string concatenation is deterministic.
- Fix: state the connected-mode shape once in git-merge-audit rule 5 (merge body = `PR #N <url>` paragraph, blank line, then the PR body verbatim; parity = PR body equals merge body minus its first paragraph) and retire the `## Summary/## Changes` skeleton in the PR template to the same paragraph-plus-nested-list shape (or hand both to pool 8 feature.merge-body-in-hook and say so in the skill). Align the template's "One to five sentences" with the rule's 1-3 (auto_fix caps at `AUTO_FIX_MAX_SENTENCES=3`).
- Test: lifecycle test that builds a PR body in the rule's shape, runs the claim's amend step in connected mode (gh mock) and asserts `git log -1 --format=%b` equals `PR #N ...` + blank + PR body, and a validator test refusing a `## Changes` header.

### DL-02 [MEDIUM] Ruling 2 not applied in git-snapshots
- `skills/git-snapshots/SKILL.md:108` "decide single-commit-to-dev vs feature-branch" (Step 2), `:111` "invoke `git-commit-audit` (Section IX lens)" (no such section; the lens is A-J), `:128` `git push --force-with-lease origin main dev <feature-branches>`.
- Evidence VERIFIED: `grep -n 'single-commit\|Section IX' skills/git-snapshots/SKILL.md` on 8ab8932 prints both lines; the branch's diff of this file is dash scrub plus the identity line only. Commit 424aace names "the commit, strategy and shuttle skills" and misses this one, so the in-repo spec still teaches the contradiction ruling 2 resolved.
- Fix: "every topic gets a working branch, a single commit included"; "sections A-J"; `<working branches>`.
- Test: extend `test_lean_loader_names_only_real_skills_and_tools` (or the consistency lint) with a grep over `skills/*/SKILL.md` for `straight to .dev|single-commit-to-dev|Section IX`.

### DL-03 [MEDIUM] Ruling 6 contradiction left in git-history-preservation
- `skills/git-history-preservation/SKILL.md:88`: "agents run as the user's identity for commit attribution".
- Evidence VERIFIED: line present on 8ab8932; `docs/Git_Strategy.md:408-420` (new section) says every commit is authored as the account of the origin's org and the user only for rebuilds of the user's own snapshots. Commit 3153bf7 updated rewrite, preflight, snapshots and shuttle and left this sentence, which tells the reader the opposite of the section it should point at.
- Fix: "(agents run as the origin org's account, Git_Strategy "Commit identity follows the origin's org"; only rebuilds of the user's snapshots carry the user's name, so the author line alone does not decide)".
- Test: same grep lint as DL-02 for `run as the user's identity`.

### DL-04 [MEDIUM] Trimmed skills and the loader name tools and workflows that do not exist on this branch; the new test cannot see them
- `skills/git-shuttle/SKILL.md:52` (`skills/git-shuttle/tools/_snapshot-scope.sh`, `--extra-exclude`), `:56` (`tools/content-match.sh`), `:65` (`tools/integration-check.sh`); `skills/how-git/SKILL.md` row "Rebuild from working-tree folders" tools `skills/git-shuttle/tools/*.sh`; `skills/git-commit-audit/SKILL.md:8`, `git-compile-audit:8`, `git-coverage-audit:8`, `git-runtime-audit:8` ("on demand: `.github/workflows/audit-pushed-branch.yml`"); `skills/git-merge-audit/SKILL.md:90` (`dev-merge.yml` / `main-merge.yml` as manual re-runs).
- Evidence VERIFIED: `ls skills/git-shuttle/tools/` → "No such file or directory"; `git ls-tree -r --name-only local/lazy-loader .github` lists 7 workflows, none of the three named. They exist only on `local/ghost-tools` (pool 10): `git ls-tree local/ghost-tools` shows the three tool scripts and `_snapshot-scope.sh:13` documents `--extra-exclude`. dev also pointed at `tools/content-match.sh` (pre-existing ghost, rulings 9-10), but e03b55b's body claims the tools are "named at their shipped paths" and adds a new name. The loader test checks `bin/` and `skills/<name>/SKILL.md` only (mutation 4 above passes).
- Fix: merge pool 10 (ghost-tools) before this lane, or extend the test to resolve every `` `skills/<s>/tools/<x>.sh` `` and `` `.github/workflows/<w>.yml` `` the skills name; until then say "(pool 10)" next to the names.
- Test: the extension above; it fails on 8ab8932 alone and passes once ghost-tools lands.

### DL-05 [LOW] Rules dropped with no in-repo home (the rest of the before/after inventory is below)
- a) Global loader: "regexes and fixtures that need a dash write the `-` or `-` escape with a comment saying why". The lean loader folds this into "Hook-enforced: dash scrub (`pre-commit`)", but the hook rewrites code too (`githooks/pre-commit:87-98`, R18); the escape is the author's only legitimate way to keep a dash, and no skill or doc on 8ab8932 carries it (`grep -rn 'u2013\|u2014' skills docs README.md` → nothing).
- b) `git-merge-audit` dev rule 6 "No method names. No comma-separated inline enumeration." The enumeration ban is gone (method names survive in rule 8 "code-construct names").
- c) `git-commit-audit` dev 37 "No `zipN`, `bak`, `wip`, `snapshot` or `historical` in any branch name" left commit-audit; survives only in `git-strategy-audit` rule 8.
- d) Global loader "one pool is one feature area of about 20 commits" (memory `feedback_pool_branch_size`) appears nowhere in-repo (`grep -rn '20 commits'` → nothing); fine while the global loader is untouched, a gap at promotion.
- e) Global decision tree row "Bootstrap a new repo" has no lean-loader row (its intro-commit rule survives in Rules at a glance).
- f) Global off-grid close-up tail (push the pool and safety pair, `archive-pool-branch.sh` to vault) dropped: `bin/finalize-pool-merge:8-9,35` says the claim vaults and pushes, so enforced by tool (header only, runtime UNVERIFIED); the dirty-tree and `active-requirement` workarounds dropped rely on pools 4 and 5 landing first (roadmap order, acceptable).
- Fix: a) one line in git-commit-audit E.29 or the loader's hook-enforced line; b) add "no inline enumeration" to rule 6; d) and e) one line each in the loader (or accept and record in the promotion checklist).

### DL-06 [LOW] Ruling-8 recipes are BSD-only and CI runs on ubuntu
- `skills/git-commit-audit/SKILL.md:F.30` `date -r "$EPOCH" +%Y-%m-%dT%H:%M:%S%z`, `skills/git-shuttle/SKILL.md` D.7.2 `date -r <epoch>`, F.30 `stat -f`. GNU `date -r` takes a file (the epoch form is `date -d @<epoch>`); GNU stat is `stat -c %Y`.
- Evidence VERIFIED on this host: `date -r 1750266836 '+%Y-%m-%dT%H:%M:%S%z'` → `2025-06-18T10:13:56-0700`, git stores it as `2025-06-18T10:13:56-07:00`; `date -d` → "illegal option" (BSD). GNU behaviour from the coreutils manual, UNVERIFIED here (no GNU date on the machine). Dev had the same `date -r` shape, but the branch rewrote these lines and kept them macOS-only.
- Fix: give both forms once (`date -r E ... 2>/dev/null || date -d @E ...`) or point at a `bin/` helper when pool 15 lands.

### DL-07 [LOW] Commit hygiene: three commits carry author dates later than their descendants
- `git log --reverse --format='%h %ad' dev..local/lazy-loader`: 296cf2d 05:39:25 → 25ad590 05:56:12 → 670befe 05:56:30 → 67d5192 05:39:55 → da64424 05:56:59 → e03b55b 05:46:46. The three were re-created after their children (amend or reword later in the session) and the global loader lesson "assert that dates never go backwards" is violated on this branch. VERIFIED.
- Otherwise clean: 22 titles 41-69 chars, approved tags, identity `v4rian-waylon (Opus)` as author and committer on all 22, no em/en dash or `Co-Authored-By` in any message. Body claims re-checked: byte table in e3eec35 (7454, 12824, 6240 match `wc -c`), "17 memory names" in 2e7c825 (17 distinct names at the spec-contradictions tip, VERIFIED), "git commit --amend keeps the author even with GIT_AUTHOR_NAME exported" in 670befe (scratch repo: `author=Original Author | committer=v4rian-waylon (Fable 5.1)`; `--reset-author` flips it, VERIFIED).
- Fix: none required for the replay (the orchestrator re-dates on the pool); note so the replay sets dates monotonic.

### DL-08 [LOW] Cosmetic text defects introduced
- `skills/git-commit-audit/SKILL.md:76-78` section J breaks a sentence over a hard newline ("fails:" / "sound reasoning plus a clean compile is not a receipt.") and leaves "No behavioral claim ..., no section." as a one-line paragraph.
- `skills/how-git/SKILL.md` row "Rebuild from bak zips" puts a skill (`git-snapshot-preflight`) in the Tools column.
- `skills/git-strategy-audit/SKILL.md:71` still says "`pre-push` hook warns but allows" right-shaped local spikes; `githooks/pre-push` passes them silently and `post-checkout` is the hook that warns (pre-existing wording, kept while the surrounding sentence was rewritten).

### DL-09 [INFO] Pre-existing stale text not introduced here, for the lint pool
- `README.md:97-99` lists `how-push` as a shipped skill (none in `skills/`; roadmap pool 9). `docs/IMPLEMENTATION_HANDOFF.md` still describes a VERSION file and `dev-merge.yml` (flagged "none of that ships today"). `.github/PULL_REQUEST_TEMPLATE.md` "One to five sentences" (see DL-01).

## Enforcement claims checked (every "enforced by" the branch introduced)

| Claim | Where stated | Hook or script line | Verdict |
|---|---|---|---|
| Subject 8-100, 140 for `[MERGE]`/`[REQ]` | commit-audit B.8, merge-audit 3, CONTRIBUTING | `githooks/commit-msg`: `case "$subj" in "[MERGE] "*\|"[REQ] "*) max=140 ;; *) max=100 ;;` then `exit 1` when `len < 8 \|\| len > max` | VERIFIED |
| Em/en dashes, "plus", `Co-Authored-By: Claude` rewritten away by `auto_fix_message` steps 1-3; hook skips merge, squash, amend, conventional subjects | commit-audit B.10, loader hook line | `scripts/lib/auto-fix-commit-message.sh` "# 1." `re.sub(r'(?im)^co-authored-by:\s*claude.*\n?', '')`, "# 2." `replace('-','-').replace('-','-')`, "# 3." banned words → `and`; `githooks/prepare-commit-msg:33-36` `case "$source" in merge\|squash\|commit) exit 0`, `:44-46` conventional regex | VERIFIED (the skill states the skip and that the rule still binds there) |
| Staged-file dash scrub, re-staged | commit-audit E.29, loader | `githooks/pre-commit:87-98` python replace then `git add -- "$abspath"`; skip list `:37-43`, binary skip via `file -b --mime-encoding` | VERIFIED |
| Branch names refused by pre-push regex | strategy-audit header and rule 5 | `githooks/pre-push:36-38` pattern with `(v[0-9]{4}\.[0-9]+/)?` and `doc`, `exit 1` on mismatch (current branch only, R12 is pool 5) | VERIFIED |
| `rulesets/pool-creations.json` when connected | strategy-audit header, rule 6 | file present in `rulesets/` | VERIFIED (content not evaluated) |
| Push audits are `ci/audits/push/required.{compile,coverage,runtime,commit-audit}.sh` via `ci-dispatch.yml`, off-grid `bin/ci-local` | the four "Runs in CI" lines | files present; `ci-dispatch.yml` `on: push: branches: '**'`; `bin/ci-local --help` lists the five triggers | VERIFIED |
| CI judge `claude_judge_commit` reads the lens | commit-audit header | `ci/audits/push/required.commit-audit.sh` → `scripts/workflows/audit-retry.sh --audit commit-audit`; `scripts/audits/commit-audit.sh` `SKILL_PATH=$(resolve_skill git-commit-audit)`, `claude_judge_commit_range "$shas" "$SKILL_PATH"` | VERIFIED (returns 0 with a WARN when no credential, as the script states) |
| Skills overridden by name from `~/.config/how-git/skills/` | loader header | `scripts/_lib.sh:140-153` `user_skills_dir` = `${HOW_GIT_USER_SKILLS_DIR:-$HOME/.config/how-git/skills}`, `resolve_skill` | VERIFIED |
| Version from `bin/version --next-dev` / `--release-tag`, stamped by the claim scripts | merge-audit 4a, commit-audit H.36 | `bin/version --help` (2,182 bytes) lists both flags; `claim-dev-merge.sh:207` `NEW_SUBJECT="[MERGE] $MERGED_POOL into dev: $NEXT"` | VERIFIED |
| Safety anchors never GC'd | Git_Strategy rationale, `bin/ship:10` | `scripts/claim-main-release.sh:24-25,300-301` "Safety/ anchor branches are never touched by this script" | VERIFIED |
| Claim vaults the pool and pushes (replaces the dropped `archive-pool-branch.sh` step) | implied by the lean close-up line | `bin/finalize-pool-merge:8-9,35` header | header only, runtime UNVERIFIED |
| `bin/create-pool-branch --no-jira --help` | loader row 2 | `--help` alone exits 2 ("--jira KEY-NNN is required"); with `--no-jira` exits 0, 1,650 bytes | VERIFIED |
| `audit-pushed-branch.yml`, `dev-merge.yml`, `main-merge.yml`, `skills/git-shuttle/tools/*.sh` | four skill headers, merge-audit 17, git-shuttle B/C/C.5, loader | absent on 8ab8932, present on local/ghost-tools | NOT ENFORCED HERE (DL-04) |

## Before/after rule inventory

Legend: V verbatim or tightened, R rephrased, E enforced by a named tool, X vanished (see DL-05), M moved to another skill.

### git-commit-audit (dev 43 items + J + ritual → tip 37 items + I + J + ritual)
A1 V · A2 V · A3 V (folded into 1) · A4 R (2400-line example dropped) · A5 R (ruling 2) · B6 V+ (adds `[REQ]`/`[MODE]`, no `[CLEANUP]`, never invented Jira) · B7 R (bullet list collapsed, smell test kept) · B8 R (72 target, hook limits, E) · B9 M→H.36 · B10 R (hyphens 9, dashes/plus E via prepare-commit-msg 10) · C11 V · C12 V · C13 V+ (absolute "no Changes:") · C14 M→git-merge-audit Body · C15 R (hyphens in 9; dashes/plus E) · C16 V · C17 E (prepare-commit-msg) · D18-27 V (V.1-V.10, recipes compressed into V.10) · E28 V · E29 V (in 26) · E30 V · E31 R ("project still imports" X) · F32 R (ruling 8: both dates, offset, no `%Sm` Z, UTC names, monotonic, ≤ now; "ASK ONCE" removed by ruling) · F33 R · F34 R (merge date) · F35 R (`[DOCS]` date) · G36 R (ruling 2 + root-commit exception) · G37 R (allocator, never pick nN, never push pool/safety, `vYYYY.MAIN/`, `doc`); "no zipN/bak/wip/snapshot/historical in branch names" M→strategy-audit 8 (DL-05c) · G38 V · G39 V · H40 R (bin/version, claim stamps; legacy → merge-audit) · H41 M→merge-audit · H42 V · H43 R · I V+ (rewrite keeps author, new) · J R (receipts kept, verdict kept) · ritual R. New: A4 "plan the split before staging". No rule vanished except the two X items above.

### git-merge-audit (dev 1-17 + parity + lens → tip 1-17 + parity + lens + Legacy)
1 V (pool examples, legacy to its section) · 2 V · 3 E (commit-msg 140; "sentence case" X, moot for `[MERGE] pool/...` titles) · 4 V · 4a R (bin/version, ruling 3) · 5 R (ruling 4, 1-3 sentences, example) · 6 R (failure cases; "no comma-separated inline enumeration" X, DL-05b; "no method names" → rule 8 code-construct names) · 7 V (altitude split kept, ruling 4) · 8 R (prose "Adds <topic> (vX title)" shape dropped: it was the contradiction; tone poles V) · 9 V · forbidden 8-10 V · 11 V · 12 V (legacy block → Legacy section) · 13 V · 14 R · 15 V · 16 V · 17 R (claim scripts, ruling 5/9) · parity 10 V+ (diff command added; see DL-01) · lens R (ruling 3 and 4 fixes) · retro V. Dead links 8 → 0.

### git-shuttle (dev 483 lines → tip 105)
Principles 1-5 R (identity/timestamps derived per rulings 6 and 8) · voice pairing R (workspace channel; hardcoded `agi-call.mjs` path and `127.0.0.1:8094` X, intended) · Step 1a-1d R · Step 2 R · 2b Init R ("set default branch via workspace preference" X, minor) · 2b Clone R · 2b Attach R · 2b Other M→Principle 2 · Step 3 V · Step 4 R · Step 5 R · Step 6 R · Step 7 R · chronological succession R · A V · B R (tool path, DL-04) · C V (table) · C.5 R · D V · D.5 P-1/P-2/P-3 R · D.6 R (ruling 2, `[REFACTOR]`) · D.7 V (all five steps, ordering, max timestamp) · E R (A-J, in-the-moment language, push verify) · F R (shape per merge-audit, commit-tree caveat, force-with-lease idiom, P-2 claim tags / legacy by hand, P-3) · G V · Output and state R · Banned R (`git add -A` → Step E "stage by name"; `Co-Authored-By` E) · when-to-use V. Dead links 32 → 0. Nothing load-bearing vanished; two hardcoded paths removed on purpose.

### git-strategy-audit
STATUS → E line (pre-push, allocator, ruleset) · model table R (bin/version marker, ruling 3) · v4rian model R (claim tags, `doc`, `vYYYY.MAIN/`) · legacy section V (only place for `feature/*`, ruling 5) · branch-per-commit-count → every change rides a branch (ruling 2) · naming 5 E (regex now read from the hook) · 6 R · 7 R · 8 V · 9 V · planning 3-4 R · lens 1 R, 10 R · banned R. Dead links 15 → 0.

### Loader: global `~/.claude/skills/how-git/SKILL.md` (11,532 B) → in-repo `skills/how-git/SKILL.md` (6,240 B)
On-invoke 1 memories → X (workspace-specific; identity rule 3 replaces `feedback_user_authors_when_rebuilding_history`) · 2 read every skill + both docs → one row, sections on demand (the diet) · 3 model R · 4 confirm line X (stated) · Rules: audits before ship R · receipts V · plan names every skill V · merge only after the user ran it, no PR unless asked, parity V ("deliver commits, branch, artifact meanwhile" X, guidance) · push after each commit, every ref, verify ls-remote R (`git push --all` dropped, which removes the global loader's contradiction with git-snapshot-preflight "never `git push origin --all`") · one defect one pool V · no empty commits, FF main V · intro commit V · no invented Jira V · cherry-pick diff V · merge body V+ example · hash compare V · trash rule R (`~/.Trash/git-branch-trash/` path X, workspace-specific) · sym9 grant R (automation) · allocator rules R (n165 ls-remote workaround X, fixed in pool 1) · dash escape X (DL-05a) · off-grid close-up R (tail X, DL-05f) · ceremony identity R (ruling 6) · dirty-tree and `[REQ]` conflict workarounds X (pools 4 and 5) · legacy close-up X (workspace) · decision tree: bootstrap row X (DL-05e), hotfix merged into branch row, "em-dash scrub on full main..dev" at release X (covered by pre-commit plus the push-range em-dash gate in `scripts/audits/commit-audit.sh`) · lessons section X (branch size DL-05d; merge dates in merge-audit 12; pinned-SHA map X, rebuild guidance). Hook-enforced line VERIFIED item by item (table above).

## Rulings applied

1 canonical source: README paragraph, fractaris 97 lines reviewed (claim in 67d5192, not re-run) → applied. 2 every change rides a pool: commit, strategy, shuttle, loader → applied; git-snapshots → missed (DL-02). 3 tags are the seal: README, strategy marker, merge-audit 4a, commit-audit H → applied. 4 merge body: shape unified with example, pool-vs-main kept as altitude (rule 7) → applied; merge-vs-PR not verified against claim-dev-merge and the PR template (DL-01). 5 naming: `pool/[vYYYY.MAIN/]nN.kind.name`, `doc` kind, no `[CLEANUP]`, no `Changes:`, `feature/*` legacy-only, `[REQ]`/`[MODE]` tool-written (auto_fix `re.match(r'\[[A-Z]+\]\s')` accepts them unchanged, VERIFIED) → applied. 6 identity: Git_Strategy section, rewrite/preflight/snapshots/shuttle/loader, honest "hooks refuse a mismatch once the resolver ships" (pool 6) → applied; history-preservation sentence contradicts (DL-03). 7 CI watch: how-dev binding only with a connected CI, local via `bin/ci-local` → applied. 8 timezone: commit-audit F, shuttle D.7, preflight builder `time.localtime(epoch)` `%z`, UTC Z names, no asking → applied (BSD-only recipes, DL-06). Rewrite preserves author: git-history-rewrite paragraph, commit-audit I, loader rule; proven in a scratch repo → applied. R14f safety forever: Git_Strategy rationale, `bin/ship` header, claim-main-release never touches safety → applied.

## Lazy loader simulation (bytes an agent reads per row; old = global loader step 2 in a v4rian repo on dev 5028b58)

Old, every task: loader 11,532 + 4 memories 3,754 + 13 in-repo git-* skills 147,364 + how-dev 5,636 + how-push 1,147 + how-preflight 4,070 + Git_Strategy 22,302 + RUNBOOK 49,222 = **245,027 bytes ≈ 61k tokens** (at 4 bytes per token; the commit's "about 65,000" is consistent). New = loader 6,240 + the row's skills at 8ab8932 + each named `--help` as printed in the worktree (smart-commit 4,468; create-pool-branch 1,650; status 466; init-pool-merge 2,230; finalize-pool-merge 2,373; version 2,182; init-release 2,210; ship 1,197; ci-local 1,682; attach 882; sync-framework 2,659; doctor 2,055).

| Row | Files read | New bytes | ≈ tokens | Saving |
|---|---|---|---|---|
| Compose a commit | loader, git-commit-audit, smart-commit help | 18,162 | 4,540 | 93% |
| Create a working branch or hotfix | loader, git-strategy-audit, create-pool-branch, status | 19,008 | 4,752 | 93% |
| Merge a pool into dev | loader, git-merge-audit, init-pool-merge, finalize-pool-merge, version | 22,869 | 5,717 | 91% |
| Release dev to main | loader, git-merge-audit, git-runtime-audit, init-release, ship | 32,304 | 8,076 | 87% |
| Rewrite my own history | loader, git-history-preservation, git-history-rewrite | 21,075 | 5,268 | 92% |
| Rebuild from bak zips, orchestrator only / full chain | git-snapshots alone / plus 10 sub-skills | 15,126 / 95,228 | 3,781 / 23,807 | 94% / 62% |
| Rebuild from working-tree folders, orchestrator only / full chain | git-shuttle alone / plus 8 sub-skills | 19,064 / 84,331 | 4,766 / 21,082 | 93% / 66% |
| Replay or rebase across diverged history | loader, git-reconcile-intent | 13,971 | 3,492 | 95% |
| Verify compile, coverage or runtime (runtime, the largest) | loader, git-runtime-audit, ci-local | 20,735 | 5,183 | 92% |
| After a push | loader, how-dev, ci-local | 14,062 | 3,515 | 95% |
| GitHub API call needing credentials | loader, git-token-discovery | 11,248 | 2,812 | 96% |
| Adopt or migrate the framework | loader, attach, sync-framework, doctor | 11,836 | 2,959 | 96% |

Each row loads the right skills for its task (checked against the global decision tree); the two gaps are the missing bootstrap row (DL-05e) and the ghost tool column (DL-04). Full-chain rebuilds still save 62-66% because the two strategy docs (71.5 KB) and the unrelated skills drop out.

## Verdict

FIX-THEN-MERGE. No gate, hook or data-loss path is weakened (docs and one test only); the four mediums are text fixes (DL-01 to DL-03) and a merge-order or test-scope decision (DL-04).
