# githooks

Local git hooks for the v4rian way. Auto-activated the first time any
in-repo script runs - `open-pr.sh`, `claim-dev-merge.sh`,
`claim-main-release.sh` source `scripts/_lib.sh` and call
`ensure_hooks_path`, which idempotently sets `core.hooksPath` to
`.io.v4rian.how-git/githooks` so these hooks are used in place of
`.git/hooks/` and stay versioned with the repo. To activate explicitly
(repair / drift), run `bash .io.v4rian.how-git/scripts/heal.sh`.

| Hook                  | Purpose                                                                |
|-----------------------|------------------------------------------------------------------------|
| `pre-commit`          | Scrub em-dashes and en-dashes from staged prose files (markdown, text, rst, AsciiDoc, Org, README-style docs); code and data keep their bytes, and in a consumer repo the vendored namespace is exempt |
| `prepare-commit-msg`  | Smart auto-fix layer, rewrites messages in place (dash scrub, banned-word replacement outside code spans, [TAG] derivation from staged diff shape, sentence cap that keeps lists intact, third-person bullets). Opt out with `HOW_GIT_AUTOFIX=0` (one command) or `git config howgit.autofix false`; rebase and cherry-pick replays are never rewritten; `[MERGE]` bodies get only the rule scrub (dashes, banned words, Claude trailer) so their nested list stays intact |
| `commit-msg`          | Subject 8-100 characters (140 for `[MERGE]`/`[REQ]`) and the message rules: no em/en dash, no banned word in prose, no Claude co-author trailer; banned words come from `AUTO_FIX_BANNED_WORDS` (default `plus`); ref names, paths, keys, compounds, and code spans are identifiers, not prose; no subject prefix is exempt; `[MERGE]` subjects and merges onto dev or main must pass `scripts/check-merge-message.sh` |
| `pre-push`            | Reject a push whose destination branch name does not match the v4rian format (judged per pushed ref, so a lane pushed from a detached HEAD works) and re-check the message rules on working-branch commits new to the destination, judged from what the destination advertises (the lane's safety anchor bounds a first push to an empty remote); refuse a pushed merge commit that breaks the merge message shape |
| `post-checkout`       | Warn locally when a branch is created with a non-conforming name       |
| `post-merge`          | Auto-run claim-dev-merge.sh / claim-main-release.sh when a `git pull` brings a new merge onto dev / main; this is the automator, once hooks are active the merger types nothing |

Every name check sources one regex, `HG_BRANCH_RE` in
`scripts/_lib.sh`; no hook or script carries its own copy. No server rule
validates branch names: in connected mode the rulesets only restrict who
may create `pool/*` and `safety/*`.

These are **guardrails**: they can be bypassed with `--no-verify`. The
server-side Repository Rules in `docs/repo-config.md` are authoritative
for who may create, update, and delete protected refs, never for names or
message wording, which only these hooks and the CI commit-audit check.
Local hooks exist to catch and reconcile mistakes early, before they
become noisy round-trips to the remote.

The deterministic enforcement of `compile`, `coverage`, and `runtime`
runs asynchronously in CI on every pushed branch via
`.github/workflows/ci-dispatch.yml` and surfaces as required
status checks on PRs to dev. The four claude audits that used to run
synchronously at `pre-push` time (strategy, compile, coverage, runtime)
moved there as of the Step 2 lifecycle redesign in `pool/n33`.
