# Audit: local/ghost-tools (11 commits on dev) - Fable 5.1, 2026-10-29

Scope: `dev...local/ghost-tools` (23 files, +1121/-251). Executed in detached worktrees `$TMPDIR/aud-ghost` (suites, probes) and `$TMPDIR/aud-mut` (mutations); both removed. bash 3.2.57 is the only bash on <host> (no bash 5 installed, `which -a bash` = /bin/bash); bash 5 behaviour UNVERIFIED. actionlint is not installed here, so the commit-body claims "actionlint 1.7.12 is clean" (0a3303e, 6385cfa) are UNVERIFIED.

Suites in the audit worktree: `test-hooks.sh` 60 passed / 0 failed; `test-lifecycle.sh` 413 passed / 0 failed (matches 8a5a92b's body).

Verdict: **FIX-THEN-MERGE**. 0 critical, 1 high, 5 medium, 8 low.

---

## HIGH

### G01 [HIGH, data loss] content-match "100%" is one-sided; a snapshot with deletions scores 100% at every superset commit, and the skill then declares it clean
- `skills/git-shuttle/tools/content-match.sh:139-143` computes `match / TOTAL` where TOTAL = snapshot in-scope files only. Files present in the commit tree but absent from the snapshot never lower the score. `SKILL.md:242` turns 100% into "Snapshot is already represented at C*. No rebuild needed ... skip Steps D-G".
- VERIFIED (probe 15, target with c1 = {logo.png, .env, keys, .auth, src/*, win.txt, run.sh}, snapshot = c1 minus the whole `src/`):
  ```
  3/3	100.0%	c1 base
  3/3	100.0%	c2 alpha v2
  ```
  Two unrelated commits tie at 100%; the deletion of `src/` is invisible unless `--verbose` is passed, and the skill's 100% row does not ask for it. A real shuttle snapshot where the user deleted files would be recorded as "clean", losing the deletion (and the tie-break then picks c1, an arbitrary ancestor).
- Fix: add an `extra_in_commit` column (in-scope tree files not in the snapshot, after running the same scope filter over the tree side) and let 100% mean `matched == total && extra == 0`; or report a two-sided ratio (`matched / |snapshot ∪ tree|`). Update `SKILL.md:242` to "100% and extra=0".
- Test: lifecycle test with a snapshot that drops one file; assert the top row is not 100% (or shows extra=1).

## MEDIUM

### G02 [MEDIUM, data loss] integration-check calls a rename INTEGRATED, and the skill says to skip INTEGRATED files
- `integration-check.sh:135` emits `INTEGRATED <path> <blob> <repos> <repo@sha>` keyed by blob only; no column says at which path the blob lives. `SKILL.md:260`: "INTEGRATED ... Skip this file in atomization".
- VERIFIED (probe 4): snapshot renamed `src/gamma.js` -> `src/gamma2.js` against the target itself:
  `INTEGRATED	src/gamma2.js	af17f6c...	<repo>	<repo>@a552ff4...`
  Following the text, the rename is never committed. The lifecycle test even asserts the sibling-rename case as INTEGRATED (`renamed.txt`), which is right for extraction into a sibling but wrong for a path move inside the target.
- Fix: add a `paths` column (`git log --all --format= --name-only --find-object=<oid>` or `ls-tree` at first commit) and split the status into `INTEGRATED` (same path in the target) and `INTEGRATED_ELSEWHERE` (other path / other repo); make Step D treat `INTEGRATED_ELSEWHERE` in the target as a rename (git mv), not a skip.
- Test: rename-only snapshot vs the target; assert the row is not plain INTEGRATED.

### G03 [MEDIUM, secret exposure] directory-style sensitive exclusions silently do nothing
- `_snapshot-scope.sh:27` turns every `--extra-exclude NAME` into `! -name NAME`; `-name` matches basenames only. `SKILL.md:224` tells the caller to pass every workspace banned name this way, and the workspace list is mostly directories (`.auth/`, `keys/`, `exports/`, `node_modules/`, `build-*/`).
- VERIFIED (probe 2): `--extra-exclude '.auth/' --extra-exclude 'keys/'` left `.auth/sa.json` in scope (`in_scope_files=8`, listing shows `.auth/sa.json`); `.env` and `*.p8` were excluded. Service-account JSON would then be hashed, reported `NEW_IN_SNAPSHOT` and handed to Step D for committing.
- Fix: accept `--extra-exclude-path GLOB` (`! -path "*/$GLOB/*"`), or detect a trailing slash and emit `! -path`; print the final exclude list on stderr so the operator sees what was honoured.
- Test: snapshot with `.auth/x.json`, `--extra-exclude .auth/`, assert not in scope.

### G04 [MEDIUM, data loss] symlinks vanish from scope without a word
- `_snapshot-scope.sh:29` `find -type f` skips symlinks and does not descend symlinked directories; `content-match.sh:129` also drops `120000` tree entries. No stderr line reports the omission (only TAB paths get one).
- VERIFIED (probe 3): snapshot with `alpha-link.js -> src/alpha.js` (git tracks it as `120000`) and `linked-dir -> <dir with work.js>`: `symlink entries in scope: 0`. A `cp -pR` shuttle snapshot keeps symlinks, so real content behind a linked directory would never reach Step D.
- Fix: enumerate `-type l` too, hash the link target text (`git hash-object --no-filters` of `readlink`), compare against `120000` entries; warn on symlinked directories (git would store the link, not the contents).
- Test: snapshot with a file symlink; assert it is counted and matches the repo's 120000 blob.

### G05 [MEDIUM, security] audit-pushed-branch runs any ref with inherited secrets and a contents:write token; no admin gate, `ref` unvalidated
- `.github/workflows/audit-pushed-branch.yml:19-25,38-39`: `ref` (free text) is checked out by `ci-dispatch.yml:95,209` and every `ci/{tests,audits}/push/*.sh` from that checkout runs with `secrets: inherit` (CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, CI_BOT_APP_PRIVATE_KEY, CANARY_TOKEN) and `contents: write`. GitHub docs (VERIFIED, events-that-trigger-workflows): "you can dispatch it against any branch or tag via the GitHub API or GitHub CLI". A maintainer auditing a fork PR with `-f ref=refs/pull/N/head` executes untrusted scripts with those secrets. Forks themselves cannot dispatch (write access needed), so this is a foot-gun, not a remote hole.
- Also: `ci-dispatch.yml:72-73` concurrency group is `ci-dispatch-<caller workflow>-<github.ref>`; `github.ref` is the dispatch branch, not `inputs.ref`, so two audits of different refs dispatched from main cancel each other (`cancel-in-progress: true`). UNVERIFIED whether GitHub honours workflow-level `concurrency` in a called workflow (docs page fetched does not say).
- Fix: validate `inputs.ref` in the resolve step (`refs/heads/*` or `refs/tags/v*` of this repo, refuse `refs/pull/*` and bare SHAs not on a branch), or put the same `verify-actor-admin.sh` gate in front of it; include `inputs.ref` in the concurrency group.
- Test: lifecycle assert that audit-pushed-branch.yml either carries the admin gate or ci-dispatch.yml rejects `refs/pull/`.

### G06 [MEDIUM, docs overstate] the skills imply the on-demand entry satisfies the required checks; only the yml header says it does not
- `git-compile-audit/SKILL.md:8`, `git-coverage-audit/SKILL.md:8`, `git-runtime-audit/SKILL.md:8` (and commit-audit, strategy-audit STATUS lines): "runs ... through ci-dispatch.yml's push trigger (on demand through audit-pushed-branch.yml, off grid through bin/ci-local --workflow audit-pushed-branch) and surfaces as the `required.compile` status check on PRs to dev". README:116 and RUNBOOK tree never say the four entries are manual-only.
- `audit-pushed-branch.yml:11-12` itself states checks "report as 'audit / <check>'" and cannot re-green a bound required check. Additionally (VERIFIED from GitHub docs: for workflow_dispatch `GITHUB_SHA` = "Last commit on the GITHUB_REF branch or tag") the run's check runs attach to the dispatch branch's SHA, not to `inputs.ref`, so even the name aside the result lands on the wrong commit unless dispatched with `--ref <branch>`. `ci-local --workflow` results never reach GitHub at all (`--archive` writes a custom ref).
- Fix: one sentence in each STATUS line and in README/RUNBOOK: "audit-pushed-branch.yml and ci-local are manual re-runs for reading; neither satisfies a PR required check, only the push run of the head SHA does."
- Test: n/a (docs); the consistency-lint pool could grep for "surfaces as" next to "audit-pushed-branch".

## LOW

### G07 [LOW, docs contradiction] README paragraph says "Seven" and lists eleven; still describes workflow_dispatch on ci-dispatch
- `.io.v4rian.how-git/README.md:115-116`: "**Seven CI dispatchers ship**" followed by 11 names. Same paragraph keeps "The earlier ... `build-on-tag.yml` workflows have been folded into `ci-dispatch.yml`" two sentences before "Four named entries sit on top ... `build-on-tag.yml`", and "the folded pr-merge-dev / pr-merge-main claim handlers accept both their primary push trigger and a manual workflow_dispatch trigger" although `ci-dispatch.yml` has no `workflow_dispatch` (VERIFIED: `on:` has `push` and `workflow_call` only).
- Fix: "Eleven", drop "folded" for build-on-tag, move the workflow_dispatch sentence to the thin entries.

### G08 [LOW, test does not discriminate] assert_thin_ci_dispatch_entry event list is an allowlist of seven events; inline logic chained after the gate passes
- `framework-tests/test-lifecycle.sh:186` blocks only `push|pull_request|pull_request_target|schedule|release|create|workflow_run`; `:195` whitelists any `run:` line containing `verify-actor-admin.sh`.
- VERIFIED by mutation (filter "workflow yamls dispatch to scripts/workflows/"): adding `issue_comment:` to audit-pushed-branch.yml -> PASS; adding `repository_dispatch:` to build-on-tag.yml -> PASS; `run: bash .../verify-actor-admin.sh && git push -f origin HEAD:main` in main-merge.yml -> PASS. Adding `push:` to dev-merge.yml -> FAIL (correct).
- Fix: parse the `on:` block and fail on any key other than `workflow_dispatch`; require the `run:` line to be exactly the gate command.

### G09 [LOW] newline in a filename aborts the run with git's message and the wrong exit code
- `_snapshot-scope.sh:18` says newline and TAB paths "are reported on stderr and skipped"; only TAB is. VERIFIED (probe 5): `fatal: could not open 'has' for reading`, integration-check exits 1, which `:30` documents as "snapshot has no in-scope file".
- Fix: `find -print0` + `tr`-free filtering, or skip paths containing `\n` the way TAB is skipped (detect with `grep -c ''` vs `wc -l`).

### G10 [LOW] a `.git` gitfile at the snapshot root is in scope
- `_snapshot-scope.sh:30` `! -path '*/.git/*'` needs a trailing slash; a worktree snapshot carries a `.git` *file*. VERIFIED (probes 1, 6): `NEW_IN_SNAPSHOT	.git`, `NEW	.git`, counted in `in_scope_files`. Fix: add `! -name .git`.

### G11 [LOW] `--path-prefix ./sub` silently yields 0%
- `content-match.sh` strips a trailing slash only. VERIFIED (probe 7): `sub/` 100%, `sub` 100%, `./sub` 0.0%. Fix: strip a leading `./` too, and refuse an absolute prefix.

### G12 [LOW] `--branches` list with a space, nonexistent rev
- VERIFIED (probe 9): `--branches 'main, nope'` -> `fatal: bad revision ' nope'`, git's rc, no tool-level message; undocumented exit code. Fix: trim items and verify each with `rev-parse --verify` before the scan (exit 2).

### G13 [LOW] shallow clone gives a wrong first_commit without warning; `--no-filters` vs `text=auto`
- VERIFIED (probe 12): on a `--depth 1` clone `first_commit` for `win.txt` is the grafted tip (c2) although c1 introduced it. VERIFIED (probe 8): a repo with `* text=auto` stores LF, the CRLF snapshot copy reports `MODIFIED` (documented design choice in the header, but Step D would then commit a no-op change). Fix: warn when `git rev-parse --is-shallow-repository` is true; mention the normalisation caveat in SKILL.md Step C.

### G14 [LOW, pre-existing, info] off-grid claim twins are live operations and run twice in this repo
- `bin/ci-local --workflow dev-merge` resolves to `required.claim.sh` -> `claim-retry.sh --target dev` -> `claim-dev-merge.sh --skip-pull`, which tags HEAD and force-pushes dev with a lease when origin exists (guarded by "HEAD must be dev", `claim-dev-merge.sh:91`; the R01 `checkout -B dev FETCH_HEAD` at `:107` is behind the pull path, so `--skip-pull` is safe). README/RUNBOOK call it a "twin" without saying it performs the claim. In neo-git both layers list the same check (`ci-dispatch.sh --trigger pr-merge-dev --list` shows usr and sys `required.claim`), so the claim runs twice (idempotent resume). Not introduced by this branch (`--trigger pr-merge-dev` existed on dev); one sentence in RUNBOOK would do.

---

## Verified OK (no finding)

- doc-freshness-check.sh empty-array claim: VERIFIED under bash 3.2 with `bash -u`. PASS path (STALE_DOCS empty, `${#STALE_DOCS[@]}` at :464) rc=0 with and without `DOC_FRESHNESS_AUTOFIX=1`; no docs at all + no merges rc=0; STALE path with the canned worker rc=0; production mode without gh/claude rc=1 with WARN; sourcing without PR_NUMBER returns cleanly. `"${arr[@]}"` expansions at :318, :364, :472, :475, :490 are only reached with non-empty arrays. Side note (not this branch, not an array): `DOC_FRESHNESS_CHANGELOG_MIN=abc` prints `line 229: abc: unbound variable` and the CHANGELOG verdict line comes out blank, so a misconfigured env silently drops the strict doc from the gate; the ROADMAP backlog line can be closed as "could not reproduce" with that caveat.
- Tie rule (earliest author date), noise exclusion, spaces in paths, `--top` validation, non-repo target (exit 2), mistyped sibling repo (exit 2), empty / noise-only snapshot (exit 1), binary blobs, blobs reachable only from a side branch, stash/remote refs (`--all`): VERIFIED by probe and suite.
- `ci-local --workflow`: quoted trigger and `.yaml` extension parsed; `${{ inputs.t }}` falls to the unknown-trigger exit 2; `../workflows/dev-merge` resolves (harmless, stays inside the repo); `dev-merge.yml` typed with suffix is refused with a clear message; two v* tags on HEAD pick `git describe`'s choice (v0.0.2) silently (info); `--workflow` + `--trigger` exclusive; TAG honoured. commit-audit's range under a dispatched ref is `origin/dev..HEAD` (commit-audit.sh:96-123, GITHUB_EVENT_BEFORE/AFTER unset in ci-dispatch.yml), so the audited commits are the input ref's.
- Thin-ness: the four yml files carry no `run:` beyond the shared gate, `needs: admin` precedes the call, `verify-actor-admin.sh` requires `admin` (not `maintain`). Permissions cannot be elevated by the callee (GitHub docs VERIFIED).
- Mutation discrimination: M1 old `usage()` -> FAIL; M2 tie order reversed -> FAIL; M3 `rev-list HEAD` instead of `--all` -> FAIL; M4 delete dev-merge.yml -> FAIL; M8 hardcoded trigger -> FAIL; M9 skill names `tools/phantom-check.sh` -> FAIL; M6 `push:` on a thin entry -> FAIL. (M5/M7/M10 see G08.)
- Commit hygiene: 11 commits, identity `v4rian-waylon (Opus)` on author and committer, `[TAG] Imperative` titles <= 72 chars, dash scrubs isolated ahead of edits (7bb7cbf, 3625ebf), `[TEST]` before `[FIX]` for the help defect (2e6a091 -> 02b28b5), bodies match the diffs. Only unverifiable claim: actionlint (see header).
- No gate weakened: no opt-out added; the only enforcement change is the deleted "legacy yml must be absent" asserts, replaced by the thin-entry assert (whose gaps are G08).
