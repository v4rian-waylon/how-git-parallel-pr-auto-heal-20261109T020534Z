# neo-git pending branches audit (2026-10-29)

Adversarial black-box audit of two unmerged pieces of work on top of dev 5028b58 (v2026.0.136):

1. `pool/v2026.0/n165.fix.off-grid-allocator-ignores-clone-refs` (eb3e4f9, 02ca0df, 30ec63d, 0753e12)
2. `local/reconstruct-tool-pending-allocation` (983ca80) and its twin aa1a68c on `landing-base` / `dev-landing`

Method: read-only inspection of `<workspace>/neo-git`; execution in detached throwaway worktrees under `$TMPDIR/neo-audit-*` (removed afterwards); reproduction scripts kept in the session scratchpad (`repro-n165.sh`, `repro-n165b.sh`, `repro-recon*.sh`). Framework tests run: `--filter allocator` (23/23 PASS at n165 tip), `--filter "counts remote-tracking"` at each of the four n165 commits (PASS at every step: the fixture grows with each fix, atomicity is intact), `--filter reconstruct` (16/16 PASS at 983ca80), `--filter consolidated` (2/2 PASS).

Paths below are relative to `.io.v4rian.how-git/` unless absolute. Line numbers refer to the file at the audited commit.

## 983ca80 vs aa1a68c verdict

**Identical content.** All seven touched files produce line-identical hunks (`diff` of the `-U0` +/- lines of each file: identical; the three new files `bin/reconstruct`, `scripts/reconstruct.sh`, `skills/git-reconstruct/SKILL.md` show an empty `git diff --stat aa1a68c 983ca80`). `git patch-id --stable` differs (e848bcd… vs a652a52…) only because the context lines of `test-lifecycle.sh` differ between the two bases. Same author, same timestamp, same message.

The difference is the base: aa1a68c sits on 58ea397 (v2026.0.121) whose `scripts/_lib.sh` has no `resolve_skill` (`bash -c '. _lib.sh; type resolve_skill'` → `not found`), so its three claude subcommands fail outside test mode (`reconstruct.sh: line 455: resolve_skill: command not found`, reproduced with a stub `claude` on PATH). 983ca80 sits on dev where `resolve_skill` exists (`_lib.sh:144`). Only 983ca80 is landable; aa1a68c / `landing-base` / `dev-landing` are superseded.

## Counts

| severity | count |
|---|---|
| critical | 1 |
| high | 5 |
| medium | 10 |
| low | 11 |

---

## Part 1: n165 off-grid allocator

### N1 · high · history scan is HEAD-relative, the inflx repository shape still restarts at n1
- **file:line** `scripts/allocate-pool-branch.sh:413` (`git log --format='%s'` with no revision argument)
- **evidence** VERIFIED. Fixture: repo whose only record of n3 is the landing subject on `dev`, HEAD on a topic branch cut before that landing (the operator state after `git checkout <branch>`):
  ```
  HEAD=topic
  "branch_name": "pool/v2026.0/n1.feature.inflx"
  ```
  Second fixture (n165 test shape, HEAD on a stale `pool/n63.fix.x`): `pool/v2026.0/n65.feature.headcheck` while the landing subject on `dev` says n70. Detached HEAD at the root commit likewise ignores every landing above it. The commit message of 0753e12 names exactly the inflx repository as the motivating case; the fix only holds while HEAD is `dev`.
- **fix** scan every ref, not HEAD: `git log --all --format='%s'` (or at minimum `refs/heads/dev refs/remotes/*/dev`, since landings happen on dev and the allocator already requires `refs/heads/dev`). Keep `2>/dev/null || true` for the unborn-HEAD case.
- **test** `test_allocator_off_grid_history_scan_is_not_head_relative`: seed `dev` with one `[MERGE] pool/v2026.0/n3.… into dev` subject and no pool/safety/vault refs, `git checkout -b topic <root>`, allocate off-grid, assert `*n4.*`; a second assertion with `git checkout --detach <root>`.

### N2 · high · shallow or single-branch clone silently restarts the counter
- **file:line** `scripts/allocate-pool-branch.sh:244-246, 413`
- **evidence** VERIFIED. `git clone --depth 1 --branch dev` (depth implies `--single-branch`), origin history carries `[MERGE] pool/v2026.0/n4.… into dev` one commit below the tip:
  ```
  shallow=true commits visible=1
  "branch_name": "pool/v2026.0/n1.feature.shallow2"
  ```
  Remote-tracking refs: one (`origin/dev`). No warning, exit 0, JSON `status: created`. This is precisely the V4Rlib / inflx collision class the branch sets out to close, re-entered through a different door.
- **fix** before `next_n` in off-grid mode: refuse (exit 2) when `git rev-parse --is-shallow-repository` prints `true`, and when the fetch refspec of the remote `dev` tracks does not cover `refs/heads/*` (`git config --get-all remote.<r>.fetch`), with a message naming `git fetch --unshallow` / `git remote set-branches <r> '*'`. A refusal is correct here: the spec promises "no collisions", and an allocator that cannot see the repository must say so rather than guess.
- **test** `test_allocator_off_grid_refuses_shallow_clone`: clone `--depth 1`, allocate, assert rc 2 and message; assert no `pool/` ref was created.

### N3 · medium · every remote's refs are counted, a framework or upstream remote pollutes the consumer's counter
- **file:line** `scripts/allocate-pool-branch.sh:245` (`refs/remotes/*/$prefix**`)
- **evidence** VERIFIED. Consumer whose highest own number is n70 with a second remote `how-git` that carries `pool/v2026.0/n165.fix.framework-own-branch`:
  ```
  "branch_name": "pool/v2026.0/n166.feature.foreigncheck"
  ```
  Any consumer that adds the framework (or a fork, or a colleague's clone) as a remote inherits foreign numbers. Not a collision, but the sequence stops meaning "creation order in this repository" (Git_Strategy.md:65 "creation sequence number").
- **fix** scan only the remote that `dev` tracks (`git config branch.dev.remote`, fallback `origin`): `refs/remotes/$R/$prefix**`.
- **test** `test_allocator_off_grid_ignores_foreign_remotes`: add a second remote carrying `pool/n500.…`, allocate, assert the number continues from the consumer's own max.

### N4 · medium · the n165 test no longer proves two of the three fixes
- **file:line** `framework-tests/test-lifecycle.sh:3176-3225` (`test_allocator_off_grid_counts_remote_tracking_refs`)
- **evidence** VERIFIED. Copy of the n165 tree with the remote-tracking scan line (`refname:lstrip=3`) deleted and `$(list_refs_for_prefix "vault/")` removed:
  ```
  remaining lstrip+vault-scan lines: 0
  allocator off-grid counts remote-tracking refs ...   PASS
  ```
  Because the fixture's `dev` carries the n70 landing subject and the clone checks out `dev`, the history scan alone yields n71. eb3e4f9 and 30ec63d have no failing test once 0753e12 is in place. (The per-commit evolution was fine: at 02ca0df the fixture expected n64, at 30ec63d n65, at 0753e12 n71; each commit was green.)
- **fix** three fixtures, one per source: remote-only pool/safety refs (no vault, no subject) → `n64`; remote-only vault ref with a lower pool ref → `n65`; subject-only → `n71`. Or one fixture with three clones where each source is the unique maximum.
- **test** split the existing function into `…_remote_refs`, `…_vault_refs`, `…_landing_subjects`, each asserting the exact number and each failing when its own scan is removed (mutation check in the test comment).

### N5 · medium · no fetch before an off-grid allocation, so remote-tracking refs are as stale as the last fetch
- **file:line** `scripts/allocate-pool-branch.sh` (0 occurrences of `git fetch`), `bin/create-pool-branch` (0 occurrences)
- **evidence** VERIFIED by read: `grep -c 'git fetch'` → 0 in both files; the eb3e4f9 message says the scan "stays offline either way". Two clones that each allocated after the last fetch still both hand out the same number (the V4Rlib n61 story recurs whenever clone B has not fetched since clone A pushed). Git_Strategy.md:65-66 promises "atomic … no collisions".
- **fix** when the tracked remote exists, attempt `git fetch --prune --quiet $R 'refs/heads/pool/*:refs/remotes/$R/pool/*' 'refs/heads/safety/*:…' 'refs/heads/vault/*:…' refs/heads/dev` with a short timeout; on failure print one warning line naming the staleness (`last fetch: <mtime of .git/FETCH_HEAD>`) and continue. Document the residual window in RUNBOOK (off-grid row of the per-mode matrix) and Git_Strategy §Working branches.
- **test** `test_allocator_off_grid_fetches_tracked_remote_first`: origin gains `pool/n80.…` after the clone, allocate from the clone, assert `*n81.*`; second assertion with an unreachable remote URL asserts the warning line and a successful allocation.

### N6 · low · landing-subject regex is unanchored, any `[MERGE]` subject with `/nN.` inflates the counter
- **file:line** `scripts/allocate-pool-branch.sh:409, 413`
- **evidence** VERIFIED. `[MERGE] dev into main: v2026.0.9 (see docs/n9000.md)` on dev → `pool/v2026.0/n9001.feature.inflatecheck`. Not a collision; a permanent gap in the sequence that the structural audit of the reconstruct tool would then report.
- **fix** anchor on the branch namespace: `grep -oE '(pool|safety|vault)/(v[0-9]+\.[0-9]+/)?n[0-9]+\.' | grep -oE 'n[0-9]+' | tr -d n`. Then the `grep -F '[MERGE]'` prefilter becomes unnecessary (the anchored regex already excludes prose).
- **test** add a `[MERGE] dev into main … docs/n9000.md` subject to the fixture and assert the counter is unaffected.

### N7 · low · one fork per landing subject
- **file:line** `scripts/allocate-pool-branch.sh:408-414`
- **evidence** VERIFIED. 3000 landing subjects → `real 22.21` seconds for one allocation (three processes per subject). neo-git itself has ~300 landings today.
- **fix** one pipeline: `git log --all --format=%s | grep -oE '<anchored regex>' | grep -oE '[0-9]+' | sort -n | tail -1`.
- **test** none needed beyond N1/N6 fixtures; optional timing guard in the e2e runner.

### N8 · low · documentation not updated with the behaviour change
- **file:line** `scripts/allocate-pool-branch.sh:21-22` (header still says `max(existing pool/n*, safety/n*) + 1`, printed by `--help` via `sed -n '2,88p'`); `docs/RUNBOOK.md:30` ("Allocate pool/safety pair … (currently connected-only; allocator workflow drives it)" while the branch is about off-grid allocation); `docs/Git_Strategy.md:65-66` ("atomic on the server, no collisions" with no off-grid caveat); `docs/CHANGELOG.md` `## Unreleased` has no n165 entry although `scripts/workflows/doc-freshness-check.sh:35-37` gates dev→main on bytes per merge in that section.
- **evidence** VERIFIED by read (quoted lines).
- **fix** header: "max over pool, safety, vault refs (local and tracked remote) and landing subjects in history"; RUNBOOK row: `bin/create-pool-branch` (local allocator, counts remote-tracking refs, fetch first); Git_Strategy: one sentence on the off-grid guarantee; CHANGELOG paragraph.
- **test** existing doc-freshness check covers CHANGELOG; `test_allocator_help_describes_counter_sources` greps `--help` for `vault`.

### N9 · low · wrong diagnostic in the test's case arms
- **file:line** `framework-tests/test-lifecycle.sh:3219` (`*n65.*) echo "reissued a number recorded only by its merge commit"`)
- **evidence** VERIFIED by read. n65 is `max(vault n64)+1`: nothing was reissued, the landing subject was ignored. Only `*n1.*` and a hypothetical `*n70.*` would be reissues.
- **fix** `*n65.*) echo "ignored the landing subject (n70) in history"`, `*n64.*) echo "ignored the archived vault branch (n64)"`.
- **test** n/a (message text).

### N10 · low · the history scan is dead in connected mode
- **file:line** `.github/workflows/allocate-pool-branch.yml:81` (`fetch-depth: 1`), `scripts/allocate-pool-branch.sh:413`
- **evidence** VERIFIED by read. In CI the checkout has one commit, so the "last record" fallback the comment at 397-406 describes never fires for connected repositories; the vault API scan does. The repository's own history already shows connected collisions: `pool/n67.refactor.pr-reference-appends-github-url` vs `pool/v2026.0/n67.refactor.complete-framework-offgrid-parity`, and two different `n96` branches under `v2026.0` (`git for-each-ref … | grep -oE 'n[0-9]+\.' | sort | uniq -d`).
- **fix** either `fetch-depth: 0` in the workflow or a comment stating the history fallback is off-grid-only; consider the same anchored subject scan via the API (`GET /repos/{r}/commits?sha=dev`) if connected coverage is wanted.
- **test** none offline; note in RUNBOOK.

### N11 · low · commit lens nits
- **file:line** commits eb3e4f9, 0753e12
- **evidence** VERIFIED by read. Bodies assert observed behaviour ("V4Rlib carries the result: two different branches both allocated as n61", "inflx has four different branches all numbered n1") with no `Receipts:` section (git-commit-audit §J). Author name `v4rian-waylon` lacks the `(Model)` suffix how-dev §"Commit author name carries the model" requires. Otherwise compliant: `[FIX]` bodies carry `Cause:`/`Fix:`, no joiners in titles, no em dashes, no trailer.
- **fix** add `Receipts:` lines (branch names observed) or drop the claims; amend author name before merge (developer-owned unmerged branch, allowed by Git_Strategy.md:76-84).
- **test** n/a.

---

## Part 2: 983ca80 reconstruct tool and git-reconstruct skill

### R1 · critical · `relocate` rewrites the caller's repository when the target path is wrong
- **file:line** `scripts/reconstruct.sh:293` (`( cd "$repo"` with no `|| exit`), `:310` (`$filter_repo_bin --to-subdirectory-filter "$subdir" --force`), file header `set -uo pipefail` (no `-e`)
- **evidence** VERIFIED with a stub `git-filter-repo` on PATH, invoked from a repo named `victim` with a nonexistent repo argument:
  ```
  reconstruct.sh: line 293: cd: /nonexistent/repo: No such file or directory
  FAKE git-filter-repo invoked in cwd=…/scratchpad/victim args=--to-subdirectory-filter cpp --force
  branches: 1 -> 1
  tags: 0 -> 0
  ```
  With the real tool this rewrites every commit of whatever repository the operator is standing in, drops its `origin` remote and expires its reflogs (filter-repo defaults). `--force` disables filter-repo's own fresh-clone guard. No preflight ref, no bak zip (how-preflight), no safety branch.
- **fix** `cd "$repo" || return 2`; refuse unless the repo is a fresh clone (filter-repo's own check, drop `--force`) or a `git-preflight.sh` ref plus bak zip exists for it; print the resolved absolute path before running.
- **test** `test_reconstruct_relocate_refuses_missing_repo`: stub `git-filter-repo` on PATH that writes a marker file, call `relocate /nonexistent cpp` from a scratch repo, assert rc 2 and that the marker was never written.

### R2 · high · `relocate` resets local branches to origin, discarding unpushed commits
- **file:line** `scripts/reconstruct.sh:297` (`git branch -f "$b" "origin/$b" >/dev/null 2>&1 || true`)
- **evidence** VERIFIED. `pool/n1.feature.x` with one pushed and one local-only commit:
  ```
  pool tip before: 45e308e [NEW] Local only, never pushed
  pool tip after : 61055e6 [NEW] Pushed
  reflog of pool: 61055e6 pool/n1.feature.x@{0}: branch: Reset to origin/pool/n1.feature.x
  ```
  The dropped commit survives only in the reflog, which the following `git filter-repo` expires and gc's. The checked-out branch is spared only because `git branch -f` refuses to move HEAD's branch (and the `|| true` hides that refusal).
- **fix** create only missing branches: `git show-ref --verify -q "refs/heads/$b" || git branch --track "$b" "origin/$b"`; when a local branch is ahead of its remote-tracking ref, refuse with the list (the operator pushes first).
- **test** `test_reconstruct_relocate_never_moves_an_existing_local_branch`: same fixture, assert the tip SHA is unchanged and the tool exits non-zero naming the branch.

### R3 · high · `scrub` misses whole branches, misreports the commit SHA, and reports 256 hits as clean
- **file:line** `scripts/reconstruct.sh:240-253, 258`
- **evidence** VERIFIED (three runs):
  - hit only on `pool/n1.feature.x`, HEAD on `main`: `clean: no hits for any supplied term`, rc 0 (`git log` scans HEAD only; SKILL Step 9 and the CHANGELOG promise "every commit message body").
  - hit in a body line: `HIT (commit): Body: codename-zulu` while the real SHA is `7b89090…` (`%H %B` is multi-line, `awk '{print $1}'` prints the first word of the matching line).
  - 256 one-hit files: `hits=256 rc=0` (`exit "$hits"` wraps modulo 256), so a large leak is reported as success to the caller.
  - directory-name leak (SKILL Step 9 category 5): file at `codename-dir/file.txt` with clean content → `clean: no hits` (paths are never swept).
- **fix** `git log --all --format='%H%x00%B%x00' | python3 -c …` or `git log --all -F --grep="$term" --format=%H`; sweep `git ls-files` for path hits; `exit $(( hits > 0 ))` and print the count on its own line.
- **test** four assertions: branch-only hit found; body hit prints the real SHA (compare with `git rev-parse`); 256 hits → rc 1; path hit reported as `HIT (path): …`.

### R4 · high · `audit-structure` contradicts the protocol it audits
- **file:line** `scripts/reconstruct.sh:133-140` (check 1), `:163-176` (check 3), `:180-186` (check 4), `:189-194` (check 5), `:197-205` (check 6)
- **evidence** VERIFIED:
  - check 1 on an original pool branch landed through its reconcile candidate (the normal path RUNBOOK.md:143 "Reconcile-merge dual-vault" describes): `FAIL: pool branch 'pool/n1.feature.thing' has no matching [MERGE] pool/n1.feature.thing into dev commit on dev`.
  - check 3 against neo-git itself: `FAIL: tag 'v2026.0.0' points at a non-merge commit (7195dc4…)`, same for `v2026.1.0` and `milestone/gen-complete-offline`; the `.0` seal tags are how the framework marks a cycle, so every conforming how-git repository fails its own structural audit.
  - check 4 (`git tag | sort | uniq -d`) can never fire, tag names are unique refs; SKILL Step 8 item 4 promises "no gaps or duplicates" and the gap half is not implemented.
  - check 5 tests `README.md` and `.gitignore`; SKILL Step 8 item 5 promises README, MANUAL, LICENSE, `.gitignore`, build entry point.
  - check 6 compares `dev` only; SKILL Step 8 item 6 promises "local dev and local tags match origin".
  - against neo-git: `FAIL: required doc missing: README.md` (the README lives in the namespace dir, the repo root has none), `FAIL: pool branch 'pool/v2026.0/n99.…' has no matching [MERGE]`.
- **fix** check 1: match `[MERGE] pool/(prefix/)?nN\.[a-z&]+\.<short> into dev` by nN + short slug (the same rule claim-dev-merge.sh uses for dual-vault); check 3: allow `v[0-9]+\.[0-9]+\.0` seal tags and tags on `main`'s first-parent merges; check 4: parse `vYEAR.SERIES.DEV`, assert DEV runs 1..N without holes per SERIES; check 5: parametrize the required list or match the skill; check 6: diff `git ls-remote --tags origin` with `git show-ref --tags`.
- **test** `test_reconstruct_audit_structure_accepts_reconcile_landing` (fixture above, expect PASS), `…_accepts_seal_tag`, `…_detects_tag_gap` (tags v2026.0.1 and v2026.0.3 only → FAIL), `…_detects_tag_push_gap` (local tag absent on origin → FAIL).

### R5 · medium · `bin/reconstruct` loads its library from the cwd's repo, not from its own location
- **file:line** `bin/reconstruct:76-84`
- **evidence** VERIFIED. From a plain source repo (the natural cwd for `reconstruct identity <source-repo>`):
  ```
  bin/reconstruct: line 84: …/plain/.io.v4rian.how-git/scripts/reconstruct.sh: No such file or directory
  bin/reconstruct: line 91: reconstruct_identity: command not found
  rc=127
  ```
  Every other bin (`create-pool-branch:67-69`) resolves `SCRIPT_DIR` from `BASH_SOURCE`. The in-repo test only passes because it `cd`s into `TEMPLATE_ROOT` first (test comment at `test-lifecycle.sh` "resolves REPO_ROOT from cwd … so the scratch repo needs its own vendored copy").
- **fix** `SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$SCRIPT_DIR/../scripts/reconstruct.sh"`; drop the "not inside a git repo" exit (only `fast-forward` needs a repo, and it checks itself).
- **test** `test_reconstruct_bin_runs_from_any_cwd`: invoke by absolute path from a scratch repo without the namespace and from a non-repo directory, assert `identity` output.

### R6 · medium · `fast-forward` claims success on failure and writes the token into `.git/config`
- **file:line** `scripts/reconstruct.sh:17` (no `set -e`), `:361` (`https://x-access-token:$(gh auth token)@github.com/…` as remote URL), `:363-369` (unchecked pushes, then `echo "ok: fast-forwarded …"`)
- **evidence** VERIFIED by read (network path is untestable offline). Any failed `gh repo create` or `git push` still prints `ok:`; the token-bearing URL persists in `.git/config` whenever the function exits before `git remote remove throwaway2`.
- **fix** check each command's rc and return 1 with the failing branch; authenticate through `gh auth git-credential` (`git -c credential.helper='!gh auth git-credential' push https://github.com/…`) so no token touches the config; `trap 'git remote remove throwaway2 2>/dev/null' RETURN`.
- **test** stub `gh` and a `git` wrapper on PATH that fails `push` for one branch; assert non-zero rc, no `ok:` line, and `git remote` shows no `throwaway2`.

### R7 · medium · `fast-forward` drops safety anchors, vault refs and every claim tag
- **file:line** `scripts/reconstruct.sh:346` (`refs/heads/pool refs/heads/feature`), `:363-367`
- **evidence** VERIFIED by read: pushes `dev` plus `pool/*` and `feature/*` only; no `--tags`, no `safety/*`, no `vault/*`. The throwaway then fails the tool's own `audit-structure` check 2 (every merge needs a tag) and loses the anchors Git_Strategy.md:44 marks "Permanent".
- **fix** push `refs/heads/dev`, `refs/heads/pool/*`, `refs/heads/safety/*`, `refs/heads/vault/*` and `refs/tags/*` (explicit refspecs are fine; the "shell mangling" the skill warns about is an unquoted-variable bug, not a refspec limitation).
- **test** dry-run plan lists `safety/…`, `vault/…` and `tags` for a fixture that has them.

### R8 · medium · `verify-artifacts` discards the build output
- **file:line** `scripts/reconstruct.sh:402` (`bash -c "$cmd" >/dev/null 2>&1`)
- **evidence** VERIFIED. Manifest command `echo DIAGNOSTIC-LINE >&2; false` → output shows only `✗ m FAILED`; the diagnostic never appears. Contradicts pool/n89 ("scripts print every failure, no silent stderr suppression").
- **fix** `bash -c "$cmd" >"$log" 2>&1 || { tail -40 "$log"; … }`.
- **test** assert the diagnostic line is present in the tool's output on failure.

### R9 · medium · claude subcommands merge stderr into the one-line contract and never validate it
- **file:line** `scripts/reconstruct.sh:463, 497, 533` (`claude -p "$prompt" </dev/null 2>&1`)
- **evidence** VERIFIED by read. The documented contract is "EXACTLY one line" (`RENAME:|QUESTION:`, `REUSABLE|EXCLUDE:`, `LEAK:|NOT-A-LEAK:`); any CLI warning or multi-line answer is passed through untouched and the function returns 0.
- **fix** capture stdout only, `grep -E '^(RENAME|QUESTION): '` on the last non-empty line, return 1 with the raw output on stderr otherwise.
- **test** stub `claude` printing a warning line then the answer → tool prints only the answer; stub printing prose → rc 1.

### R10 · medium · `identity` reads HEAD's history only
- **file:line** `scripts/reconstruct.sh:33` (`git -C "$source_repo" log --format='%an <%ae>'`)
- **evidence** VERIFIED by read; SKILL Step 2 promises "every distinct real git author identity". Authors present only on unmerged branches of the source are invisible, and the replay later attributes their commits (Non-negotiable 3) from an incomplete list.
- **fix** `git log --all --format='%an <%ae>%n%cn <%ce>' | sort -u` (committers matter for replay too).
- **test** fixture with a third author on an unmerged branch, assert three identities.

### R11 · medium · skill prescribes `git push --force`, `reset --hard` and `branch -D` with no preflight
- **file:line** `skills/git-reconstruct/SKILL.md:187` ("as a full rewrite (`git push --force` after a safety-branch snapshot …)"), `:294-299` (`git reset --hard`, `git branch -D tip-save`)
- **evidence** VERIFIED by read. Joel's banned list forbids `git push --force` without `--with-lease` on pushed refs; `~/.claude/hooks/guard-destructive.sh` denies `reset --hard` / `branch -D` until `git-preflight.sh` ran; `git branch -D tip-save` deletes the only pointer to the old tip right after the cherry-pick, before any audit confirms the result. `git-history-preservation` (SKILL.md:73) lists force-push over a ref holding user commits as a rewrite.
- **fix** Step 10: `--force-with-lease=<ref>:<expected>` after `git-preflight.sh <repo> "<reason>"`; closing section: run the preflight first, keep `tip-save` until Steps 5/8/9 pass, delete it in the delivery step.
- **test** n/a (prose); `test_consolidated_skills_are_repo_agnostic` could additionally grep the skill tree for `push --force[^-]` and `branch -D`.

### R12 · low · token waste and internal contradictions in the skill text
- **file:line** `skills/git-reconstruct/SKILL.md:3` (158-word description, loaded in every session), `:75-77` (inline `git log` duplicating `reconstruct identity`), `:133-145` (12-line shell block duplicating `reconstruct fast-forward`, writes `/tmp/branches.txt`), `:155-160` (six-item list duplicating `audit-structure`), `:50` ("fast-forward/no-PR direct merges" vs `:282` "`--no-ff` merges into dev"), `:249` ("the graft technique in Step 7/11": neither step describes a graft), total 6824 words.
- **evidence** VERIFIED by read and `wc -w`.
- **fix** description to one sentence (~35 words); replace each duplicated mechanic with the subcommand name and keep only the rule the tool does not enforce; resolve the ff/no-ff sentence; point Step 16 at the actual graft recipe or add it.
- **test** `test_skill_descriptions_are_short` (≤ 60 words) in the consolidated-skills group.

### R13 · low · commit lens violations on 983ca80
- **file:line** commit 983ca80 (author `waylon <waylon@sessionpass.io>`)
- **evidence** VERIFIED by read. One commit bundles the skill copy, the tool, sixteen tests, README, RUNBOOK and CHANGELOG (git-commit-audit rule 1: ≥2 concepts → split); body carries a `Changes:` header (rule 13); hyphenated English compounds in body ("workspace-specific", "rename-only", "fail-fast", "multi-source", "in-repo") (rule 15); bullet "reconstruct + scripts/reconstruct.sh" leads with a path and a joiner (V.1, rule 2); author is the sessionpass identity in a v4rian-io repo (feedback_commit_identity_by_repo_org) and lacks the `(Model)` suffix (how-dev).
- **fix** re-cut as three commits on the allocated pool branch: `[NEW] Add the git-reconstruct skill to the namespace`, `[NEW] Add the bin/reconstruct tool with lifecycle tests`, `[DOCS] Register bin/reconstruct in the README, RUNBOOK and CHANGELOG`, authored `v4rian-waylon (<Model>) <v4rian-waylon@users.noreply.github.com>`.
- **test** `./bin/smart-commit` / commit-audit lens on the re-cut branch.

### R14 · low · aa1a68c on `landing-base` / `dev-landing` is unusable on its base
- **file:line** `scripts/_lib.sh` at 58ea397 (no `resolve_skill`); `scripts/reconstruct.sh:455, 489, 525` call it
- **evidence** VERIFIED: `type resolve_skill` → `not found` at aa1a68c; `reconstruct infer-rename Mixer cat.json` with a stub `claude` → `reconstruct.sh: line 455: resolve_skill: command not found` (then the stub's answer, because of the missing `set -e`). At 983ca80: `resolve_skill is a function`.
- **fix** discard `landing-base` / `dev-landing`; land from 983ca80 after an allocation (`bin/create-pool-branch reconstruct-tool --no-jira --kind feature`).
- **test** the existing reconstruct tests pass on both bases only because every claude path runs in `LIFECYCLE_TEST_MODE=1`; add one non-test-mode assertion with a stub `claude` on PATH so a missing helper fails the suite.

### R15 · low · `audit-structure` failure count wraps modulo 256
- **file:line** `scripts/reconstruct.sh:221` (`exit "$failures"` inside the subshell), mirrored by R3's `exit "$hits"` at `:258`
- **evidence** VERIFIED for the identical pattern in `scrub` (256 hits → rc 0); same construct.
- **fix** `exit $(( failures > 0 ))`, print the count in the summary line.
- **test** fixture with 256 orphan pool branches → rc 1.

### R16 · low · `relocate` tag materialisation is a no-op
- **file:line** `scripts/reconstruct.sh:301` (`git tag -f "$t" "refs/tags/$t"`)
- **evidence** VERIFIED: annotated `v1` before `412db80…` type `tag`, after `412db80…` type `tag`. Tags fetched by a clone are already local refs; the loop re-points each tag at itself. The comment claims it "materializes every remote branch and tag".
- **fix** delete the loop, or when the intent is "fetch tags the clone skipped": `git fetch origin 'refs/tags/*:refs/tags/*'`.
- **test** n/a after deletion.

---

## Pre-existing observations (not introduced by either branch, relevant to landing)

- The counter was never globally unique in this repository: `pool/n67.…` vs `pool/v2026.0/n67.…` (flat → prefixed transition) and two different `n96` branches under `v2026.0` already exist (`git for-each-ref refs/heads/pool/** | grep -oE 'n[0-9]+\.' | sort | uniq -d`). The connected allocator runs under `concurrency: group: allocate-pool-branch` (workflow:67-69), so the n96 pair came from another path; the vault/history scans in n165 make both shapes count for future allocations.
- `docs/RUNBOOK.md:30` already documented off-grid allocation as "connected-only" before n165; the row is wrong today and stays wrong after the branch.
