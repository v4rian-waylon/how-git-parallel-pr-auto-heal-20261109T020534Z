# neo-git audit: `local/reconstruct` (2026-10-29)

Branch `local/reconstruct`, 19 commits 5365306..29205cb on dev 5028b58 (v2026.0.136). Diff `dev...local/reconstruct`: bin/reconstruct (+119), scripts/reconstruct.sh (+823), skills/git-reconstruct/SKILL.md (+236), test-lifecycle.sh (+807), README, RUNBOOK, CHANGELOG.

Method: read-only on `<workspace>/neo-git`; execution in detached worktrees `$TMPDIR/aud-recon` (tip) and `$TMPDIR/aud-recon-<sha>` (each `[TEST]` commit), all removed afterwards. Probe script: `<scratchpad>/probe-recon.sh` (results under `$TMPDIR/aud-recon-probe`). The pinned git-filter-repo v2.47.0 was fetched for real relocation runs: `shasum -a 256` = `67447413e273fc…7d94`, identical to `RECONSTRUCT_FILTER_REPO_SHA256` (VERIFIED). Paths relative to `.io.v4rian.how-git/` unless absolute; line numbers at 29205cb.

## Suites (worktree at 29205cb, /bin/bash 3.2.57)

- `framework-tests/test-hooks.sh`: 60 passed, 0 failed, rc 0 (VERIFIED).
- `framework-tests/test-lifecycle.sh`: 446 passed, 0 failed, rc 0 (VERIFIED; matches the 29205cb body).
- `--filter reconstruct` at each `[TEST]` commit (brief item 4, tests discriminate): 67f355c 17 passed / 3 failed, 8aa3737 20 / 9, a23d518 29 / 9, ea3b096 38 / 3; every failing test is the one its following `[FIX]` names, and every count matches the commit body (VERIFIED).

## Prior findings R1 to R16: status at the tip

| id | status | receipt |
|---|---|---|
| R1 relocate rewrites the caller's repo on a bad path | closed | `relocate /nonexistent/repo cpp` from a repo: rc 2, stub filter-repo never ran; non-root path rc 2 (suite + probe). Residual: GIT_DIR vector, see A2 |
| R2 relocate resets local branches to origin | closed | ahead branch kept with its tip SHA, behind branch refused rc 1, tip untouched (suite) |
| R3 scrub misses branches, wrong SHA, 256 wraps | closed | branch-only body hit by real SHA, path hit, pickaxe hit, 256 hits rc 1 (suite). Residual: ref names and identities unswept, see A6 |
| R4 audit-structure contradicts the protocol | closed | reconcile and PR landings PASS, `.0` seal PASS, gap and double FAIL, push gap FAIL, `--require` (suite). Residual A7 |
| R5 bin loads lib from cwd | closed | runs by absolute path from a plain repo and a non-repo dir (suite) |
| R6 fast-forward claims ok on failure, token in `.git/config` | closed | failed push rc 1 without `ok:`, no `gh auth token` call anywhere (`grep -c 'auth token' scripts/reconstruct.sh` = 0), URL carries no credential, `-c credential.helper=!gh auth git-credential` scoped to the one command (read + suite) |
| R7 fast-forward drops safety, vault, tags | closed | dry-run plan and real file:// push carry safety, vault, tags; `--atomic` (suite) |
| R8 verify-artifacts swallows output | closed | DIAGNOSTIC-LINE shown, bad JSON rc 2 (suite) |
| R9 claude answers unvalidated | closed | stdout only, last line must match, prose rc 1 (suite, non test mode with stub claude). Residual A9 |
| R10 identity reads HEAD only | closed | unmerged-branch author and distinct committer listed (suite) |
| R11 skill prescribes bare force push, reset --hard, branch -D | closed in text, broken in practice | no `push --force`, no `branch -D`; `--force-with-lease` after `reconstruct preflight`. But the preflight the skill routes through does not satisfy Joel's guard, see A1 |
| R12 skill token waste and contradictions | closed | 6824 to 3102 words (`wc -w`), description 34 words, ff/no-ff and graft contradictions gone |
| R13 single bundled commit, wrong identity | closed | 19 atomic commits, `v4rian-waylon (Opus) <v4rian-waylon@users.noreply.github.com>` on every one |
| R14 aa1a68c base lacks resolve_skill | closed | branch sits on dev 5028b58 where `resolve_skill` exists (`_lib.sh:144`); `user_skills_dir` used at `reconstruct.sh:682` |
| R15 audit-structure count wraps | closed | 256 orphans rc 1 (suite) |
| R16 tag loop no-op | closed | loop deleted; `grep -c 'git tag -f' scripts/reconstruct.sh` = 0 |

## New findings

| severity | count |
|---|---|
| critical | 0 |
| high | 1 |
| medium | 5 |
| low | 7 |

### A1 · high · the preflight the skill routes rewrites through is rejected by `guard-destructive.sh`, so both skill recipes cannot run on <host>
- **file:line** `scripts/reconstruct.sh:411` (`archive="$bak_dir/$name-$stamp.zip"`), `:373` (`RECONSTRUCT_BAK_DIR` default `<repo parent>/baks`); `skills/git-reconstruct/SKILL.md` Step 10 (`reconstruct preflight … ; git push --force-with-lease …`) and "Fixing unpushed local history" (`reconstruct preflight . … ; git reset --hard …`); `~/.claude/hooks/guard-destructive.sh` (`z=$(ls -t "$BAKS"/"$name"-bak-*.zip …)`).
- **evidence** VERIFIED. `reconstruct preflight work "fix in place"` then the guard on the skill's next command, with `BAKS_DIR` pointed at the same bak dir:
  ```
  work-20261029T123258Z.bundle  work-20261029T123258Z.zip
  deny: git reset --hard on …/p6/work with no work-bak-*.zip in …/p6/baks within 12h
  deny: force push on …/p6/work with no work-bak-*.zip in …/p6/baks within 12h
  ```
  The ref half of the guard passes (preflight ref on origin); the zip half fails on the name (`<name>-<stamp>.zip` vs the hook's `<name>-bak-*.zip`). Commit 5fb6686 says the recipe was "run on a four commit scratch repo", which is true only outside the Claude Code hook. Every consumer of the skill on this machine is a Claude session under that hook, so Step 10 and the local-fix recipe halt at their second command with an instruction to run `git-preflight.sh` instead, which the skill no longer mentions.
- **fix** `archive="$bak_dir/$name-bak-$stamp.zip"` (`.tar.gz` likewise) and `bak_dir="${RECONSTRUCT_BAK_DIR:-${BAKS_DIR:-$(dirname "$repo_abs")/baks}}"` so the tool and the hook agree on both name and place; mirror to `BAKS_MIRROR` when set, as `git-preflight.sh` does.
- **test** `test_reconstruct_preflight_zip_matches_guard_name`: assert a `work-bak-*.zip` exists after `preflight`; optionally, when `~/.claude/hooks/guard-destructive.sh` exists, pipe the reset command through it with `BAKS_DIR` set and assert no `deny`.

### A2 · medium · an exported `GIT_DIR` makes any plain directory pass the repo-root guard, and relocate then rewrites the `GIT_DIR` repo
- **file:line** `scripts/reconstruct.sh:459-461, 510-512` (`git rev-parse --show-toplevel` equality is the only root test), `:19` (nothing unsets `GIT_DIR`/`GIT_WORK_TREE`).
- **evidence** VERIFIED. `GIT_DIR=…/victim/.git reconstruct relocate …/plain cpp` where `plain` is an empty non-repo directory:
  ```
  preflight: preflight-bak-2026-10-29/01 (ce73ad32…, local only (no origin)) …
  STUB cwd=…/p3/plain args=--to-subdirectory-filter cpp --force
  branches: 2 -> 2 ; rc=0
  ```
  The preflight ref landed in `victim`, and the real filter-repo would have rewritten `victim` from a directory that is not a repository. With `GIT_DIR` set, git treats the cwd as the work tree, so `--show-toplevel` equals any cwd. Git sets `GIT_DIR` in every hook, so a hook that calls the tool, or an operator shell that exported it, is the trigger.
- **fix** at the top of `reconstruct.sh`: `unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES`; additionally require `[ -e "$repo_abs/.git" ]` in `relocate` and `preflight`.
- **test** `test_reconstruct_relocate_ignores_inherited_git_dir`: export `GIT_DIR` to a victim, call `relocate` on a plain dir, assert rc 2, no marker, no new ref in the victim.

### A3 · medium · relocate's only post-check is ref counts, so a rewrite that changed nothing passes; a linked worktree is one such case
- **file:line** `scripts/reconstruct.sh:519-535`.
- **evidence** VERIFIED with the real filter-repo on a linked worktree of another repo (`.git` is a `gitdir:` file):
  ```
  New history written … Completely finished
  branches: 3 -> 3 ; tags: 0 -> 0 ; rc 0
  main-repo after: main 6dc9ad0 seed, side 6dc9ad0 seed   (unchanged SHAs)
  linked work tree after: .git cpp                        (files moved, history not)
  ```
  The tool reported success while no ref was rewritten and the working tree no longer matches HEAD. A worktree is also a shared object store: a successful rewrite there would rewrite the main repo the operator never named.
- **fix** refuse when `git rev-parse --git-dir` differs from `--git-common-dir` (linked worktree) or `.git` is not a directory; after filter-repo assert for every branch tip that `git ls-tree --name-only <tip>` is exactly `<subdir>` and that HEAD's SHA changed, else exit 1 naming the ref.
- **test** stub filter-repo that does nothing: assert rc 1 "history not relocated"; linked worktree fixture: assert rc 2 before any preflight.

### A4 · medium · relocate silently discards uncommitted tracked changes
- **file:line** `scripts/reconstruct.sh:450-540` (no `git status --porcelain` check); filter-repo `--force` skips its own clean-tree check and ends with a hard reset.
- **evidence** VERIFIED with the real filter-repo: `README.md` edited to `EDITED` and untracked `notes.txt` before `relocate`; afterwards `cpp/README.md` = `r`, `git status --short` = `?? notes.txt` only, no warning printed. The edit survives in the preflight ref (`preflight-bak-2026-10-29/01:cpp/README.md` = `EDITED` locally, `:README.md` = `EDITED` on origin) and in the zip, so this is a recoverable loss the operator is not told about.
- **fix** refuse before the preflight when `git status --porcelain --untracked-files=no` is non-empty ("commit or stash first"), consistent with the brief's "never weaken a gate" and with how `relocate` already refuses a behind branch.
- **test** dirty fixture with the stub: assert rc 1, marker absent, file content unchanged.

### A5 · medium · relocate proceeds when the preflight ref could not reach origin, leaving the bundle and zip as the only pre-rewrite copies
- **file:line** `scripts/reconstruct.sh:401-405` (`pushed="PUSH FAILED, local only"`, exit status unaffected), `:504` (relocate checks only the function's rc).
- **evidence** VERIFIED: origin with a refusing `pre-receive` hook:
  ```
  preflight: preflight-bak-2026-10-29/01 (fc0cfc42…, PUSH FAILED, local only); bundle …; archive …
  STUB ran in …/p13/work ; branches: 2 -> 2 ; rc=0
  ```
  After a real rewrite the local preflight ref is itself rewritten and `origin` is removed, so the guard's "ref on origin" contract (`guard-destructive.sh`, "preflight-bak-* ref, on origin when the repo has one") is unmet and nothing off the machine holds the old history. `git-preflight.sh` reports the same failure but is followed by a human decision; here the rewrite runs unattended in the same command.
- **fix** in `_reconstruct_preflight` return 1 on push failure when an origin exists (print the refusal), so `relocate` stops with "preflight failed; nothing was rewritten"; keep the current behaviour for `reconstruct preflight` run standalone only behind an explicit `--allow-unpushed`.
- **test** the P13 fixture: assert rc 1 and no marker.

### A6 · medium · scrub never sweeps ref names or author/committer identities, and `fast-forward` ships both verbatim
- **file:line** `scripts/reconstruct.sh:321-345` (four sweeps: content, paths, messages, pickaxe); `:570-571` pushes every tag and branch name unchanged.
- **evidence** VERIFIED: repo with tag `codename-zulu-v1`, branch `pool/n9.feature.from-codename-zulu`, author `codename-zulu@old.example`:
  ```
  reconstruct scrub <repo> codename-zulu  ->  hits: 0 ; clean: no hits for any supplied term ; rc=0
  ```
  Skill Step 9 category 1 ("every prior project or zip codename") and the anti-pattern "naming a branch after its source" are exactly these leaks; `fast-forward` then publishes them to the throwaway.
- **fix** two more sweeps: `git for-each-ref --format='%(refname)' | grep -F -- "$term"` as `HIT (ref)`, and `git log --all --format='%H %an <%ae> %cn <%ce>' | grep -F -- "$term"` as `HIT (identity)`.
- **test** the fixture above: assert three hits and rc 1.

### A7 · low · audit-structure check 1 ignores the kind, so an unmerged `pool/nN.fix.<slug>` passes when `pool/nN.feature.<slug>` landed
- **file:line** `scripts/reconstruct.sh:147-156` (`_reconstruct_pool_key` drops the kind for every branch, not only reconcile candidates).
- **evidence** VERIFIED: fixture with landed `pool/n1.feature.thing` and never-merged `pool/n1.fix.thing` → `PASS: structural audit clean (1 merge(s) on dev)`.
- **fix** keep the kind in the key unless it is `reconcile` on either side.
- **test** that fixture, expect FAIL naming `pool/n1.fix.thing`.

### A8 · low · `scrub <path>` on a subdirectory under-reports: content and path sweeps are cwd-relative, history sweeps are repo-wide
- **file:line** `scripts/reconstruct.sh:318-321, 330`.
- **evidence** VERIFIED: term only in `root.txt`, `scrub <repo>/sub term` → one `HIT (history)`, no `HIT (file)`; an empty term is accepted and matches every commit (`scrub <repo> ""` → `hits: 5`).
- **fix** `cd "$(git -C "$path" rev-parse --show-toplevel)"`; reject empty terms with rc 2.
- **test** both cases.

### A9 · low · claude prompts carry the whole file in argv; a file over ARG_MAX fails with a shell error
- **file:line** `scripts/reconstruct.sh:695` (`claude -p "$prompt"`), `:779-785`, `:815-821`.
- **evidence** VERIFIED: 1.2 MB file → `reconstruct.sh: line 695: …/claude: Argument list too long`, then `X reconstruct: claude exited non-zero`, rc 1 (fails closed, no false `REUSABLE`).
- **fix** pipe the prompt on stdin (`claude -p` reads stdin) or cite the file by path as the skill paths already are.
- **test** 1.2 MB fixture with the stub claude, expect rc 0 and `REUSABLE`.

### A10 · low · relocate forwards a dash-prefixed `<subdir>` to filter-repo's option parser
- **file:line** `scripts/reconstruct.sh:455-457`.
- **evidence** VERIFIED: `relocate <repo> --help` passes the subdir guard, takes a preflight, then `git-filter-repo: error: argument --to-subdirectory-filter: expected one argument`, rc 1. Harmless with v2.47.0 (argparse refuses) but the preflight side effects already happened and a future filter-repo flag could be consumed.
- **fix** add `-*)` to the refusal case and use `--to-subdirectory-filter="$subdir"`.
- **test** assert rc 2 and no preflight ref.

### A11 · low · identity counts the stash committer
- **evidence** VERIFIED: a repo whose only second identity is a `git stash` author → `Stasher <stasher@x>` listed. `--all` includes `refs/stash`; a stash is not source history the replay attributes.
- **fix** `git log --branches --tags --remotes` instead of `--all`.

### A12 · low · the framework's own repository fails its structural audit on rules the audit cannot relax
- **evidence** VERIFIED: `audit-structure --clone <workspace>/neo-git` → `required doc missing: README.md` (the README lives in the namespace), nine `tag sequence gap` lines (v2026.0.35, .51-.53, .56, .73-.75, .77; ledger R19 says holes are permanent), and two real unlanded pool branches (`n96.feature.abandoned-branch-hygiene-helper-and-readme-polish`, `n99.fix.one-reconcile-branch-per-pool-no-suffix`, pre-existing). `--require` can add docs but nothing can drop the hardcoded `README.md .gitignore`; a hole is reported forever.
- **fix** `--no-default-docs`, and a `note:` instead of `FAIL` for a gap older than the newest tag's series start when `--allow-gaps-before <tag>` is given; keep FAIL as the default (a reconstructed repo has no legitimate hole).

### A13 · low · docs and commit nits
- `docs/CHANGELOG.md` Unreleased: "gains 41 reconstruct tests" while 40 new `run_test "reconstruct …"` lines were added (the 41st is the renamed consolidated-skills test); harmless, but the paragraph is 270 words in a section the dev→main freshness check only measures by bytes.
- `README.md:97` keeps the pre-existing "how-dev, how-push" while `skills/` has no `how-push` (15 entries: 14 `git-*` + how-dev); not introduced here, worth a one-word fix in the same `[DOCS]` commit.
- Commits: 19 against the brief's "at most ~18"; `5fb6686` carries two concerns (preflight routing and the trim) under one `[FIX]`; `795338e` body has the hyphenated compound "re-pointed" (git-commit-audit rule 15). Titles ≤69 chars, no em dashes, no `Changes:`, no trailer, identity correct on all 19 (VERIFIED by `git log --format`).
- Skill: code blocks call bare `reconstruct preflight` while "The tool" names `.io.v4rian.how-git/bin/reconstruct`; Non-negotiable 6 fixes "no remote CI" where DECISIONS ruling 7 lets CI be local or remote. Otherwise the text is lean: each tool-enforced rule stated once in "The tool", steps name subcommands only, no duplicated mechanics (`grep -c 'x-access-token\|/tmp/\|%an <%ae>'` = 0), consistent with Git_Strategy on `--no-ff` pool merges into dev, lease-based rewrites of the developer's own refs and permanent safety/vault anchors.

## Data-loss contract (brief focus), verdict per item

- Originals never touched: `identity`, `scrub`, `gaps` are read-only (`git log`, `git grep`, `ls-files`); `audit-structure` fetches into the audited target only. VERIFIED by read. Caveat: `preflight <source>` would push a `preflight-bak-*` ref to the source's origin; the skill routes source preflights through `git-snapshot-preflight`, not this subcommand.
- Preflight before every destructive step: `relocate` always runs `_reconstruct_preflight` before filter-repo (`:504`), and the skill's two rewrite recipes start with `reconstruct preflight`. VERIFIED, with A1 (guard mismatch) and A5 (push failure not fatal) as the gaps.
- Pushes: `fast-forward` uses `--atomic` to a brand-new repo (no force needed); the skill's destination rewrite uses `--force-with-lease=<ref>:<expected>`; the test `skill routes rewrites through preflight` fails on any `push --force` or `branch -D`. VERIFIED.
- Credentials: no token in any URL or `.git/config`; `gh auth git-credential` is bound by `-c` for the push and the ls-remote only; the stub-based test fails if a token reaches git's argv. VERIFIED.
- Wrong path or cwd: `relocate` refuses a missing path, a non-root path and re-verifies the cwd inside the subshell; `audit-structure` and `scrub` refuse a failed `cd`. VERIFIED, with A2 (inherited `GIT_DIR`) and A3 (linked worktree) as the remaining doors.

## Verdict

FIX-THEN-MERGE. No critical finding; A1 breaks the skill's own rewrite path under Joel's hook and is a one-line rename plus one env fallback; A2 to A6 are each a guard or a sweep of a few lines with a failing test first. Nothing here weakens an existing gate; every prior finding R1 to R16 is closed at the tip and each `[TEST]` commit demonstrably fails before its `[FIX]`.
