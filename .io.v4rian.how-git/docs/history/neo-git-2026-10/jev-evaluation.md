# Jev and open-source alternatives for neo-git (pool 17, r&d.jev-evaluation)

Date: 2026-10-29. Raw receipts: `bench-results/jev/` (results.md, bench.py, bench_msg.py, bench-vcs.json, bench-msg.json, commitlint.config.mjs, gitlint.ini).

## 1. What "jev" is

Candidates checked:
- **Jev by TypeSafe AI (picked).** It is a hosted "System One" decision model, announced 2026-09-15. You send it a state and typed questions (choice, noul (probability that a statement is true), score, box) and it returns calibrated probabilities. Receipts:
  - docs.typesafe.ai/go/models.md lists `jev-1.14.0` and `jev-1.13.0` at "$42 / $0.042" per Btok / Mtok of input; output is free. Context is "64k per-request / 32k per-question".
  - The skill repo github.com/typesafe-ai/skills is MIT. Its SKILL.md is 18,085 bytes and says to use Jev "when replacing an LLM prompt-and-parse step, keyword matching, or a brittle heuristic with a typed question".
  - OpenRouter lists the model as `typesafe/jev-router`.
  - Why I picked it: the name matches exactly, it launched six weeks ago, and it is marketed at Claude Code for cutting tokens. A community mod (jev-skill-suggestion) uses it to pick which skill to load, which is the same job as neo-git's lazy loader.
- **jj (Jujutsu VCS), a possible typo.** I benchmarked it below as the strongest open-source tool in this space.
- **jeeves-git-commit (RubyGems).** It writes AI commit messages; this is not the tool meant. Rejected.

Licence: only the skill is MIT. The model is proprietary and paid (the console gives US$5 of starting credit). It is not open source.

## 2. Account attempt (kai, waylon identity)

- **Google sign-in:** console.typesafe.ai sent me to `login?error=turnstile_blocked`. The page says "We couldn't verify your browser". This is a Cloudflare Turnstile check, and it rejects kai's CEF browser driven over CDP.
- **Email sign-in as waylon@helpen.cloud:** the console said "click the link sent to waylon@helpen.cloud". Support codes [support-code redacted] and [support-code redacted].
  - I signed waylon@helpen.cloud into Gmail in kai: password from Keychain, typed through a GUI-session LaunchAgent, never printed.
  - No TypeSafe mail reached the inbox or spam after two sends and about 4 minutes.
  - A secondary source (horadecodar.com.br) says new sign-ups were paused on 2026-09-22. That is consistent with what I saw but not confirmed.
- **Blocker:** there is no API key, so I did not benchmark Jev live. Its cost below is computed from the published price and latency (100 to 300 ms per call, vendor figure).

## 3. Where Jev could fit in neo-git, and what it costs

neo-git's AI-judged steps are the decision-tree skill pick, commit-message wording, atomicity and readability review.

| Candidate use | Today | With Jev | Verdict |
|---|---|---|---|
| Skill selection (pool 13 lazy loader) | Deterministic row lookup: 0 tokens, 0 ms | One network call: 100 to 300 ms, API key, about $0.0004 per call for a 10k-token state | Worse. Code already decides reliably, and the Jev skill itself says "If code alone can already make the decision reliably, tell the user." |
| Commit tag, case and length rules | Agent reads git-commit-audit (12,727 bytes, about 3.2k tokens) | Not needed: these are syntax rules a linter handles (section 4) | Use a linter instead |
| "Is this commit atomic / does the subject describe the diff" | Claude judgment in the audit skills | Typed noul questions on the diff, about 1/1000 of the Claude input cost, but the 32k per-question limit cuts off big diffs | Possible later; needs an account and an A/B test against the Fable audit |

The Jev skill would also add 18 KB of instructions if loaded into Claude. Net: Jev does not cut neo-git tokens until a judgment step exists that a script cannot do. Pool 15 (deterministic replacements) shrinks that list first.

## 4. Open-source shortlist, benchmarked

All tools were installed under $TMPDIR (prebuilt binaries, a uv venv and an npm prefix); nothing global. Each operation ran 20 times and the median is shown. "Calls" means agent tool calls.

| Operation | Plain git + neo-git (ms / calls) | Tool (ms / calls) |
|---|---|---|
| Split one commit into two | 123 / 3 | jj split 75 / 1 |
| Absorb 5 fixes into a 5-commit stack | 475 / 11 | jj absorb 107 / 1; git absorb 0.9.0 244 / 1 (Intel binary under Rosetta) |
| Rebase a 3-branch stack | 169 / 4 | git rebase --update-refs (built into git 2.50) 129 / 1; jj rebase 130 / 1; git-branchless move 850 / 1 |
| Audit 200 messages (61 seeded violations) | neo-git hooks 11.8 s, caught 15/61 (title length only) | commitlint 950 ms, 61/61; gitlint 25.1 s, 61/61 |
| Per-commit hook cost | neo-git about 60 ms | gitlint about 220 ms; commitlint about 800 ms (Node startup) |

Two config receipts:
- The tag set, sentence case and 8 to 100 length fit in a 205-byte gitlint config or a 501-byte commitlint config.
- The `[MERGE]`/`[REQ]` 140-character exception and the body-shape rules need one custom rule of about 30 lines.

Neither linter checks branch names (`pool/nN.kind.name`); the bash check in `_lib.sh` stays.

**Token effect:**
- Moving the rules into a linter lets git-commit-audit drop the rule prose the hook now enforces, matching pool 12's target of 12.7 KB down to about 6 KB.
- Each absorb or split saves 2 to 10 tool calls.
- At roughly 300 to 600 tokens of overhead per tool call, a 5-fixup absorb saves about 3 to 6k tokens per occurrence.

## 5. Ranked recommendation

1. **ADOPT `git rebase --update-refs`.** It is already in git, with no dependency. Use it for the pool-sync rebase sweep (pool 16, R25) and for any stacked-pool rebase: 4 calls become 1.
2. **ADOPT a gitlint-equivalent rule set inside the commit-msg hook.** neo-git currently misses 46 of 61 violations. Build it in bash (or vendor gitlint's rules) so hook latency stays at about 60 ms and nothing has to be installed; port the 205-byte config logic plus the 30-line custom rule. Then trim git-commit-audit.
   - commitlint is faster for bulk audits but brings a Node dependency, so it is for CI only.
3. **PILOT git-absorb as an optional bin/ helper** for fixup-heavy pools: 11 calls become 1. It is a single static binary (MIT), and neo-git must keep working when it is absent. jj absorb is faster but needs jj.
4. **PILOT (later) Jev** for one judgment step (diff-to-subject agreement), once an account exists and only after pool 15. Score it against the Fable audit on the pool 3 benchmark harness.
5. **REJECT jj as the base VCS.** It is the fastest on split and absorb, but neo-git's protocol (claim tags, safety refs, hooks, rulesets) is built on git refs and hooks, and jj does not run git hooks. A colocated jj only for local editing would split the protocol in two. Revisit if jj gains hook support.
6. **REJECT git-branchless** (850 ms move, overlaps with --update-refs), **pre-commit** (adds nothing over the bash hooks, Python dependency) and **Jev for skill loading** (a deterministic lookup is free).

## Open

- Jev account: Turnstile rejects kai's CEF browser, and the email link never arrived for waylon@helpen.cloud. A retry with Joel's v4rian identity or a normal Chrome profile would need a browser Turnstile accepts.
- Side finding from the fork: `auto-fix-commit-message.sh` breaks when sourced by `/bin/sh` (line 414). Hooks run it under bash, so it is not a live bug; logged for pool 14.
