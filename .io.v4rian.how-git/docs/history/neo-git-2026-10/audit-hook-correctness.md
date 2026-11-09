# Audit: local/hook-correctness (19 commits on dev 5028b58; ledger R04 R07 R08 R09 R10 R11 R12 R13 R17 R18)

Auditor: Fable 5.1, read-only, 2026-10-29. Worktrees: `$TMPDIR/aud-hc` (branch tip 5ac4a10), `$TMPDIR/aud-dev` (dev), both removed after the run. Paths below are relative to `.io.v4rian.how-git/` at 5ac4a10.

## Suites (VERIFIED)

- `framework-tests/test-hooks.sh`: 62 passed, 0 failed.
- `framework-tests/test-lifecycle.sh`: 417 passed, 0 failed.
- Discrimination: the branch's `test-lifecycle.sh` copied onto a dev worktree, each of the 11 new `test_hc_*` run with `--filter`: all 11 fail on dev (0 passed, 1 failed each). Every new test discriminates.
- Only bash 3.2.57 exists on this machine (`bash` and `/bin/bash` are the same); every helper was exercised under it. bash 5 UNVERIFIED (no binary).

## Findings

### HC-01 [HIGH] R13 driver replaces a lane's requirement when the lane merges dev
- `scripts/_lib.sh:1073-1075` driver `cat %B > %A` ("keep the incoming side"), `.gitattributes:5`.
- Evidence VERIFIED (scratch repo, driver configured by heal.sh): lane A `[REQ]` "Req A" merged into dev; on lane B (`active-requirement` = "Req B") `git merge dev` printed only `Auto-merging .io.v4rian.how-git/active-requirement` and left `Req A` in lane B's file. The lane's canonical intent (read by post-checkout preflight, `get-active-requirement.sh`, auto-rebase `REQ_HEADER`, `bin/smart-commit`) is silently swapped for another lane's. The commit body claims "a rebased lane keeps its own"; a merged lane does not, and the fallback (no driver) at least stopped with a conflict.
- Fix: a driver that keeps the side that is NOT dev: e.g. a tiny script `howgit-branch-local.sh %O %A %B %P` that keeps %A when `git rev-parse --abbrev-ref HEAD` is a pool/safety branch (lane merging dev) and %B otherwise (dev merging a lane, rebase onto dev). Or refuse the direction: in the driver exit 1 when HEAD is a pool branch so the merge stops as before.
- Test: extend `test_hc_r13_*` with lane B `git merge dev` after lane A landed; assert `grep -q 'lane 2' active-requirement`.

### HC-02 [HIGH] R13 is fixed for local merges only; the connected-mode merge still conflicts
- Merge drivers are repo-local config (`ensure_merge_drivers`, `heal.sh:65-73`); GitHub's merge button has none. `scripts/claim-dev-merge.sh:5,356` and `docs/RUNBOOK.md:354` ("Locks merge mode to --no-ff merge commits only") make the GitHub-side merge the connected-mode path.
- Evidence VERIFIED (server-side analogue): a fresh clone without the driver, `git merge --no-ff pool/v2026.0/n2.feature.b` into dev → `CONFLICT (add/add): Merge conflict in .io.v4rian.how-git/active-requirement`. The second PR into dev shows as conflicting on GitHub exactly as before. GitHub itself UNVERIFIED (no network call made), but the mechanism is deterministic.
- Fix: stop making the file collide instead of resolving the collision: have the allocator write `active-requirement` outside the merge path (e.g. `.io.v4rian.how-git/requirements/<pool-ref>.txt`, or keep it only on the lane and strip it in the PR via `.gitattributes export-ignore`/a pre-merge step in `finalize-pool-merge`/`validate-pr-open`). Alternatively document R13 as off-grid-only and keep the ledger item open for connected mode.
- Test: a lifecycle test that merges lane 2 in a clone that never ran heal.sh must not conflict.

### HC-03 [MEDIUM] Message rules are bypassed by a subject prefix
- `scripts/_lib.sh:1033-1034` (`[REQ]` → none, `[MERGE]` → dashes), `githooks/prepare-commit-msg:69,82` (`[MERGE]` skips audit_message and the full auto-fix). Pre-push and commit-msg inherit the scope from the subject alone.
- Evidence VERIFIED: `HOW_GIT_AUTOFIX=0 git commit -F` with subject `[REQ] Anything at all`, body carrying an em dash, "plus" and `Co-Authored-By: Claude`: rc=0, body stored verbatim. Same with `[MERGE] Not a merge at all` on a one-parent commit: rc=0. `git push origin HEAD:refs/heads/pool/...` of both: rc=0 (published). On dev, prepare-commit-msg rewrote those messages (no scope exemption existed), so this is new bypass surface the opt-out opens.
- Fix: tie the scope to facts, not the title: `[REQ]` exempt only when the commit's diff is exactly `active-requirement` (commit-msg: `git diff --cached --name-only`; pre-push: `git diff-tree --no-commit-id --name-only -r $sha`); `[MERGE]` dashes-only only when the commit has 2+ parents (commit-msg: `MERGE_HEAD` exists; pre-push: `git rev-list --parents -n1`). Anything else is `full`.
- Test: in `test_hc_r17_*`, a one-parent `[MERGE]`-titled commit with "plus" and a `[REQ]`-titled commit touching `probe.txt` with an em dash must be refused by commit-msg and by pre-push.

### HC-04 [MEDIUM] pre-push refuses pushes to a fresh remote or by URL because of legacy history
- `githooks/pre-push:71` falls back to `git rev-list $local_sha --not --remotes=$remote_name` when the remote ref is unknown locally; with no remote-tracking refs (new remote, mirror, `git push <url>`) that is the whole history.
- Evidence VERIFIED: `bash $TMPDIR/aud-e3.sh` over neo-git dev: 586 commits, 89 violate `hg_message_violations` (mostly "plus", e.g. a12d989, a9b6462, 51c6b03, a9222e3 "Merge pull request #77"). Scratch: a pool branch pushed to `origin` (dev fetched) rc=0; the same branch pushed by URL to an empty bare repo: `X Refusing to push: commit messages break the message rules: 3346fc8 [FIX] Legacy plus commit`. Any neo-git pool branch pushed to the new v4rian-io/neo-git remote before `origin/dev` exists locally, or to a NAS mirror by URL, is refused by 89 historic commits nobody can reword.
- Fix: bound the range to commits not reachable from any local `main`/`dev`/remote-tracking ref (`--not --remotes --branches=main --branches=dev`), or to commits after the first allocation of the pushed pool (`merge-base` with dev), and never scan when `$1` is a URL.
- Test: push a pool branch by URL to an empty bare repo whose history has a legacy "plus" commit on dev; must pass.

### HC-05 [MEDIUM] Opt-out plus auto-fix scope drift: configurable banned words are not enforced
- `scripts/lib/auto-fix-commit-message.sh:154` honours `AUTO_FIX_BANNED_WORDS` (csv); `scripts/_lib.sh:1019` hardcodes `plus`. A repo that bans more words gets them rewritten with auto-fix on and accepted verbatim with `HOW_GIT_AUTOFIX=0` (VERIFIED by reading; no runtime test).
- Fix: `hg_message_violations` loops over `${AUTO_FIX_BANNED_WORDS:-plus}`.
- Test: `AUTO_FIX_BANNED_WORDS=plus,utilize HOW_GIT_AUTOFIX=0` commit with "utilize" must be refused.

### HC-06 [LOW] `#`-led body lines are invisible to the gates
- `scripts/_lib.sh:1013` deletes every `^#` line before checking. git keeps `#` lines for `-m`/`-F` messages (cleanup=whitespace). VERIFIED: `git commit -F` with body line `# hidden plus line` → stored (`grep -c '^# hidden'` = 1), `hg_message_violations` passes it.
- Fix: strip comment lines only in commit-msg (where the editor template lives) and only with the repo's `core.commentChar`; in pre-push check `%B` unfiltered except the scissors block.

### HC-07 [LOW] R04 strip leaves partial userinfo for malformed or `git+https` URLs
- `scripts/_lib.sh:1086-1095`. VERIFIED under bash 3.2: `https://user:p@ss@github.com/o/r.git` → `https://ss@github.com/o/r.git` (password tail kept, `hg_has_credentials` passes it); `git+https://ghp_...@github.com/o/r.git` → unchanged (then `stamp_spec` refuses, so attach aborts instead of stamping a bare URL). Correct for every shape the test covers (x-access-token, bare token, ssh password, scp, path, `%40` passwords).
- Fix: for any `*://` scheme strip the whole userinfo up to the last `@` before the first `/` after the authority (`sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/]*@)+#\1#'`) and keep the ssh user with a second pass only for `ssh://`.

### HC-08 [LOW] doctor prints a credentialed SPEC source into its output
- `bin/doctor:184` interpolates `$spec_source` raw in the "does not exist at the source" line (and the credential `c_fail` at :166 fires alongside, so a stale credentialed SPEC leaks into terminal and CI logs). VERIFIED by reading.
- Fix: print `$(hg_strip_url_credentials "$spec_source")`.

### HC-09 [LOW] R18 classification gaps
- `scripts/_lib.sh:1058-1059`: case-sensitive extensions (`docs/x.MD` → keep, VERIFIED), `.html`/`.tex` prose kept, `LICENSE` kept while `CHANGELOG` scrubbed; fenced code blocks inside `.md` are still scrubbed (the `[--]` regex incident recurs the moment the regex sits in a README code fence). Design-level; the ledger item itself is closed.
- Fix: lower-case the basename before matching; skip fenced blocks (```` ``` ```` to ```` ``` ````) in the markdown scrub.

### HC-10 [LOW] "every gate sources the one regex" is not quite true
- `bin/create-pool-branch:154` and `scripts/allocate-pool-branch.sh:354` still carry `feature|fix|r\&d|refactor|reconcile|doc` as case patterns; `githooks/README.md:44-45` says no script carries its own copy. `skills/git-commit-audit/SKILL.md:99` and `skills/git-strategy-audit/SKILL.md:28,81,83` still omit `doc` (pre-existing). `framework-tests/test-lifecycle.sh:22` header still says "pre-push is regex-only". `githooks/README.md:25-27` ("can be bypassed with --no-verify. The server-side Repository Rules ... are authoritative") now sits under a paragraph saying no server rule validates names: contradictory on names.
- Fix: validate kind through `[[ "$KIND" =~ ^(${HG_BRANCH_KINDS})$ ]]`; fix the three doc lines.

### HC-11 [LOW] R11 attach fetches into the source checkout
- `scripts/attach.sh:166` runs `git -C "$SRC_ROOT" fetch "$SRC_URL_ACCESS" refs/tags/$TAG` into the framework source repo (writes FETCH_HEAD and objects there). attach is documented as read-only on the source. VERIFIED by reading. Fix: fetch into a throwaway bare repo as `hg_source_has_commit` does, compare trees there.

## Checked and clean
- R07: `MODE` check/dry-run/apply paths exist (`bootstrap-ci-steps.sh:62,81-84`); unknown `is_template` keeps the marker. OK.
- R08: list bodies survive `-F` and `--amend -F`; real merges (source=merge) still skip the hook entirely so a `git merge -m` em dash is refused by commit-msg (dashes scope), not silently fixed. Consistent.
- R09/R12: hooks source `_lib.sh` via `core.hooksPath=.io.v4rian.how-git/githooks` (relative `../scripts` resolves; hooks are never copied into `.git/hooks`). Detached HEAD push, tag push, deletion, misnamed destination all behave as tested. `hg_branch_name_ok` works under bash 3.2 with `&` and `{4}` in the pattern.
- R10: `-c core.hooksPath=/dev/null` disables every hook for the vendoring commit; the attach and sync messages carry no "plus" or dash, so the later pre-push re-check passes. The consumer pre-commit also exempts the namespace, so a later hand commit inside it stays byte-exact.
- R11: `hg_source_has_commit` fetch-by-SHA works under protocol v1 and v2 against a path source (rc=0 both, VERIFIED); GitHub allows reachable-SHA wants. Doctor degrades to a warning when unreachable.
- R17 happy path: `HOW_GIT_AUTOFIX=0`, `howgit.autofix=false`, rebase replay untouched, commit-msg refuses dash/plus with auto-fix off, pre-push refuses a `--no-verify` dash commit. Enforcement is not weakened on the intended path; HC-03 is the hole.
- Commit hygiene: 19 commits, each TEST precedes its FIX, titles `[TAG] Imperative` ≤72, identity `v4rian-waylon (Opus) <v4rian-waylon@users.noreply.github.com>` on author and committer, no trailers, no dashes; bodies match the diffs (the "rebased lane keeps its own" claim is true as stated; the merge direction in HC-01 is simply not covered). No `--no-verify` evidence.
- Data loss: no deletion path added; `rm -rf` only on `mktemp -d` probes.

## Verdict
FIX-THEN-MERGE. HC-01 and HC-03 are small, local fixes with clear tests; HC-02 needs a design decision (relocate the file or scope R13 to off-grid) and should not block the other nine items but must not be recorded as "R13 closed" for connected mode; HC-04 should land with the branch because the first push of neo-git's pools to its new remote hits it.
