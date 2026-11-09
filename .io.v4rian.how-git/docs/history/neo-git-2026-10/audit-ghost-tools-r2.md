# Re-audit: local/ghost-tools, commits c1ed8e3..9305a0c (5) - Fable 5.1, 2026-10-29

Scope: the five commits fixing audit-ghost-tools.md G01-G14 (`c1ed8e3 [TEST]`, `a8d1595 [FIX]` tools, `02c6efa [TEST]`, `9f1a50a [FIX]` workflows, `9305a0c [DOCS]`; 18 files, +471/-153). Read-only on the repo; executed in detached worktrees `$TMPDIR/aud-gt2` (tip), `aud-gt2-dev`, `aud-gt2-mut` (mutations), `aud-gt2-c1` (c1ed8e3), `aud-gt2-c2` (02c6efa); all removed. Probe scripts: `<scratchpad>/{probe1,probe2,probe3,probe4,mut,mut2}.sh`. bash 3.2.57 is the only bash here (bash 5 UNVERIFIED, as in round 1). actionlint 1.7.12 (darwin arm64 release binary, downloaded to `$TMPDIR`) VERIFIED clean on all 11 workflows at the tip and on dev, which settles the round-1 "UNVERIFIED actionlint" note.

Suites at the tip: `test-hooks.sh` 60 passed / 0 failed; `test-lifecycle.sh` 420 passed / 0 failed (matches 9305a0c's body).

Verdict: **MERGE** (0 critical, 0 high, 1 medium, 6 low; the medium is a residual edge of G03 whose documented form works).

---

## Ledger closure (G01-G14)

| Item | Status | Receipt |
|---|---|---|
| G01 two-sided score | CLOSED | Deletion-only snapshot (repo a,b,c; snap a,b): `2/2  1  66.7%`, `--verbose` lists `DELETED_IN_SNAPSHOT c.txt`; addition-only (a,b,c,d vs a,b,c): `3/4  0  75.0%`; exact tree: the only `100.0%` row; no overlap: `0/1  3  0.0%`. Prefix mode counts extra only under the prefix (`--path-prefix src`: `1/1 0 100%`). Mutation M1 (`u = t`) fails the G01 test. |
| G02 rename = INTEGRATED_ELSEWHERE | CLOSED | `a.txt -> a2.txt`: `INTEGRATED_ELSEWHERE a2.txt ... repo:a.txt`; copy keeps `a.txt` INTEGRATED and `a2.txt` ELSEWHERE; identical blob at a path that exists with other content (`b.txt`) is ELSEWHERE (Step D then sees MODIFIED); sibling-only path match stays INTEGRATED in the sibling; the path check uses the full path list, the printed `known_paths` caps at 5 (`many7.txt` INTEGRATED although it is the 7th path). Mutation M2 fails the G02 test. |
| G03 directory excludes | CLOSED (documented form) | `--extra-exclude .auth/ keys/ exports/ node_modules/ 'build-*/' .env '*.p8' '*.p12' '*.pem'` leaves only `.env.local app/exports.js app/ok.js authkeys/g foo.auth/f keys.md` in scope; nested `app/.auth/deep/sa.json` and `app/sub/keys/k.pem` excluded. Regex metacharacters in patterns are escaped (`a+b`, `x|y`, `a.b` exclude only themselves). Tree side is filtered with the same rules (repo tracking `keys/k.pem` with `--extra-exclude keys/`: extra 0). Mutation M3 fails the G03 test. Residual: R01 below. |
| G04 symlinks | CLOSED | `cp -pR` snapshot with file link, dangling link and directory link vs the repo storing all three as 120000: `5/5 0 100%`, all INTEGRATED. Dangling link with a different target: MODIFIED. Symlink loops (`self -> .`, `loop1 <-> loop2`): no hang, counted as links. Link target containing a newline: hashed correctly (TSV carries path+oid only). Regular file where the repo has a link: MODIFIED. Snapshot dir passed as a symlink: works. Mutation M4 (`-type f` only) fails the G04 test. Residual: R03. |
| G05 admin gate + ref validation | CLOSED | audit-pushed-branch.yml has the `admin` job and `needs: admin`; all four entries pass secrets by name; `ci-dispatch.yml` runs `verify-dispatch-ref.sh` from the trusted checkout before `check out the requested ref`, and the `check` job has `needs: resolve`, so no script of the requested ref runs when the validator refuses. Validator probes (28): accepts `main`, `feature`, `refs/heads/feature`, `v1.0.0`, `refs/tags/v1.0.0`, annotated tag, `release/1.0`, 40-hex SHA on a branch; refuses `refs/pull/7/head`, loose SHA, short SHA, upper-case SHA, `feature:main`, `refs/remotes/origin/feature`, `refs/heads/`, `--all`, `-x`, `HEAD`, `origin/feature`, `feature^`, `main~1`, `v1.0.0^{}`, `@`, `refs/pull/7/head^{commit}`, newline, `feature;ls`, `FETCH_HEAD`, `refs/notes/commits`. Concurrency group now keyed on `inputs.ref || github.ref`. Mutations M5-M8 (accept refs/pull, drop containment check, revert concurrency, remove validator step) each fail the G05 test. Note R04 (tag on an orphan commit is accepted; by design, a tag is a repo ref). |
| G06 docs overstate | CLOSED | The five STATUS lines, README:116 and RUNBOOK now say manual entries and ci-local are re-runs for reading that never satisfy a PR required check. |
| G07 README count | CLOSED | "Eleven" and 11 `.yml` files VERIFIED (`ls .github/workflows/*.yml | wc -l` = 11); folded-workflow sentence and the ci-dispatch `workflow_dispatch` claim corrected. |
| G08 thin-entry assert | CLOSED (with gaps R02) | Mutations now FAIL: `issue_comment:` added (M9), `on: [workflow_dispatch, push]` (M15), extra `push:` key (M16), gate chained with `&& git push` (M10), `run: |` block (M20), `secrets: inherit` (M11), `needs: admin` removed (M12). The strict assert fails at 02c6efa against the pre-fix ymls and passes at the tip. |
| G09 newline path | CLOSED | G09 test; mutation M19 (arm removed) fails it; `find -print0` + `read -d ''` works under bash 3.2. |
| G10 `.git` gitfile | CLOSED | Excluded twice (find `-name .git -prune` and the name rule), so mutation M17 (name rule removed) still passes the G03 test: redundancy, not a gap. Nested `vendor/lib/.git` gitfile also out; `.git` symlink at root out. |
| G11 prefix | CLOSED | `./sub` = `sub` = `sub//`; `/sub`, `..`, `src/../src`, `.//src` refused with exit 2. Partial prefix `sr` does not match `src/`. |
| G12 revs | CLOSED | `'main, nope'` -> `unknown rev 'nope'` exit 2; `'main,,'` tolerated; `' '` -> "names no rev" exit 2; `HEAD~1,v1` accepted; `main..HEAD` refused (documented: each item must be a commit). |
| G13 shallow + filters | CLOSED | `WARN: shallow` on both tools (G11 test, mutation M18 fails it); SKILL.md Step C carries the `text=auto` caveat. |
| G14 live claim twins | CLOSED | RUNBOOK "Manual CI entries and their off-grid twins" says the twins tag and force-push and run twice on the framework repo. |

## The implementer's three unverified points, settled from GitHub docs (fetched 2026-10-29)

1. **Can a called workflow exceed the caller's permissions?** No. docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations, "Supported keywords for jobs that call a reusable workflow": "The `GITHUB_TOKEN` permissions passed from the caller workflow can be only downgraded (not elevated) by the called workflow." and "Access and permissions for nested workflows": "`GITHUB_TOKEN` permissions can only be the same or more restrictive in nested workflows." The yml comment "GitHub never elevates permissions down a call chain" is VERIFIED. Caveat worth one line in the comment: the same note says "If `jobs.<job_id>.permissions` is not specified in the calling job, the called workflow will have the default permissions for the `GITHUB_TOKEN`"; the thin entries set `permissions:` at workflow level, not on the calling job. In practice workflow-level permissions apply to every job, so the called workflow gets ci-dispatch's set, but the sentence is ambiguous (UNVERIFIED on a live run).
2. **How GITHUB_TOKEN and secrets reach a called workflow.** Same page, "github context": "The called workflow is automatically granted access to `github.token` and `secrets.GITHUB_TOKEN`." and "the `github` context is always associated with the caller workflow." Named secrets: reuse-workflows how-to, "Passing inputs and secrets to a reusable workflow": "Use the `secrets` keyword to pass named secrets" / "can use the `inherit` keyword to implicitly pass the secrets"; workflow-syntax `on.workflow_call.secrets`: "If a caller workflow passes a secret that is not specified in the called workflow, this results in an error." (actionlint reproduces this: passing `CANARY_TOKEN` is flagged `secret "CANARY_TOKEN" is not defined in "./.github/workflows/ci-dispatch.yml"`). The ci-dispatch.yml comment is VERIFIED.
3. **Concurrency in a called workflow.** No sentence states outright that a called workflow's workflow-level `concurrency` is evaluated; the reference page's note presupposes it: "If you use `jobs.<job_id>.concurrency.cancel-in-progress: true`, don't use the same value for `jobs.<job_id>.concurrency.group` in the called and caller workflows as this will cause the workflow that's already running to be cancelled." and "A called workflow uses the name of its caller workflow in ${{ github.workflow }}, so using this context as the value of `jobs.<job_id>.concurrency.group` in both caller and called workflows will cause the caller workflow to be cancelled when the called workflow runs." `inputs` is a legal context in a concurrency expression (workflow-syntax `concurrency`: "The expression can only use github, inputs and vars contexts."), and `github.workflow` inside ci-dispatch.yml is the caller's name, so the group `ci-dispatch-audit-pushed-branch-<inputs.ref>` is distinct per audited ref and never collides with the push run's `ci-dispatch-ci-dispatch-<github.ref>`. VERIFIED by quote for the inputs context; "honoured in a called workflow" is inferred from the two notes, not stated.
4. Also settled: actions/checkout README, `fetch-depth`: "Number of commits to fetch. 0 indicates all history for all branches and tags." so `git branch -r --contains <sha>` in the validator sees every origin branch in the trusted checkout (a `--depth 1` clone refuses the SHA path with "commit not present in the checkout", VERIFIED).

## e2e "iterative pass force-pushes the candidate in place"

Not flaky in isolation: `--filter "iterative pass force-pushes"` 5/5 PASS on dev (5028b58) and 5/5 PASS on the branch tip, plus PASS inside the full 420-test run. The test's only shared state is `_gh_mock_enable.sh` (per-test `mktemp -d` state) and `auto-rebase-pools-after-dev-merge.sh:648` writing `/tmp/.reconcile-cherrypick-$NUM.log`; that log is write-only (never read), so two concurrent suites can at worst clobber each other's log, not the verdict. UNVERIFIED what run produced the report of flakiness; the known machine-wide cause of one-off FAILs is the fixed-`/tmp` race between concurrent suite runs documented in audit-reconstruct-r2.md B10 (9 fixed paths in other tests), not this test's body.

---

## MEDIUM

### R01 [MEDIUM, secret exposure, G03 residual] a path-form directory exclude is a silent no-op
- `_snapshot-scope.sh:38-43`: `*/)` strips the slash and treats the whole string as one directory *name*, so `app/sub/keys/` compiles into `dir_re` and is compared against single path components; `*/*` compiles into an exact-path match, so `app/sub/keys` matches only a file literally at that path. Neither excludes the files under the directory, and nothing on stderr says what was honoured (round-1 fix suggestion "print the final exclude list" was not taken).
- VERIFIED (probe4 K3-K8): snapshot `app/sub/keys/k.pem`, `app/ok.js`; `--extra-exclude app/sub/keys` -> both in scope; `--extra-exclude app/sub/keys/` -> both in scope; `--extra-exclude 'app/*/keys/'` -> both; `--extra-exclude '**/keys/**'` -> both; `--extra-exclude 'app/sub/keys/*'` -> k.pem excluded (the only working path form for a directory); `--extra-exclude /app/ok.js` -> no effect. The header documents `dir/NAME  a path relative to the snapshot root` without saying it never covers a directory.
- Why medium not low: the failure is silent and in the secrets path, the same class as G03; it only bites an operator who writes a nested path instead of the documented `NAME/`, which the SKILL.md text steers toward.
- Fix: in `scope_setup`, make `a/b/` an anchored path-prefix rule (`^a/b/`) and `a/b` match the exact path or anything under it (`^a/b(/|$)`); refuse or strip a leading `/`; print `# excludes: dirs=... names=... paths=...` on stderr once.
- Test: snapshot `app/sub/keys/k.pem`; `--extra-exclude app/sub/keys/` and `--extra-exclude app/sub/keys` both leave only `app/ok.js`.

## LOW

### R02 [LOW, test does not discriminate, G08 residual] `assert_thin_ci_dispatch_entry` checks `needs: admin` and `run:` lines, not the job graph or `uses:` steps
- VERIFIED by mutation (filter "workflow yamls dispatch to scripts/workflows/"): M13 move `needs: admin` onto a decoy job and leave `audit:` ungated -> PASS; M14 add `- uses: evil/exfiltrate@v1` with `token: ${{ secrets.GITHUB_TOKEN }}` before the gate step -> PASS; M21 append a second `uses: ./.github/workflows/ci-dispatch.yml` job without `needs: admin` -> PASS. Everything G08 named now fails (M9, M10, M11, M12, M15, M16, M20 above).
- Fix: parse jobs: require every job whose `uses:` names ci-dispatch.yml to carry `needs: admin`; allow only `actions/checkout@` under `uses:` in the gate job; fail on any other `uses:`.
- Test: the three mutations above.

### R03 [LOW] content-match is mode-blind: a regular file whose bytes equal a link target matches the repo's 120000 entry
- VERIFIED (probe4 K2): repo `link -> a.txt`; snapshot regular file `link` containing `a.txt` (no newline) -> `2/2 0 100.0%` and integration-check `INTEGRATED link`. The skill would declare the snapshot clean although the mode changed. Rare in a `cp -pR` snapshot; possible after an editor or archive tool materialised a link.
- Fix: carry the mode in the TSV (`120000`/`100644`; executable bit ignored) and compare `oid+mode`; or hash `L:<target>` for links on both sides.
- Test: the K2 layout, assert MODIFIED.

### R04 [LOW, info] validator accepts a tag that points at a commit on no branch; `*` globs pass `ls-remote`
- VERIFIED (probe3): `loose-tag` / `refs/tags/loose-tag` on an orphan commit -> accepted (a tag is a repo ref, so by design; only write access can create it). `REF='*'` -> `refs/heads/*` matches `ls-remote` -> accepted, then `actions/checkout` fails on the glob (noise, no code runs). The 40-hex SHA path accepts a commit contained by any remote-tracking branch (`git branch -r`), not only `origin/*`; in CI only origin exists.
- Fix (optional): refuse `*`, `?`, `[` in the ref; `git branch -r --contains` -> `--list 'origin/*'`.

### R05 [LOW] an unreadable snapshot file aborts with git's message and exit 1 ("no in-scope file")
- VERIFIED (probe4 K16): `chmod 000 secret` -> `fatal: could not open '.../secret' for reading: Permission denied`, content-match rc=1, integration-check rc=1; the documented meaning of 1 is "snapshot has no in-scope file". Same shape as the G09 newline case before its fix.
- Fix: `[ -r "$f" ]` in the walk, report `! skipped (unreadable): path` and continue, or exit 2 with a tool message.

### R06 [LOW, docs] two stale INTEGRATED/NEW sentences in git-shuttle SKILL.md
- `SKILL.md:345` "that file is actually INTEGRATED - Step C.5 should have caught it. If it slipped through (rare - content drift due to identical blobs across paths)" describes exactly what INTEGRATED_ELSEWHERE now reports; `SKILL.md:459` "per-file INTEGRATED/NEW classification (Step C.5)". `README.md:112` and the tools are consistent.
- Fix: "INTEGRATED or INTEGRATED_ELSEWHERE" at :345 (drop the "slipped through" clause), "INTEGRATED / INTEGRATED_ELSEWHERE / NEW" at :459.

### R07 [LOW, info] a submodule checkout inside the snapshot is walked as plain files
- VERIFIED (probe2 N): repo has gitlink `sub` (160000); snapshot has `sub/a.txt` + `sub/.git` gitfile -> `5/6 83.3%`, `NEW_IN_SNAPSHOT sub/a.txt`; Step D would commit the submodule's files into the superproject. `tree_tsv` drops 160000 entries silently and the walk only prunes `.git` itself.
- Fix: when a subdirectory contains a `.git` (file or dir), report `! nested repository sub: walked as files` on stderr; in `tree_tsv`, emit gitlinks as `<path>\tGITLINK` so the row shows up as MODIFIED rather than vanishing.

---

## Verified OK (no finding)

- Commit hygiene: identity `v4rian-waylon (Opus)` on author and committer for all five; titles 49-70 chars, `[TAG] Imperative`; `[TEST]` precedes `[FIX]` twice and the TEST commits fail exactly as the bodies say (c1ed8e3: 6 of 6 new shuttle tests FAIL, the two pre-existing shuttle tests PASS; 02c6efa: `G05 dispatch ref validator` FAIL on the missing script, `workflow yamls dispatch` FAIL on the missing `needs: admin`; both PASS after their FIX). a8d1595 also edits test-lifecycle.sh (4 expectation updates for the new column and the two corrections its body names) and says so. 9f1a50a's actionlint claim now VERIFIED. 9305a0c's suite counts VERIFIED.
- No gate weakened: the thin entries gained a gate and lost `secrets: inherit`; ci-dispatch.yml gained a refusal; no opt-out added; push-trigger behaviour unchanged (`if: inputs.ref != ''` steps skip on push, `inputs.ref` is null there and `|| github.ref` restores the old group).
- Scope rules: `--extra-exclude ''` ignored; patterns with spaces work (`'my dir/'`, `'a b.txt'`); repo path with a space works; bare repo as target works; `--top 0`, `--top abc` (exit 2), snapshot given as `./dir/` work; 1000-file snapshot ranks in 0.27 s; `--verbose` with a 0-match top commit lists NEW and DELETED rows.
- Tie rule under the two-sided score: equal pct ties still resolve to the earliest author date (deletion-only probe: c1 before c3 at 66.7%).
- Portability: `find -print0` + `read -r -d ''`, `printf '%q'`, `sort -o f f`, `paste -s -d,`, `rev-parse --is-shallow-repository` (git 2.50 here; needs git >= 2.15) all run under bash 3.2 and BSD userland; no `sed -i`, no GNU-only flags introduced.
- Docs: the five STATUS lines now carry one identical clause; README:116 no longer names `workflow_dispatch` on ci-dispatch.yml; RUNBOOK tree line for audit-pushed-branch.yml matches the yml header.
