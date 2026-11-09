# neo-git audit: `local/n165-fixes` (2026-10-29)

Range `dev...local/n165-fixes` (5028b58..f8afffa): the four September n165 commits (eb3e4f9, 02ca0df, 30ec63d, 0753e12) plus eighteen fix commits. Read-only inspection of `<workspace>/neo-git`; execution in detached worktrees `$TMPDIR/aud-n165` (tip) and `$TMPDIR/aud-mut` (mutations), both removed afterwards. Repro scripts in the session scratchpad: `lib.sh`, `race.sh`, `perf2.sh`, `clones.sh`, `mutate.sh`, `dot.sh`.

Paths relative to `.io.v4rian.how-git/` unless absolute; line numbers refer to the file at f8afffa.

## Suites (bash 3.2.57, git 2.50.1, macOS)

| suite | result |
|---|---|
| `test-lifecycle.sh` (full) | 418 passed, 0 failed |
| `test-lifecycle.sh --filter allocator` | 34 passed, 0 failed |
| `test-hooks.sh` | 60 passed, 0 failed |

bash 5: none on this Mac without installing. `which -a bash` → `/bin/bash` only (3.2.57); no `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`, `/opt/local/bin/bash`, nix profile, Xcode toolchain bash or venv bash (`find / -maxdepth 8 -name bash -perm -u+x` returns `/bin/bash` and tree-sitter grammar dirs only). The allocator suite therefore ran under 3.2 only; by read the branch adds no bash 4+ construct (no `mapfile`, `declare -A`, `${var,,}`, `&>>`).

## Ledger items (N1 to N11, R02)

| item | status | evidence |
|---|---|---|
| N1 HEAD-relative scan | fixed | `history_subjects` (scripts/allocate-pool-branch.sh:478-484) walks `--branches --tags --remotes=$TRACKED_REMOTE HEAD`; mutation m5 (HEAD-only `git log`) fails `history scan is not HEAD-relative` and `counts tag-only landings` |
| N2 shallow / single-branch | fixed | `:273-285`; `clones.sh`: `--depth 1`, `--depth 1 --no-single-branch`, `--single-branch` all exit 2 with the repair command and create no refs; `--filter=blob:none` allocates correctly; mutation m2 fails the test |
| N3 foreign remotes | fixed, with a new hole (F1) | `:262-264`; mutation m4 (`refs/remotes/*`) fails `ignores foreign remotes`; a dev that tracks a local branch drops every remote silently |
| N4 non-discriminating test | fixed | three fixtures; m8 removes the vault, subject and remote-tracking scans one at a time, each fails exactly its own test |
| N5 no fetch | fixed, with F2 | `:303-322`; mutation m3 fails `fetches the tracked remote first`; unreachable https stalls 76 s |
| N6 unanchored regex | fixed | `:521`; mutation m6 fails `subject scan ignores prose` |
| N7 fork per subject | fixed | `perf2.sh`: 20001 commits, 2857 landings, 5003 remote-tracking refs: tip 1.26 to 1.68 s, 0753e12 48.3 s, dev (refs only, wrong answer) 0.10 s |
| N8 docs | fixed, over-delivered (F8) | header, README, RUNBOOK, Git_Strategy, REQUIREMENTS, CHANGELOG all updated |
| N9 case-arm text | fixed | test-lifecycle.sh:3230 `ignored the archived vault branch (n64)` |
| N10 connected scan dead | fixed | `.github/workflows/allocate-pool-branch.yml:81` `fetch-depth: 0`; mutation m7 fails `workflow checks out full history` |
| N11 commit lens | partly open (F7) | 18 new commits carry `(Opus)`; the four September commits still do not; `Receipts:` missing on seven FIX/PERF bodies |
| R02 (reconstruct relocate) | not in this range | belongs to the reconstruct branch; nothing in `dev...local/n165-fixes` touches `scripts/reconstruct.sh` |

## Special attention items

**Reservation refs `refs/how-git/allocated/nN`.** VERIFIED (`aud-x-leak` fixture): `git push --all` sends 0 of them (heads only); plain `git clone` receives 0; `git push --mirror`, `git clone --mirror` and `git bundle create --all` carry them (1 each); `git gc` keeps them (a ref is a root); `git branch -a` and `git log --all --decorate` do not list them. The framework `pre-push` hook accepts a `--mirror` push carrying one (`* [new reference] refs/how-git/allocated/n1`, rc 0): the hook reads the current branch name, not the pushed refs. Nothing in `bin/`, `scripts/`, `githooks/` or `.github/` enumerates `refs/` without a `pool/`, `safety/`, `vault/` or `heads/` pattern (`grep -rn for-each-ref` → `_lib.sh:1098` `${pool_refspace}**`, `abandoned-pool-branches.sh:166` pool only), so the claim, the vault archive (`post-merge-lifecycle.sh:97` `vault="vault/${pool#pool/}"`) and the fetch `--prune` in `post-merge-lifecycle.sh:84` never see them. Consumers inherit nothing: the default fetch refspec is `+refs/heads/*`. Growth is one loose ref per off-grid allocation until `pack-refs`, each pinning the dev SHA of its day (F9).

**Atomicity of the update-ref transaction.** VERIFIED: `race.sh`, three rounds of 24 racers in one clone (72 allocations, each fetching origin first): 72 pool branches, 72 distinct numbers, 72 reservations, 0 racers exited 1, 0 racers misreported `offline` although all 72 fetched concurrently, worst racer recounted 12 times. The transaction (`:663-665`) creates pool, safety and reservation under one `prepare`/`commit`; two racers with the same N differ in pool name, so only the reservation ref collides, and the loser's `git rev-parse -q --verify "$RESERVATION"` (`:668`) found the winner's ref in every one of 72 cases. The window where the loser checks before the winner's `commit` writes the ref exists in theory (it would exit 1 with "atomic local ref creation failed", never a duplicate) and was not hit. Mutation m1 (no reservation in the transaction) fails the eight-racer test 3 of 3 runs, so the test discriminates reliably.

**Retry loop.** Bounded: `ALLOC_ATTEMPT -lt 50` (`:668`); each retry recounts with the winner's reservation visible, so N strictly increases and the loop cannot spin on one number. More than 50 simultaneous racers in one clone would make the 51st exit 1 rather than collide. Not a livelock.

**Offline mode.** VERIFIED: unreachable local path, `nonexistent.invalid` (6 s), ssh to a black-holed IP (10 s, `ConnectTimeout=10`) all allocate with rc 0 and the `offline: could not fetch` notice; `--no-fetch` prints `fetch skipped`. A failed fetch truncates `FETCH_HEAD` to 0 bytes (verified: 262 → 0), so reading `LAST_FETCH` before fetching (`:305`) is necessary and correct. https to a black-holed IP stalls 76 s (F2). A fresh clone that never fetched reports `no successful fetch recorded` although the clone itself dates the view (F5).

**Remote selection.** `branch.dev.remote` unset → `origin` (every fixture); dev tracking `upstream` while `origin` is a fork → `fetched 'upstream'`, counts upstream only (correct, `clones.sh`); dev tracking a local branch (`branch.dev.remote=.`) → F1.

**Shallow-clone refusal message.** Accurate and actionable; the one gap is the two-step repair for `--depth 1` (F6). A remote with a URL and no fetch refspec is refused with the single-branch wording (`clones.sh`), acceptable.

**Thousands of refs.** 5003 remote-tracking refs + 20001 commits: 1.26 to 1.68 s per allocation including the fetch (`perf2.sh`). The cost is the `git log` over the history and the fetch, not the refs; a second allocation (one more reservation) is no slower.

## Findings

| severity | count |
|---|---|
| critical | 0 |
| high | 1 |
| medium | 2 |
| low | 7 |

### F1 · high · a `dev` that tracks a local branch silently drops the whole remote from the counter
- **file:line** `scripts/allocate-pool-branch.sh:262-264`
- **evidence** VERIFIED (`dot.sh`). `git config branch.dev.remote` returns `.` whenever dev was created with `git branch --track dev main`, `git checkout -t`, or under `branch.autoSetupMerge=always` (reproduced: `git -c branch.autoSetupMerge=always checkout -b dev2 main` → `branch.dev2.remote=.`). `git remote get-url .` fails (`error: No such remote '.'`), so `TRACKED_REMOTE=""`: no fetch, no remote-tracking refs, no remote history, no single-branch gate, and no notice of any of it. With `origin` carrying `pool/n40.feature.on-origin` and the remote-tracking ref present locally:
  ```
  branch.dev.remote=.
  "branch_name": "pool/v2026.0/n1.feature.dot-check",
  remote-tracking pool refs in this clone: 1
  ```
  This is the V4Rlib n61 collision re-entered through git's own tracking config, and unlike the shallow case it is silent (rc 0, `start: ok … commit: ok`).
- **fix** treat `.` (and any value that is not a configured remote) as "fall back to origin": `case "$TRACKED_REMOTE" in .|"") TRACKED_REMOTE=origin;; esac` before the `get-url` probe; when the probe still fails and `git remote` lists at least one remote, print one stderr line naming that the counter runs on local refs only (an operator with a remote should never be left guessing).
- **test** `test_allocator_off_grid_tracks_origin_when_dev_tracks_a_local_branch`: fixture with `pool/n40` on origin, `git branch --set-upstream-to=main dev`, allocate, assert `*n41.*`; second assertion with no remote at all asserts the notice line.

### F2 · medium · an unreachable https remote stalls the allocation for 76 s while the header promises bounded stalls
- **file:line** `scripts/allocate-pool-branch.sh:34-35, 293-294, 310-315`
- **evidence** VERIFIED. `git remote set-url origin https://10.255.255.1/x.git` then allocate: `rc=0 elapsed=76s`; ssh to the same IP: 10 s (BatchMode + ConnectTimeout work); `nonexistent.invalid`: 6 s. `http.lowSpeedLimit/Time` only bound a stall after the TCP connect; git exposes no connect timeout for http (`git help config | grep -i connecttimeout` → nothing), so a black-holed https host waits for the OS TCP timeout. The header (`:34-35`) and the RUNBOOK ("bounded stalls") state otherwise.
- **fix** run the fetch under a portable watchdog, for example `perl -e 'alarm shift; exec @ARGV' 30 git … fetch …` (perl is on macOS and every Linux CI image; `timeout` is GNU only), treat the kill as the offline path; or document the https ceiling honestly.
- **test** `test_allocator_off_grid_fetch_is_bounded`: stub `git` on PATH whose `fetch` sleeps 120 s, assert the allocation returns within the watchdog plus a margin and prints the offline notice.

### F3 · medium · `[PERF]` is not an approved commit tag
- **file:line** commit d7267c9; `scripts/lib/auto-fix-commit-message.sh:214` `APPROVED = {'[FIX]', '[NEW]', '[REFACTOR]', '[DOCS]', '[TEST]', '[REVERT]', '[HOTFIX]', '[MERGE]'}`; `skills/git-commit-audit/SKILL.md:22` rule 6
- **evidence** VERIFIED by read. The repository's own auto-fix layer and the lens list eight tags; `[PERF]` is in neither, so the pushed-branch audit (`audit-pushed-branch.yml`, UNVERIFIED offline) flags it and the title would be rewritten on a hooked commit. The change (loop → pipeline, test rewritten from text pin to behaviour) is a `[REFACTOR]`.
- **fix** reword to `[REFACTOR] Take the next number from one pipeline instead of a loop` (developer-owned unmerged branch, amend allowed).
- **test** n/a.

### F4 · low · "never pushed" overstates what protects the reservation refs
- **file:line** `scripts/allocate-pool-branch.sh:655-656`, `docs/RUNBOOK.md:79`, `README.md:157`
- **evidence** VERIFIED. `git push --mirror` and `git bundle create --all` carry `refs/how-git/allocated/n1`; the framework `pre-push` hook lets the mirror push through (rc 0, `* [new reference] refs/how-git/allocated/n1`). Default fetch refspecs never bring them back, so nothing breaks; the words are wrong, not the behaviour.
- **fix** "local refs outside `refs/heads`, not carried by a normal push or fetch" (one phrase, three places).
- **test** n/a.

### F5 · low · a fresh clone reports "no successful fetch recorded"
- **file:line** `scripts/allocate-pool-branch.sh:296-302`
- **evidence** VERIFIED. `git clone` writes no `FETCH_HEAD`; a clone that goes offline before its first fetch prints `counting refs as of the last fetch (no successful fetch recorded)` although the clone time dates its view exactly.
- **fix** fall back to the mtime of `$(git rev-parse --git-path refs/remotes/$TRACKED_REMOTE/HEAD)` or of `packed-refs`, and say "as of the clone".
- **test** extend `…_fetches_tracked_remote_first` with a never-fetched clone and assert the notice names a time.

### F6 · low · `--depth 1` needs two refusals to repair
- **file:line** `scripts/allocate-pool-branch.sh:274-284`
- **evidence** VERIFIED (`clones.sh`): after the printed `git fetch --unshallow origin` the next run is refused again for the single-branch refspec that `--depth` implies.
- **fix** evaluate both conditions before exiting and print both repair commands.
- **test** assert the shallow refusal of a `--depth 1` clone names `set-branches` too.

### F7 · low · commit lens leftovers (N11 still open)
- **file:line** commits eb3e4f9, 02ca0df, 30ec63d, 0753e12 (author `v4rian-waylon`, no `(Model)`; six path-led bullets `- allocate-pool-branch.sh`, `- test-lifecycle.sh`, V.1); 850743f, bf61997, 48abef3, ce2b366, d7267c9, 4913ae4, 0dc3c03 (bodies assert observed behaviour, "handed out n1 and n5 with exit 0", "passed five runs of five", "33 seconds … 0.48 seconds", "passes 33 of 33", with no `Receipts:` section, §J); hyphenated English compounds in body prose (`remote-tracking` ×5, `single-branch` ×3, `whitespace-led`, `connected-only`; rule 15)
- **evidence** VERIFIED by `git log --format=%B dev..local/n165-fixes`.
- **fix** amend the four September commits with `v4rian-waylon (Opus)` and symbol-led bullets; add `Receipts:` lines (the test names that went green are enough); unhyphenate the compounds.
- **test** n/a.

### F8 · low · the same paragraph lives in five documents, and one of them contradicts another
- **file:line** `README.md:155-165` (11 lines), `docs/RUNBOOK.md:27-30, 73-87, 403`, `docs/Git_Strategy.md:65-72, 201-208`, `docs/CHANGELOG.md:7`, `scripts/allocate-pool-branch.sh:22-42` (header, also `--help`)
- **evidence** VERIFIED by diff: 14+18+15+2 doc lines plus the header all enumerate the counter sources, the fetch, the refusals and the reservation. README says the allocator "never reissues a spent number" while RUNBOOK:87 says two clones "can still pick the same number"; README defers to RUNBOOK for the window but the headline sentence stays absolute.
- **fix** keep the header (it is `--help`) and the RUNBOOK section as the two sources; README and Git_Strategy point at them in one sentence each; README headline "never reissues a number it can see".
- **test** `test_allocator_help_describes_counter_sources` already pins the header.

### F9 · low · reservations grow without bound and pin old dev commits
- **file:line** `scripts/allocate-pool-branch.sh:663-664` (`create $RESERVATION $DEV_SHA`)
- **evidence** VERIFIED by read and `aud-x-leak` (`git gc` keeps the ref). One ref per off-grid allocation forever, each a GC root for the dev tip of its day; after an authorised dev rewrite those commits can never be collected. Hundreds of refs are harmless; the pinning is the real cost.
- **fix** point the reservation at an empty tree or the root commit of dev (`git hash-object -t tree /dev/null` is stable and pins nothing new) and note in the header that the reservation is a name, not a snapshot.
- **test** assert the reservation target is the empty tree in `…_concurrent_allocations_get_distinct_numbers`.

### F10 · low · nine `[TEST]` commits are red at their own SHA
- **file:line** 4da96c5, b89531c, 97ce615, 698ff40, ea6ac5d, 4c8839f, 96616dd, 52a29c9, b0fc288
- **evidence** VERIFIED by the bodies ("fails on the current allocator") and by design. No rule in `docs/Git_Strategy.md` or the lens requires every commit green, so this is a note, not a violation: `git bisect` on the allocator suite will land on these.
- **fix** none required; if bisectability is wanted later, land test and fix as one `[FIX]` with the test in the bullets.
- **test** n/a.

## Not weakened

No gate or deletion path lost a check: the old best-effort `update-ref -d` cleanup on transaction failure is gone (it could delete a concurrent allocation's refs), `rollback_pair` still deletes only the pair this process created, `--no-fetch` skips a best-effort step whose failure already continues, and the two new refusals add gates. `--help` output: verified to print the whole header.

## Verdict

FIX-THEN-MERGE: F1 before landing (one `case` arm plus one notice line and one test); F2 and F3 in the same pass.
