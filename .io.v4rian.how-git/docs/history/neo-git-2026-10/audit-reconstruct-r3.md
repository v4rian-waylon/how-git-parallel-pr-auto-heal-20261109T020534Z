# neo-git audit r3: `local/reconstruct` 7067d7d..f0bafe6 (2026-10-29)

Scope: the 6 commits that answer audit-reconstruct-r2.md B1 to B9 (7760bf4 TEST, 01b0d3d, 8f4d0fe, 5b9036b, 15def95 FIX, f0bafe6 DOCS; branch now 33 commits on dev 5028b58). The brief named `2f6de51..tip`; 2f6de51 is a dangling sibling of 7760bf4 (same parent 7067d7d, same title), so the audited range is 7067d7d..f0bafe6. Method: read-only on `<workspace>/neo-git`; execution in detached worktrees `$TMPDIR/aud-r3` (tip), `aud-r3-test` (7760bf4) and four mutants `aud-r3-mut{a,b,c,d}` (tip with one fix reverted each), all removed afterwards; `git worktree list` holds no `aud-r3*` and `git status` of neo-git is clean. Probe script `<scratchpad>/probe-r3.sh` (log `$TMPDIR/probe-r3.log`), fixtures under `$TMPDIR/aud-r3-probe/`. The pinned git-filter-repo v2.47.0 was fetched for the real relocations: sha256 `67447413e273fc…7d94` = `RECONSTRUCT_FILTER_REPO_SHA256` (VERIFIED). Hook probes ran copies of the machine's `~/.claude/hooks/git-preflight.sh` and `guard-destructive.sh` with their default bak and mirror directories sed-moved into the fixture, so nothing reached `local_stage/baks`, `shuttle.o` or a real remote. Shell: /bin/bash 3.2.57; bash 5 UNVERIFIED (none on this machine). Paths relative to `.io.v4rian.how-git/`, line numbers at f0bafe6.

## Suites and commit claims

| where | result | claimed |
|---|---|---|
| tip `test-hooks.sh` | 60 passed, 0 failed | 60 of 60 (f0bafe6) |
| tip `test-lifecycle.sh` full | **465 passed, 1 failed** (`version math across release cycles`: expected `v2026.1.3`, got `v2026.0.5`); rc 1 | 466 of 466 (f0bafe6) |
| tip `--filter "version math"` alone | 3 passed, 0 failed | |
| dev `--filter "version math"` alone | 3 passed, 0 failed | |
| 7760bf4 `--filter reconstruct` | 54 passed, 7 failed: `relocate aborts on a refused preflight push`, `preflight delegates to the machine hook`, `preflight lands where the guard looks`, `relocate rejects extra arguments`, `relocate notes tags on non-commits`, `identity includes a detached HEAD`, `scrub ignores case, rejects blank terms` | 54 pass, 7 fail (7760bf4) |
| `run_test "reconstruct` lines | 60 | CHANGELOG "60 reconstruct tests" |

The one full-run failure: 11 `test-lifecycle.sh` processes were running on the machine at the time (`ps`), the test passes alone at the tip and on dev, and `git diff --stat dev local/reconstruct` touches only README, RUNBOOK, CHANGELOG, `bin/reconstruct`, `scripts/reconstruct.sh`, the reconstruct skill and the lifecycle suite (no version tooling). Not a regression of this branch; cause UNVERIFIED (B10 class: concurrent suites on one machine). The "466 of 466" claim holds in isolation only.

Commit hygiene (VERIFIED): identity `v4rian-waylon (Opus) <v4rian-waylon@users.noreply.github.com>` on all 6, no trailer, no em or en dash, titles 47 to 69 chars, each commit's file list matches its body (TEST touches only the suite; the three code FIXes touch only `reconstruct.sh`, 8f4d0fe also the stub it names; DOCS touches `bin/reconstruct`, CHANGELOG, SKILL.md). Bodies are truthful: 8f4d0fe's "real filter-repo relocated a repo with a tree tag and an annotated tag to rc 0" reproduced (P6).

## B1 to B9: closed at the tip

| id | status | receipt |
|---|---|---|
| B1 hook delegation | closed, residuals C3, C4 | copies of the real hook pair with defaults moved: `preflight` via hook → `preflight-bak-2026-10-29/01` pushed to the fixture origin, zip in the hook's dir, bundle beside it; guard on `git reset --hard HEAD` with no `BAKS_DIR` anywhere → allow (P5, P12, suite `lands where the guard looks`, which FAILS at 7760bf4 on this machine) |
| B2 GIT_DIR preflight test discriminates | closed | mutant A (line 24 `unset GIT_*` deleted): `preflight ignores an inherited GIT_DIR` FAIL, 60/1; hook path with `GIT_DIR=victim/.git` → ref in `work`, none in `victim` (P12) |
| B3 `--allow-unpushed` warning | closed, test gap C2 | built-in and hook path both print `! reconstruct preflight: no off-machine copy of <repo>; the backup ref exists locally only` on stderr (P2); mutant C (hook-path line removed) still 61/61 |
| B4 relocate arg count | closed | `relocate work cpp ""` → rc 2, no preflight ref; `relocate work cpp --force` rc 2; `relocate work ""` and `relocate "" cpp` rc 2 (P7, P7b) |
| B5 non-commit tags | closed, test gap C1 | real filter-repo: lightweight tag on tree, tag on blob, annotated tag on commit, annotated tag on tree, empty root branch, untracked file, preflight-bak branch → rc 0, three `note: … points at a tree/blob` lines, every branch and `anntag^{commit}` tree = `cpp` alone, tags 4 → 4; second relocate into `js/` rc 0 with `dev` tree `js/cpp` (P6, P6b, P14) |
| B6 detached HEAD identity | closed | `Alpha`, `Beta` listed on a detached checkout; unborn orphan HEAD, bare clone and empty repo rc 0 (P8) |
| B7 scrub case | closed, residual C6 pre-existing | `zulu` hits file, path `Zulu-Dir/f`, pickaxe, ref `Codename-ZULU`, identity `ZuLu Dev` (P9); `zülu` vs `ZÜLU` hits file, pickaxe, commit, ref and identity (P9, P9b); tab-only term rc 2; mutant B (`-i` dropped from `-S` only) → scrub test FAIL 60/1 |
| B8 `--help` | closed | relocate entry lists the two-argument contract, the four refusals and the per-ref tree check; matches `reconstruct.sh:565-580` |
| B9 env-dependent test | closed | `lands where the guard looks` says so in its comment and prints `note: … not checked here` when the hooks or jq are absent |

## The hook question (brief)

Which repos the tool preflights: the working clone before `relocate` (SKILL Step 11), the destination clone before the lease push (Step 10, SKILL.md:159) and `.` for an in-place fix (SKILL.md:228). All three are this reconstruction's own clones whose origin is the throwaway or the destination; the originals go through `git-snapshot-preflight`, never through `bin/reconstruct preflight` (SKILL.md:55-56, VERIFIED by read). A `preflight-bak-<day>/NN` branch on that origin is the how-preflight convention the guard checks for (`guard-destructive.sh` reads `refs/remotes/` when origin exists), the template's `rulesets/pool-creations.json` restricts creation of `refs/heads/pool/*` only, `fast-forward` ships dev, main, pool, feature, safety, vault and tags (not preflight-bak) and `audit-structure` pairs pool branches only, so the ref neither blocks nor pollutes the protocol: expected and acceptable. Two caveats, both outside this branch: `skills/git-strategy-audit/SKILL.md:103` whitelists only the literal `preflight-bak-YYYY-MM-DD` shape while the hook (and now the tool) write `preflight-bak-YYYY-MM-DD/NN`; and `relocate` ends with filter-repo removing `origin` (P6 NOTICE), so the pushed ref survives only on the remote, which is the point.

No origin: the hook reports `local-only (no origin)`, the tool exits 0 without any warning (P1), the guard then accepts a local `preflight-bak-*` ref (`where="locally (repo has no origin)"`), consistent with the built-in path (P4b). Read-only origin (pre-receive refuses): the hook reports `PUSH FAILED (local-only, still at risk)`, the tool exits 1 with `X … origin refused the backup ref`, writes no bundle, `relocate` stops with `preflight failed; nothing was rewritten` and the stub filter-repo never ran (P2); the guard still denies `git reset --hard` (`no preflight-bak-* ref on origin within 12h`). With `--allow-unpushed` (standalone only; relocate never passes it, `reconstruct.sh:647`) rc 0, stderr warning, bundle written, guard still denies. Side effect of a refused run: the hook has already created the local `preflight-bak-<day>/NN` ref and the zip before the tool can judge the push, so each retry leaves another pair (01, 02, 03 in P2); cosmetic, same as the built-in path and the hook on its own.

## New findings

| severity | count |
|---|---|
| critical | 0 |
| high | 0 |
| medium | 0 |
| low | 7 (C6 pre-existing on dev) |

### C1 · low · the empty-tree half of "classify refs first" has no discriminating test
- **file:line** `reconstruct.sh:660-666` (`empty=1` recorded before filter-repo), test `test_reconstruct_relocate_notes_tags_on_non_commits`.
- **evidence** VERIFIED: mutant D (kind kept before the rewrite, `empty` read from `$old^{commit}` after it, as 7067d7d did) → `--filter reconstruct` 61 passed, 0 failed. Real filter-repo on a fixture whose `dev` tip is a non-root commit with an empty tree (`git rm a` then commit) plus branch `wiped` on it: tip rc 0; mutant D rc 1 `history not relocated under cpp/ for: refs/heads/dev refs/heads/preflight-bak-2026-10-29/01 refs/heads/wiped` (the old objects are pruned, `rev-parse` fails, the exemption never fires). The fix is real; the `points at a missing` assertion added in 8f4d0fe only guards the `kind` half (a root empty commit keeps its SHA, so the suite's fixtures never prune the old object).
- **fix** none in code. **test** fixture with a wipe commit on a branch and the moving stub (it prunes since 8f4d0fe); assert rc 0.

### C2 · low · the hook-path `--allow-unpushed` warning is untested
- **evidence** VERIFIED: mutant C (the `echo "! reconstruct preflight: no off-machine copy …"` inside `_reconstruct_preflight_via_hook` replaced by `:`) → 61 passed, 0 failed. `test_reconstruct_preflight_delegates_to_the_machine_hook` asserts rc 1 for `PUSH FAILED` without the flag and never runs the flag.
- **test** one more call in that test: `RECONSTRUCT_TEST_HOOK_PUSH="PUSH FAILED …" … preflight … --allow-unpushed` → rc 0, stderr has the `^! reconstruct preflight: no off-machine copy` line, bundle present.

### C3 · low · `HOME` unset crashes the preflight instead of falling back
- **file:line** `reconstruct.sh:437` (`local hook="${RECONSTRUCT_PREFLIGHT_HOOK-$HOME/.claude/hooks/git-preflight.sh}"` under `set -u`).
- **evidence** VERIFIED (P3): `env -u HOME -u RECONSTRUCT_PREFLIGHT_HOOK … preflight work` → `reconstruct.sh: line 437: HOME: unbound variable`, rc 1, no backup taken. `HOME=` (empty) falls back to the built-in path correctly (P3b). Daemons and some CI runners start without `HOME`.
- **fix** `${HOME:-}`; with an empty `HOME` the default resolves to a non-executable path and the built-in path runs. **test** `env -u HOME` → rc 0 and the built-in `preflight:` line.

### C4 · low · the bundle is not mirrored when the hook mirrors its zip by default
- **file:line** `reconstruct.sh:527-529` (`[ -n "${BAKS_MIRROR:-}" ] && [ -d "$BAKS_MIRROR" ]`); hook `MIRROR="${BAKS_MIRROR:-<workspace>/shuttle.o/baks}"`.
- **evidence** VERIFIED (P1/P11): hook defaults → `hookmirror/` holds `work-bak-….zip` only, `hookbaks/` holds zip and bundle. On <host> with no `BAKS_MIRROR` exported the zip reaches `shuttle.o/baks` and the bundle does not, so the shuttle copy lacks the refs (the bundle is the only backup that holds every ref after a rewrite).
- **fix** when the hook's output names the zip and `BAKS_MIRROR` is unset, copy the bundle next to the mirrored zip the hook made (`dirname` of the mirrored copy is not printed, so either parse the hook's `MIRROR` default or have the hook print its mirror path; the cheaper route is `cp -p "$bundle" "$(dirname "$zipf")/../"`-free: read `MIRROR=` from the hook file as `lands_where_the_guard_looks` already does for `BAKS=`). **test** stub hook that writes a mirror copy, assert the bundle lands beside it.

### C5 · low · the fallback-location note is untested
- **evidence** VERIFIED: `grep -n 'note: no how-preflight' framework-tests/test-lifecycle.sh` → no match; the note prints correctly (P4: `note: no how-preflight hook at <path>; backups are under <dir>, which a destructive-git guard accepts only when it reads the same directory (BAKS_DIR)`, P4b without ` at <path>` when the hook is disabled).
- **test** assert the `^note: no how-preflight hook` stderr line in `test_reconstruct_preflight_matches_the_guard_convention`.

### C6 · low, pre-existing on dev · the scrub path sweep is blind to non-ASCII paths
- **file:line** `reconstruct.sh:366` (`paths=$( { git ls-files; git log --all --format= --name-only; } …)`).
- **evidence** VERIFIED (P9b): path `ZÜLU-dir/f`, `scrub <repo> zülu` → `HIT (commit)`, `HIT (ref)`, `HIT (identity)`, no `HIT (path)`; `git log --name-only` and `git ls-files` print `"Z\303\234LU-dir/f"` (core.quotePath default), `git -c core.quotePath=false log …` prints `ZÜLU-dir/f`. The case fix in 15def95 is correct (the ASCII path `Zulu-Dir/f` hits for `zulu`); the gap is older than this branch and now the only sweep that misses a non-ASCII leak.
- **fix** `git -c core.quotePath=false` on both commands at `:366`. **test** fixture path with a non-ASCII letter, assert `HIT (path)`.

### C7 · low · CHANGELOG word count is stale
- **evidence** VERIFIED: `docs/CHANGELOG.md:7` says "down from 6824 to 3102 words"; `wc -w skills/git-reconstruct/SKILL.md` = 3102 at 327465d, 3151 at 7067d7d, 3151 at f0bafe6 (f0bafe6 edited the same sentence for "60 reconstruct tests" and left 3102).
- **fix** 3151, or drop the number.

## Enforcement and data loss
- No gate weakened. The hook path keeps every refusal the built-in path has (refused push → rc 1, relocate never reaches filter-repo, P2), `--allow-unpushed` stays standalone only and the guard still denies downstream destructive git without the origin ref. The hook is run only when executable; a hook that prints no `preflight:` line fails the preflight (P10, rc 1) rather than falling back silently.
- Relocate post-check VERIFIED with the real filter-repo on branches, commit tags, annotated tags, tree and blob tags, a tree annotated tag, an empty root, an untracked file and the preflight-bak branch itself (P6, P6b, P13 detached HEAD, P14 second run).
- Originals never touched: `identity`, `scrub` read-only; `preflight` runs only on the reconstruction's own clones (by skill text); VERIFIED by read.

## Verdict
MERGE. B1 to B9 are closed, every closure reproduced with the real hooks (copied, defaults relocated) and the real git-filter-repo; the three behaviour-changing fixes checked by mutation (A, B) discriminate, and the two that do not (C, D) are low test gaps on code that is correct. The one full-suite failure is a concurrent-run artefact outside this branch's files. C1 to C7 ride the next pool at the implementer's discretion; C6 is dev debt that the case fix made visible.
