# neo-git audit r2: `local/reconstruct` 327465d..7067d7d (2026-10-29)

Scope: the 8 commits that answer audit-reconstruct.md A1 to A13 (branch now 27 commits on dev 5028b58). Method: read-only on `<workspace>/neo-git`; execution in detached worktrees `$TMPDIR/aud-r2` (tip), `aud-r2-test` (327465d), `aud-r2-19461cd`, `aud-r2-0f517d1`, all removed afterwards. Probe script `<scratchpad>/probe-r2.sh` (log `$TMPDIR/probe-r2.log`). The pinned git-filter-repo v2.47.0 was fetched for real relocations: sha256 `67447413e273fc…7d94` = `RECONSTRUCT_FILTER_REPO_SHA256` (VERIFIED). Paths relative to `.io.v4rian.how-git/`, line numbers at 7067d7d. Shell: /bin/bash 3.2.57; no bash 5 on this machine, so bash 5 behaviour is UNVERIFIED.

## Suites and commit claims (all VERIFIED by run)

| where | result | claimed |
|---|---|---|
| tip `test-hooks.sh` | 60 passed, 0 failed, rc 0 | 60 of 60 (7067d7d) |
| tip `test-lifecycle.sh` | 459 passed, 0 failed, rc 0 | 459 of 459 (7067d7d) |
| 327465d `--filter reconstruct` | 41 passed, 13 failed; the 13 are exactly the new tests | 41 pass, 13 fail (327465d) |
| 19461cd `--filter reconstruct` | 43 / 11 | 43 pass, 11 red |
| 0f517d1 `--filter reconstruct` | 48 / 6 | 48 pass, 6 red |
| `run_test "reconstruct` lines | 53 | CHANGELOG "53 reconstruct tests" |
| neo-git `--clone … --no-default-docs --allow-gaps-before v2026.0.100` | 9 `note: tag sequence gap` lines, FAIL 58 (11 untagged merges + 47 unlanded pool refs, repo state not tool) | "nine historical holes print as notes" (4fd80a5) |

Identity `v4rian-waylon (Opus) <v4rian-waylon@users.noreply.github.com>` on all 8; no trailer, no em or en dash; bodies match the diffs. Nit: `4fd80a5` title is 73 chars (AGENT-BRIEF says 72 at most).

## A1 to A13: closed at the tip

| id | status | receipt |
|---|---|---|
| A1 zip name / bak dir vs guard | closed, residual B1 | `reconstruct preflight` → `work-bak-20261029T131213.zip`, ref `preflight-bak-2026-10-29/01` on `refs/remotes/origin/…`; `guard-destructive.sh` with `BAKS_DIR=<that dir>` on `git reset --hard HEAD` → allow (probe P1) |
| A2 inherited GIT_DIR | closed, test gap B2 | `GIT_DIR=victim/.git reconstruct preflight work` → ref lands in `work`, victim untouched (P4); relocate on a plain dir rc 2, no marker, no ref in victim (suite) |
| A3 no-op rewrite / linked worktree | closed, residual B5 | no-op stub → rc 1 `history not relocated under cpp/ for: refs/heads/dev …` (P2b, suite); linked worktree rc 2 before any preflight (suite); real filter-repo: `cpp/`, `lang/cpp`, `my dir` all rc 0 with every branch and tag tree = `<top>` alone; `./cpp` → filter-repo refuses, rc 1, refs unchanged (P5) |
| A4 dirty tracked files | closed | rc 1, marker absent, edit untouched (suite) |
| A5 refused preflight push | closed, loudness B3 | relocate rc 1 `preflight failed; nothing was rewritten`, no marker; standalone preflight rc 1 without, rc 0 with `--allow-unpushed`; relocate never passes the flag (`reconstruct.sh:602`), a third arg `--allow-unpushed` is ignored and relocate still stops (P2) |
| A6 ref names / identities | closed | `HIT (ref): refs/tags/codename-zulu-v1`, `HIT (ref): refs/heads/pool/n9…`, `HIT (identity): <sha>` rc 1 (suite) |
| A7 kind in the landing key | closed | unmerged `pool/n1.fix.thing` beside landed feature → FAIL naming it (suite); reverse pairing (branch `feature`, merge subject `reconcile`) → PASS (P8) |
| A8 scrub from a subdir / empty term | closed | `HIT (file): root.txt:1` from `<repo>/sub`; `""` → rc 2 (suite) |
| A9 argv overflow | closed | 1.2 MB file → rc 0 `REUSABLE`, prompt > 1.2 MB on the stub's stdin (suite). `claude -p </dev/null` prints `Input must be provided either through stdin or as a prompt argument when using --print` (stdin contract confirmed by the CLI itself; a live call was not possible: the nested CLI reports `Not logged in`) |
| A10 dash subdir | closed | `relocate work --help` rc 2, no preflight ref (suite) |
| A11 stash identity | closed, residual B6 | only `Author Alpha` listed (suite) |
| A12 relaxations | closed | `--no-default-docs`, `--allow-gaps-before` (suite; neo-git run above); bad tag name or missing value rc 2 (P8) |
| A13 docs | closed, residual B8 | README `how-push` gone; CHANGELOG 53; skill "written `reconstruct` below", "no remote CI" dropped |

## New findings

| severity | count |
|---|---|
| critical | 0 |
| high | 0 |
| medium | 3 (B1, B2, B10; B10 pre-existing on dev) |
| low | 7 |

### B1 · medium · the A1 fix holds only when the repo sits under `local_stage/` or `BAKS_DIR` is in the hook's environment
- **file:line** `scripts/reconstruct.sh:433` (`bak_dir="${RECONSTRUCT_BAK_DIR:-${BAKS_DIR:-$(dirname "$repo_abs")/baks}}"`); `~/.claude/hooks/guard-destructive.sh` (`BAKS="${BAKS_DIR:-<workspace>/baks}"`); `skills/git-reconstruct/SKILL.md:159, 228`; test `test_reconstruct_preflight_matches_the_guard_convention`.
- **evidence** VERIFIED (P1): fixture under `$TMPDIR`, no `BAKS_DIR` anywhere, `reconstruct preflight work "before reset"` rc 0, zip in `$TMPDIR/aud-r2-probe/p1/baks/`; guard with its defaults on `git reset --hard HEAD`: `Destructive git blocked (how-preflight): git reset --hard on …/p1/work with no work-bak-*.zip in <workspace>/baks within 12h`. Same command with `BAKS_DIR=…/p1/baks` → allow. The guard is a PreToolUse hook and reads Claude Code's environment, so a `BAKS_DIR=…` prefix on the skill's command line never reaches it; the test sets `BAKS_DIR` on both sides and cannot see the mismatch. For a repo at `<workspace>/<name>` the tool's default equals the hook's, so the skill works there and fails everywhere else (scratch repos, other workspaces).
- **fix** make `reconstruct preflight` delegate to `$HOME/.claude/hooks/git-preflight.sh <repo> "<reason>"` when that file is executable (names and places then match by construction) and add its bundle beside; keep the built-in path for machines without the hook. State in SKILL.md Step 10 and the local-fix recipe that the preflight must be the one the machine's destructive-git guard checks.
- **test** stub `git-preflight.sh` in a fake `$HOME` recording its argv; assert the tool calls it and still writes the bundle.

### B2 · medium · the GIT_DIR test does not discriminate the `unset GIT_*` line, and the live vector it guards (preflight) is untested
- **file:line** `scripts/reconstruct.sh:24`; `framework-tests/test-lifecycle.sh` `test_reconstruct_relocate_ignores_an_inherited_git_dir`.
- **evidence** VERIFIED (P4): copy of the tip tree with line 24 deleted → `--filter "inherited GIT_DIR"` still `1 passed, 0 failed` (the `.git` directory check at `:551` refuses `plain` first). On that copy `GIT_DIR=victim/.git reconstruct preflight work` rc 0 and `victim` gains `refs/heads/preflight-bak-2026-10-29/01` while the zip is of `work`: ref and archive of two different repositories, which is the data-loss shape A2 described. The tip refuses nothing here and does the right thing only because of the untested line.
- **fix** `test_reconstruct_preflight_ignores_an_inherited_git_dir`: `GIT_DIR=<victim>/.git reconstruct preflight <work>`; assert the ref is in `work`, none in `victim`, and the bundle lists `work`'s heads.

### B3 · low · `--allow-unpushed` is accepted quietly
- **evidence** VERIFIED (P2): stdout `preflight: … PUSH FAILED, local only (--allow-unpushed) …`, stderr only git's own rejection, rc 0. Under the guard a later `git push --force-with-lease` is still denied (`no preflight-bak-* ref on origin within 12h`), so the bypass is contained on <host> but not on a machine without the hook.
- **fix** print `! reconstruct preflight: no off-machine copy of <repo>; the backup ref exists locally only` on stderr whenever the flag is used; the skill never mentions the flag (keep it so).
- **test** assert the stderr line in the existing `--allow-unpushed` assertion.

### B4 · low · `relocate` ignores extra arguments
- **evidence** VERIFIED (P2b): `relocate work cpp totally-bogus-arg` ran the stub (rc 1 only because the stub relocates nothing). `reconstruct_relocate` reads `$1 $2` and never checks `$#`.
- **fix** `[ $# -eq 2 ] || usage rc 2`. **test** rc 2, no preflight ref.

### B5 · low · a tag on a non-commit object fails the post-rewrite check after a correct rewrite
- **file:line** `scripts/reconstruct.sh:631` (`rev-parse "$ref^{commit}"` failure → `(gone)`).
- **evidence** VERIFIED (P12, real filter-repo): `git tag treetag HEAD^{tree}` → every branch relocated (`dev` tree `cpp`), filter-repo keeps the tree tag unchanged, tool exits 1 `history not relocated under cpp/ for: refs/tags/treetag(gone)`. False failure, nothing lost.
- **fix** skip refs whose old object is not a commit (`git cat-file -t`), print them as `note:`. **test** that fixture, rc 0 with the note.

### B6 · low · `identity` misses a detached HEAD unreachable from any ref
- **evidence** VERIFIED (P7): commit by `Beta <beta@x>` on a detached HEAD → output `Alpha <alpha@x>` only. Source checkouts shipped as zips are often detached.
- **fix** `git log HEAD --branches --tags --remotes` (HEAD only when it resolves). **test** that fixture lists both.

### B7 · low · `scrub` is case-sensitive and accepts whitespace-only terms
- **evidence** VERIFIED (P6): content `Project ZULU internal`, `scrub <repo> zulu` → `hits: 0`, rc 0; `scrub <repo> " "` → `hits: 3`, rc 1.
- **fix** `-i` on `git grep`, `--regexp-ignore-case` on the two `git log` sweeps, `tolower()` in the awk identity sweep, case-insensitive ref grep; reject terms that are empty after trimming.

### B8 · low · `bin/reconstruct --help` is stale for `relocate`
- **evidence** `bin/reconstruct:50-54` still says "verifies branch/tag counts are unchanged" and lists neither the dirty-tree, linked-worktree, GIT_DIR and dash-subdir refusals nor the per-ref tree check that 0f517d1 added and that SKILL.md and CHANGELOG now describe; SKILL.md names `--help` as the argument reference.
- **fix** one paragraph in the same shape as the `preflight` entry.

### B9 · low · the guard-convention test is environment dependent
- `test_reconstruct_preflight_matches_the_guard_convention` runs the guard only when `~/.claude/hooks/guard-destructive.sh` and `jq` exist; elsewhere it silently asserts less. Acceptable (the convention itself is still asserted); note it in the test comment.

### B10 · medium, pre-existing on dev · the "one-off sed `process.c` crash" is a suite race on fixed `/tmp` paths; the sed abort is Apple's sed on NUL-filled output
- **what was seen** (transcript of the implementer's full run `lifecycle-full2.log`, 12:47Z): `claim-dev-merge dual-vault e2e … FAIL`, log begins `Assertion failed: (advance > 0), function substitute, file process.c, line 462.`, body `claim output did not announce dual-vault of the original branch`, then `test-lifecycle.sh: line 86: 5503 Abort trap: 6 sed 's/^/      /' "$log"`. Three single reruns passed.
- **root cause, VERIFIED**
  1. `test_claim_dev_merge_dual_vaults_original_e2e` (test-lifecycle.sh:4363) redirects the merge+claim output to the fixed path `/tmp/.n92-claim-out`, greps it and `rm -f`s it; the zero-match test uses `/tmp/.n92-zero-out`. The suite holds 9 such fixed paths, 33 uses (`/tmp/.n92-claim-out`, `.n92-zero-out`, `.short-msg`, `.good-msg`, `.merge-long`, `.merge-over`, `.req-long`, `.new-over`, `.auto-fix-msg`); everything else lives in `SCRATCH_BASE=$(mktemp -d …)`.
  2. Three full lifecycle runs overlapped on this machine when the failure happened: wt-spec-contradictions 12:46:19Z, wt-reconstruct 12:47:29Z (the failing one), wt-n165 12:52:49Z (tool_use timestamps across the session's subagent transcripts; at 13:04Z `ps` still showed 7 concurrent `test-lifecycle.sh`).
  3. Reproduction: two `--filter "dual-vault e2e"` runs started 0.7 s apart, 4 rounds → run B fails every round with the identical message `claim output did not announce dual-vault of the original branch` (run A's `rm -f` or truncation lands between B's redirect and B's grep). 4 of 4 rounds; a single run alone passes (5 s).
  4. The abort: two writers on one path with `>` leave a zero-filled hole (P11: 80 bytes, 39 NUL). `printf '\0\0\0abc\n' | sed 's/^/      /'` under `en_US.UTF-8` → `Assertion failed: (advance > 0), function substitute, file process.c, line 462`, rc 134. Apple's text_cmds `sed/process.c` computes `advance = mbtowc(&wc, s, slen)` after a zero-length match under `#ifdef __APPLE__` and asserts it is positive; `mbtowc` returns 0 on a NUL byte (invalid UTF-8 gives `RE error: illegal byte sequence` instead, also verified; `LC_ALL=C` passes both). So the crash is the harness's log printer (`run_test`, test-lifecycle.sh:103) choking on the clobbered file the failing test had `cat`ed into its log, after the FAIL was already recorded.
- **verdict** not flaky in isolation, not a bug in this branch's input, not a filter-repo matter: a race between concurrent suite runs over a shared `/tmp` file, with a genuine but cosmetic macOS sed defect on top. Pre-existing on dev (the branch does not touch these tests); every parallel audit or implementer running the suite on this machine can trip it.
- **fix** (own pool) replace the 9 fixed paths with `$SCRATCH_BASE/…`; harden `run_test` against binary logs (`LC_ALL=C sed 's/^/      /'` or `awk '{print "      " $0}'`). **test** two concurrent `--filter "dual-vault e2e"` runs both pass; `printf '\0x\n' > log` through the printer does not abort.

## Enforcement and data loss
- No gate weakened: every new refusal (dirty tree, worktree, GIT_DIR, dash subdir, refused push) exits before the preflight or before filter-repo; `--allow-unpushed` is reachable only from the standalone subcommand and the guard still denies downstream destructive git without the origin ref (P2). `relocate` with a refused origin: rc 1, filter-repo never ran (suite, P2).
- Post-rewrite check on every ref: VERIFIED on branches, lightweight and annotated tags with the real filter-repo (P5); false negative only on non-commit tags (B5).
- GIT_* sanitisation: covers the variables git exports to hooks (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`) plus `GIT_COMMON_DIR`, `GIT_NAMESPACE`; effective for `preflight` (P4), untested (B2).
- Originals never touched: `identity`, `scrub`, `gaps`, `audit-structure --clone` read-only; VERIFIED by read.

## Verdict
FIX-THEN-MERGE. No critical or high finding; A1 to A13 are closed with discriminating tests except the one line in B2. Before merge: B1 (route the preflight through the machine's `git-preflight.sh` when present, or document `BAKS_DIR` as mandatory outside `local_stage/`) and B2 (one failing test for the GIT_DIR preflight vector). B3 to B9 ride the same pool at the implementer's discretion. B10 is dev debt for its own `[FIX]` pool and explains the reported crash in full.
