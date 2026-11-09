# Re-audit: local/hook-correctness r2 (17 commits 5ac4a10..66b0157, fixes for HC-01..HC-11)

Auditor: Fable 5.1, read-only, 2026-10-29. Worktrees `$TMPDIR/aud-hc2` (tip 66b0157), `$TMPDIR/aud-hc2m` (tip + `git merge local/n165-fixes`, abandoned), `$TMPDIR/aud-hc2-5ac` (5ac4a10 reference), 16 short-lived `aud-disc-*` (one per TEST/FIX commit); all removed. Paths relative to `.io.v4rian.how-git/` at 66b0157. bash 3.2.57 only on this machine.

## Suites (VERIFIED)
- `framework-tests/test-hooks.sh`: 62 passed, 0 failed.
- `framework-tests/test-lifecycle.sh`: 424 passed, 0 failed (417 at 5ac4a10, +8 `test_hc_hc*`, -1 retired `test_hc_r13_*`).
- Discrimination: each of the 8 new tests run with `--filter` at its own TEST commit (fix absent) and at the following FIX commit: 8/8 fail 0/1 at TEST, 8/8 pass 1/0 at FIX (6557388→6a71a49, 8898b01→2cf692f, 08da287→10b844b, cb828f2→0dbce6e, 4fccc75→cdbebf6, 85a0d0d→aac4a5e, 6282d84→318838d, a45b1e9→33837e6).

## HC findings: closure status
| HC | Status | Receipt |
|---|---|---|
| HC-01 lane merging dev loses its requirement | CLOSED | per-lane file `requirements/<pool__ref>`; probe: lane that merged dev resolves its own text; driver + `.gitattributes` removed |
| HC-02 forge-side add/add conflict | CLOSED | test merges two lanes in a fresh clone with no driver, rc=0 |
| HC-03 `[REQ]`/`[MERGE]` bypass | CLOSED (new false positive, R2-01) | `hg_message_scope` gone; honest one-parent `[MERGE]`/`[REQ]` rule breaks refused in commit-msg and pre-push |
| HC-04 URL / fresh-remote push refused | CLOSED (exclusion too wide, R2-03) | by-URL push over legacy "plus" dev history rc=0 |
| HC-05 configured banned words | CLOSED | `AUTO_FIX_BANNED_WORDS=plus,utilize` refuses "utilize" |
| HC-06 `#` lines hidden | CLOSED | pre-push judges the stored message whole; commit-msg strips by `core.commentChar` only |
| HC-07 partial userinfo | CLOSED | table below |
| HC-08 doctor prints credentialed source | CLOSED | `spec_source_shown` on every line (`bin/doctor:106,120,123`) |
| HC-09 case / LICENSE / fences | CLOSED (edge cases R2-11) | `NOTES.MD`, `LICENSE` scrubbed; fenced `[--]` kept; gate skips fenced added lines via `-U0` hunks |
| HC-10 kind alternation copies | CLOSED | both tools use `^(${HG_BRANCH_KINDS})$`; works under bash 3.2 with `&` |
| HC-11 attach fetches into source | CLOSED | `hg_source_tree_at` throwaway bare repo; test asserts no FETCH_HEAD/objects in the source |

Credential strip table (VERIFIED, `hg_strip_url_credentials`, `_lib.sh:1176`): `https://user:p@ss@github.com/o/r.git`→`https://github.com/o/r.git`; `x-access-token:ghp_…@`→stripped; `HTTPS://tok@`→stripped; `https://user:pw@[::1]:8443/o/r`→`https://[::1]:8443/o/r`; `https://user:pw@host`→`https://host`; `https://host/o/r@v1` unchanged; `file:///Users/a@b/repo` unchanged; `ssh://u:pw@host:2222/o/r`→`ssh://u@host:2222/o/r`; `git+ssh://u:pw@h/r`→`git+ssh://u@h/r`; `git@github.com:o/r.git`, `/local/path`, `""` unchanged. Only oddities: `https://user:p/w@host/o/r` unchanged (unencoded `/` in a password is not a URL git treats as credentials either; `hg_has_credentials` misses it too) and `https://host?x=a@b`→`https://b` (no `/` after the authority; not a git URL shape). No action.

## New findings

### R2-01 [MEDIUM] Ref names and JIRA keys carrying a banned word are refused or silently rewritten in `[MERGE]`/`[REQ]` subjects
- `scripts/_lib.sh:1018` (`hg_message_violations`, `grep -qiwF`), `:1050` (`hg_scrub_message_file`, `\bword\b` → "and" on every non-`#` line, subject included), `scripts/allocate-pool-branch.sh:564`, `githooks/prepare-commit-msg:83`.
- Evidence VERIFIED (scratch repo, off-grid allocator): `--jira PLUS-12 --short-name add-plus-operator` creates `pool/v2026.0/n1.fix.PLUS-12-add-plus-operator` whose `[REQ]` subject is stored as `[REQ] active-requirement: pool/v2026.0/n1.fix.and-12-add-and-operator` (body "Add the and operator."; file verbatim). `git merge --no-ff -m "[MERGE] <lane> into dev: v2026.0.1"` with hooks on: `X Commit message breaks the message rules: the banned word "plus"`. Same subject through `git commit -F` (how claim/finalize amend): stored subject `[MERGE] pool/v2026.0/n1.fix.and-12-add-and-operator into dev: v2026.0.1`, two parents. At 5ac4a10 `[MERGE]` was dashes-only, so this is new surface opened by the HC-03 fix. The landing subject is machine-parsed (`claim-dev-merge.sh:168` `MERGED_POOL`, the n165 allocator's landing-subject counter, vault/archive names), so the ref token in history is corrupted silently; the honest form cannot be committed.
- Fix: mask ref-shaped and key-shaped tokens before judging or scrubbing, in both functions from one helper: anything matching `(pool|safety|vault)/[^[:space:]]+` or `[A-Z]+-[0-9]+` is treated like a backtick span (removed before the word check, restored after the scrub). Keep prose "plus" refused.
- Test: extend `test_hc_hc03_*`: allocate `--jira PLUS-1 --short-name add-plus-operator`; assert the `[REQ]` subject names the real ref; `git merge -m "[MERGE] <lane> into dev: v0.0.1"` passes commit-msg; a body line "one plus two" is still refused.

### R2-02 [MEDIUM] Legacy lanes carrying the shared `active-requirement` collide again on dev merge
- The driver and `.gitattributes` are removed (`heal.sh`, `_lib.sh ensure_merge_drivers`); `get-active-requirement.sh:130` only covers reading.
- Evidence VERIFIED: two lanes each adding `.io.v4rian.how-git/active-requirement` merged into dev: tip rc=1, unmerged `.io.v4rian.how-git/active-requirement`; 5ac4a10 with heal.sh rc=0. neo-git itself carries the file on no ref (0 of 679 refs), so the framework repo is unaffected; 10 consumer checkouts under local_stage carry it in their namespace (native-ui-beta, iris, foundry.wa, native-base, swarm, abstraklib, helpen.portal-audit, neo-whisper-throwaway, offgrid_QS_AB_GR_upgrade, neo_QS_AB_GR_upgrade), so their in-flight legacy lanes conflict after a sync (off-grid only; forge merges conflicted before too, HC-02).
- Fix: a migration in the merge tools rather than a driver: when `claim-dev-merge`/`finalize-pool-merge` (and a hand `git merge` through `post-merge`) meet a conflict on exactly `.io.v4rian.how-git/active-requirement`, resolve by deleting the path on dev (it is litter under the per-lane layout) and say so in the merge body; `sync-framework` adds a note that legacy lanes keep their file and resolve once. Or document R13 as closed for lanes allocated from this version on and keep the ledger item open for legacy lanes.
- Test: two legacy lanes + one per-lane lane into dev through the claim path, all three land, dev ends with no `active-requirement`.

### R2-03 [MEDIUM] pre-push excludes far more than "what the destination has": local tags, every remote-tracking ref, local main/dev
- `githooks/pre-push:75-89`: `--not --remotes --tags $known_tips $old_tip` plus `refs/heads/main|dev`.
- Evidence VERIFIED (scratch, lane with one `--no-verify` "plus" commit): plain push: 1 refusal. `git tag scratch HEAD` then push: 0 refusals, remote has the lane. `git update-ref refs/remotes/origin/forged HEAD` then push: 0 refusals, published. Bad commit made on local dev (`--no-verify`), dev merged into the lane, lane pushed: only the lane's own bad commit is listed, the dev one passes (at 5ac4a10 with a known remote ref the range was `local ^remote_sha`, which judged both). HC-04 is fixed, but the fix is wider than its item: a forged local ref now hides a commit even when the destination ref is known.
- Fix: exclude only destination facts: `$known_tips` (ls-remote tips present locally) and `$old_tip`; bound legacy history with the fork point instead of local branches (`git merge-base $local_sha refs/heads/dev` and `... refs/heads/main`, when they exist), which still passes HC-04 (legacy commits predate every fork point) and judges dev commits merged after the fork; drop `--tags`; use `--remotes=<name>` only when `$1` is a remote name and ls-remote failed (offline).
- Test: extend `test_hc_hc04_*` with the three bypasses above, each refused, and keep the by-URL legacy case passing.

### R2-04 [MEDIUM] Merge with `local/n165-fixes`: one textual conflict whose obvious resolution silently disables two gates
- Both branches edit `githooks/pre-push`; `git merge local/n165-fixes` on the tip conflicts in exactly one hunk (lines 22-47 of the merged file): n165 inserts a stdin-draining `while read` loop refusing `refs/how-git/*` before `branch=$(git rev-parse --abbrev-ref HEAD)`, hook-correctness replaced that whole region (`_lib.sh` sourcing, per-ref loop). `scripts/allocate-pool-branch.sh` (n165 hunks at 6, 18, 101, 123, 137, 232, 239, 365, 415, 494 vs hook-correctness at 104, 331, 350, 552-641), `framework-tests/test-lifecycle.sh`, README and RUNBOOK automerge; n165 adds no `hg_*`/`HG_*` names, so sourcing `_lib.sh` at allocator start is safe.
- Evidence VERIFIED on the merged tree: resolution A (keep both blocks, n165 loop first): `R12 pre-push`, `HC-03`, `HC-04` each 0 passed 1 failed (the first loop consumes stdin, `saw_ref` stays false, no ref name or message is judged), `allocator reservations: pre-push refuses refs/how-git` 1 passed. Resolution B (fold the `refs/how-git/*` case into the single ref loop right after `saw_ref=true`, skipping `(delete)`): R12, HC-03, HC-04, the reservation test, HC-01/02, HC-10 and the 16 `allocator off-grid` tests all pass.
- Recommendation: land hook-correctness first; n165 rebases or merges and resolves pre-push per B; run the full lifecycle suite on the result (automerge of the test file is textual only).

### R2-05 [LOW] known_tips loop spawns one `git cat-file -e` per advertised ref
- `githooks/pre-push:76-78`. VERIFIED: 822 refs advertised by neo-git itself → 9.5 s wall per lane push before the push starts; the same set through one `git cat-file --batch-check='%(objectname)'` → 0.16 s. Fix: pipe `ls-remote | awk '{print $1"^{commit}"}' | sort -u` into one `--batch-check`, drop lines ending in `missing`.

### R2-06 [LOW] Requirement text differs by how the lane is named
- `scripts/get-active-requirement.sh:72-77` keys source 1 on `--symbolic-full-name`; a SHA or a detached HEAD yields no name, so source 2 (the scrubbed `[REQ]` body) answers. VERIFIED: by name / `HEAD` on the lane / `origin/<lane>`: `Verbatim-text plus more.`; by SHA and from a detached HEAD: `Verbatim-text and more.`. CI checkouts and `smart-commit` on a detached HEAD get the scrubbed copy; the RUNBOOK calls the two sources equivalent.
- Fix: when no name resolves, take the path the `[REQ]` commit added under `requirements/` (`git diff-tree --no-commit-id --name-only -r <req-sha>`) and read it at `$BRANCH`. Test: by-SHA equals by-name.

### R2-07 [LOW] Per-lane files accumulate on dev and main forever
- VERIFIED: after a lane merges, dev carries `.io.v4rian.how-git/requirements/pool__v2026.0__n1.feature.probe`; no script or bin tool removes lane files (`grep -l requirements scripts/*.sh bin/*`: only `_lib.sh`, `allocate-pool-branch.sh`, `attach.sh`, `sync-framework.sh`). attach and sync exclude the tree for consumers, so the litter stays inside the framework and each consumer's own history. Fix: `finalize-pool-merge`/`claim-dev-merge` delete the merged lane's file in the merge commit (or the vault step does). Test: after a claim, `git ls-tree dev .io.v4rian.how-git/requirements` is empty.

### R2-08 [LOW] Banned-word false positives beyond ref names; gate and scrub parse the list differently
- VERIFIED refused: "Handles plus-sized payloads", "Adds Google Plus login", "Links https://example.com/plus/api", "Edits src/plus.c and docs", "Covers PLUS-12 in JIRA". Passed: "surplus", "C++", `` `plus` ``. With `AUTO_FIX_BANNED_WORDS="plus,as well as"`: gate rc=0 (`tr -d '[:space:]'` turns the entry into `aswellas`, `_lib.sh:1033`), scrub rewrites "This as well as that." → "This and that.". `hg_scrub_message_file` and the auto-fix (`lib/auto-fix-commit-message.sh:196-198`) replace every configured word with "and" ("utilize" → "and").
- Fix: one list parser (`strip()` only) shared by gate and scrub; treat `/`- and `-`-joined compounds and URL/path tokens as code; replacement word per entry (`word=replacement`) or refuse without rewriting for non-default words.

### R2-09 [LOW] Commit body of 0dbce6e is untruthful: "AUTO_FIX_BANNED_WORDS (default and)"
- VERIFIED `git log -1 --format=%b 0dbce6e`; the auto-fix rewrote the author's "(default plus)". Live instance of R2-08: the banned word cannot be named in a message without backticks. Fix: reword to "(default `plus`)" before merge (Claude-authored commit, not Joel's).

### R2-10 [LOW] Documentation drift and one false claim
- `REQUIREMENTS.md:102` (HG-R052) and `:354` (HG-R229) still describe the shared `active-requirement` file; `scripts/auto-rebase-pools-after-dev-merge.sh:560` `REQ_HEADER` prompt text says "+ .io.v4rian.how-git/active-requirement file"; `bin/smart-commit:50`, `bin/create-pool-branch:55` comments likewise.
- `githooks/README.md:27-28`: message wording is checked by "these hooks and the CI commit-audit"; `scripts/audits/commit-audit.sh` has no message-rule check (`grep -rl hg_message_violations scripts/audits .github/workflows scripts/workflows`: none), so `--no-verify` and web-UI commits meet no message gate at all. Fix: add `hg_message_violations` over the push range to `commit-audit.sh` (then the sentence is true), or correct the sentence.

### R2-11 [LOW] Fence detection toggles on non-fences
- `_lib.sh:1106-1140` (`hg_dash_fenced_lines`, `hg_scrub_prose_file`): `^\s*(```|~~~)`. VERIFIED: a `~~~` fence is closed by ``` (CommonMark requires the same character), and a 4-space-indented ``` (an indented code block, not a fence) toggles the state, leaving the rest of the file "inside" so later prose dashes are neither scrubbed nor flagged by the gate. Fix: remember fence char and length, close only on a matching fence, require at most 3 leading spaces.

## Checked and clean
- Allocator sourcing `_lib.sh` under `set -euo pipefail`: top level is constants only (`_lib.sh:965-971,1156`); `[[ =~ ^(${HG_BRANCH_KINDS})$ ]]` accepts `r&d`, refuses `chore`, under bash 3.2.
- `hg_requirement_path`: `pool/v2026.0/n3.r&d.PROJ-1-x` → `requirements/pool__v2026.0__n3.r&d.PROJ-1-x`; `refs/heads/` stripped; the branch regex forbids `_` in short names and allows no character a path or JSON string cannot carry, so keys cannot collide; `get-active-requirement.sh` normalises `refs/remotes/<remote>/` before keying. Case-insensitive file systems: `n` is unique per lane, so no two live lanes map to case-variant paths.
- `[REQ]` plumbing commit: scrubbed message, verbatim file, lane pushes through pre-push (test HC-03); legacy lane with only the old file still resolves (test HC-01).
- `hg_source_tree_at`: `<sha>^{tree}:<path>` resolves in the throwaway repo; attach degrades to "local SHA" when the source refuses the SHA want; source checkout gains nothing (test HC-11).
- commit-msg `strip-comments` honours `core.commentChar` (`auto`/empty → `#`); pre-push judges `%B` whole; scissors block always dropped.
- Commit hygiene: 17 commits, each TEST before its FIX, titles `[TAG] Imperative` ≤69 chars, author and committer `v4rian-waylon (Opus) <v4rian-waylon@users.noreply.github.com>`, no trailers, no dashes; bodies match the diffs except R2-09; one `[DOCS]` commit touches README.
- Data loss: no new deletion path outside `mktemp -d` probes and the attach target's fresh copy (`rm -rf "$TGT_ROOT/$NS_DIR/requirements"` on a tree just copied).
- Enforcement weakened: only R2-03 (and R2-01's scrub turning refusal into silent rewrite).

## Verdict
FIX-THEN-MERGE. R2-01 and R2-03 are small, local fixes with clear tests and should land on this branch; R2-04 is a merge-order instruction for `local/n165-fixes` (resolution B, then the full suite); R2-02 needs a decision (merge-tool migration or ledger item kept open for legacy lanes) but does not block neo-git itself, which carries the legacy file on no ref. R2-05 to R2-11 can ride the same branch or a follow-up pool.
