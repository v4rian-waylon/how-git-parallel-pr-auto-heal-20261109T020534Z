#!/usr/bin/env bash
# _lib.sh - shared helpers for in-repo scripts AND for the shipped githooks.
#
# Sourced (not executed). Provides:
#
#   ensure_hooks_path     - Idempotently sets `core.hooksPath` to
#                           .io.v4rian.how-git/githooks so the shipped
#                           hooks become active. Also installs the
#                           local `git v4r openPR` alias.
#                           Called by every in-repo script at startup.
#
#   ensure_repo_alias     - Idempotently installs `git v4r` as a local
#                           alias that dispatches to in-repo scripts:
#                             git v4r openPR  → scripts/open-pr.sh
#                             git v4r heal    → scripts/heal.sh
#                             git v4r verify  → scripts/verify-template.sh
#                           (renamed from the legacy `git repo` alias which
#                           collides with modern git's `repo` builtin)
#
#   claude_skill_run      - Runs a Claude skill via the `claude` CLI if
#                           installed, otherwise gracefully skips (logs
#                           a note but does not block). Returns 0 if
#                           audit passes or Claude unavailable; non-zero
#                           only on explicit AUDIT_FAIL from the skill.
#
#   claude_resolve_conflict - Invokes `claude -p` with working-tree
#                           file-edit permissions so claude can read
#                           conflict-markered files, apply semantic
#                           judgment per the git-reconcile-intent skill,
#                           and edit the files in place to clear the
#                           markers. Returns 0 when every passed-in file
#                           is conflict-marker-free after the call;
#                           non-zero when markers remain or claude is
#                           unavailable. Used by the L1-L5 ladder in
#                           auto-rebase-pools-after-dev-merge.sh.
#
#   claude_render_spec    - Invokes `claude -p` (read-only allowlist) with a
#                           system prompt that names the how-git ticket spec
#                           (title shape, kind allowlist, body shape, bullet
#                           rules, em-dash ban, no fabricated JIRA codes) and
#                           a single operator-supplied natural-language
#                           description plus any prior operator answers to
#                           prior gap questions. Claude returns ONE of:
#                           (a) a JSON payload { title, body, kind, sprint? }
#                           on success; (b) one or more lines starting with
#                           QUESTION: when senior-engineer judgment detects
#                           gaps in the description that the spec cannot
#                           paper over. Returns 0 with the raw claude reply
#                           on stdout; non-zero on claude failure / missing
#                           CLI / parse failure. The caller composes the
#                           question loop (read operator answers, re-invoke)
#                           and the JSON parse. Test-mode bypass writes a
#                           canned reply driven by CLAUDE_RENDER_TEST_REPLY.
#
# Source via:
#   SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
#   . "$SCRIPT_DIR/_lib.sh"

# Commit identity from the origin's GitHub org (scripts/lib/identity.sh).
# Exported at source time, unless the caller already exported one, so the
# allocator, claim scripts and every git write they spawn commit as the
# mapped identity instead of the machine's global git config.
# shellcheck source=./lib/identity.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/identity.sh"
identity_export_if_unset

# Idempotent core.hooksPath self-install. Silent unless a change is made.
ensure_hooks_path() {
  local expected="${HOOKS_PATH_OVERRIDE:-.io.v4rian.how-git/githooks}"
  local current
  current=$(git config core.hooksPath 2>/dev/null || true)
  if [ "$current" != "$expected" ]; then
    git config core.hooksPath "$expected"
    echo "→ activated git hooks (core.hooksPath = $expected)"
  fi
  ensure_merge_hook_fallback
  ensure_repo_alias
}

# Idempotent local git alias install. `git v4r <subcmd> [args...]`
# dispatches to in-repo scripts so users never have to type the long
# bash invocation. Subcommands: openPR, heal, verify, claim-dev, claim-main.
#
# The alias is named v4r (not repo) because modern git ships a builtin
# `git repo` subcommand that preempts user aliases of the same name.
# Also removes any stale alias.repo from a prior template revision so
# upgrades cleanly migrate.
ensure_repo_alias() {
  # Body is POSIX sh: git executes "!" aliases via /bin/sh which is dash on
  # Linux (bash 3.2+ on macOS). The previous ${@:2} bash-only slice was a
  # source of dash incompatibility. shift + "$@" works in dash, bash,
  # zsh, ksh, ash.
  local expected_alias='!f() { subcmd="$1"; shift; case "$subcmd" in openPR) bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/open-pr.sh" "$@";; heal) bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/heal.sh" "$@";; verify|verify-template) bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/verify-template.sh" "$@";; claim-dev|claim-dev-merge) bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/claim-dev-merge.sh" "$@";; claim-main|claim-main-release) bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/claim-main-release.sh" "$@";; *) echo "git v4r <openPR|heal|verify|claim-dev|claim-main> [args]" >&2; exit 2;; esac; }; f'
  local current
  current=$(git config alias.v4r 2>/dev/null || true)
  if [ "$current" != "$expected_alias" ]; then
    git config alias.v4r "$expected_alias"
    echo "→ installed git alias: 'git v4r <openPR|heal|verify|claim-dev|claim-main>'"
  fi
  # Migration: clear any stale alias.repo from a prior template revision.
  if git config alias.repo >/dev/null 2>&1; then
    git config --unset alias.repo
  fi
}

# Run an in-repo Claude skill via the `claude` CLI. Skills live at
# .io.v4rian.how-git/skills/<skill>/SKILL.md so they ride with the repo
# and can be updated per-project without a global Claude reinstall.
#
# Auditing is OPTIONAL - if `claude` is not installed (i.e. the consumer
# isn't using Claude Code), this function logs a note and returns 0 so
# the hook doesn't block on a missing-dependency basis. When `claude`
# IS installed, the skill output is expected to contain `AUDIT_PASS`
# (success) or `AUDIT_FAIL: <reason>` (failure); failure returns
# non-zero which the calling hook should propagate to block the git op.
#
# Usage: claude_skill_run <skill-name> <one-line context for the audit>
# Join on the backgrounded claude install (ci-dispatch.yml starts it nohup'd
# with a /tmp/.claude-install.done marker) so PR-facing signals don't wait
# behind the ~25s install. No-op when claude is already on PATH or no
# background install is running (local operator shells).
ensure_claude_ready() {
  command -v claude >/dev/null 2>&1 && return 0
  # Only join on the background install when one was actually launched:
  # ci-dispatch.yml creates /tmp/.claude-install.log the moment it starts the
  # nohup'd install. With no install underway (local operator shells, offline
  # tests) the .done marker never arrives, so waiting for it stalls for the
  # full 90 x 2s = 180s before falling through. Gate the wait on the log so
  # those contexts return immediately.
  if [ -f /tmp/.claude-install.log ]; then
    local i
    for i in $(seq 1 90); do
      [ -f /tmp/.claude-install.done ] && break
      sleep 2
    done
    command -v claude >/dev/null 2>&1 && return 0
  fi
  [ -x "$HOME/.local/bin/claude" ] && { export PATH="$HOME/.local/bin:$PATH"; return 0; }
  return 1
}

# User-space skill override / expansion. A per-user tree (default
# ~/.config/how-git/skills/<name>/SKILL.md, override the root with
# HOW_GIT_USER_SKILLS_DIR) can REPLACE any in-repo audit skill by name or
# ADD new ones, without touching the vendored copy. Every consumer that
# points claude at a skill resolves through here: user-space wins when the
# named skill exists there, else the in-repo copy answers.

user_skills_dir() {
  printf '%s\n' "${HOW_GIT_USER_SKILLS_DIR:-$HOME/.config/how-git/skills}"
}

resolve_skill() {
  local name="$1" repo_root user_path
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  user_path="$(user_skills_dir)/$name/SKILL.md"
  if [ -f "$user_path" ]; then
    printf '%s\n' "$user_path"
    return 0
  fi
  printf '%s\n' "$repo_root/.io.v4rian.how-git/skills/$name/SKILL.md"
}

# Expansion half: user-space skills with names the in-repo tree does not
# carry, one SKILL.md path per line. Consumers append these to the skill
# set they point claude at.
list_user_extra_skills() {
  local repo_root d name
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  for d in "$(user_skills_dir)"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    name=$(basename "$d")
    [ -f "$repo_root/.io.v4rian.how-git/skills/$name/SKILL.md" ] && continue
    printf '%s\n' "${d}SKILL.md"
  done 2>/dev/null
  return 0
}

claude_skill_run() {
  local skill="$1"
  local context="$2"
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  local skill_path
  skill_path=$(resolve_skill "$skill")

  # Test-mode escape hatch: tests set LIFECYCLE_TEST_MODE=1 to bypass
  # the real (slow + network-bound) claude invocation and just log the
  # would-be call. Hook wiring is verified separately by static
  # inspection in test-lifecycle.sh.
  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    echo "  · [test-mode] would invoke claude $skill audit (skill_path=$skill_path)" >&2
    return 0
  fi

  ensure_claude_ready || true
  if ! command -v claude >/dev/null 2>&1; then
    echo "  · claude CLI not installed; skipping $skill audit (install Claude Code to enable)" >&2
    return 0
  fi
  if [ ! -f "$skill_path" ]; then
    echo "  · skill file $skill_path not found; skipping $skill audit" >&2
    return 0
  fi

  local prompt
  prompt="Audit the current git state against the rules in $skill_path. Context: $context. After auditing, output exactly 'AUDIT_PASS' on a line by itself if the audit passes, or 'AUDIT_FAIL: <reason>' if it fails. Be terse."
  echo "  → running $skill audit via claude (this may take a few seconds)" >&2
  local output
  local rc=0
  output=$(claude -p "$prompt" </dev/null 2>&1) || rc=$?
  if printf '%s\n' "$output" | grep -q '^AUDIT_FAIL'; then
    echo "✗ $skill: $(printf '%s\n' "$output" | grep '^AUDIT_FAIL' | head -1)" >&2
    return 1
  fi
  # Fail closed on the verdict: only an explicit AUDIT_PASS line is a pass.
  # A login prompt, a CLI error or any other answer is reported as SKIPPED
  # with its first line, never as passed (friction ledger FP-04).
  if [ "$rc" -eq 0 ] && printf '%s\n' "$output" | grep -q '^AUDIT_PASS'; then
    echo "  ✓ $skill passed" >&2
    return 0
  fi
  echo "  ! $skill audit SKIPPED (no verdict; claude rc=$rc): $(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | head -1 | cut -c1-160)" >&2
  return 0
}

# Invoke claude to resolve cherry-pick conflict markers in the working
# tree by editing the affected files in place. Each L-tier of the
# auto-rebase ladder calls this with a tier-specific intent prompt so
# the claude pass can apply the git-reconcile-intent skill's hunk-level
# allocation discipline with the right context for the tier. Claude is
# the one editing the files; the script only verifies the markers were
# cleared and returns the outcome.
#
# Arguments:
#   $1 = tier label (L1..L5) for logging
#   $2 = full prompt body to pass on stdin to claude. Caller composes
#        this with: the active requirement, the tier-specific intent,
#        the conflicting commit's message, the diff snippets, the
#        list of conflicting files, and the rule that claude must EDIT
#        the files in place (not print a patch) and emit either
#        RESOLVED on success or UNRESOLVED: <reason> on failure.
#   $3 = space-separated list of conflicting file paths (relative to
#        the worktree root) to verify after the call. Pass empty for
#        L5 surface-only mode (skips the marker-cleared check).
#
# Returns:
#   0 when the claude pass reported RESOLVED AND every listed file is
#     conflict-marker-free (i.e. no <<<<<<< / ======= / >>>>>>> lines).
#   2 when claude surfaced the unresolved hunks for the admin (L5
#     surface-only outcome); markers may still be present.
#   1 in every other case (claude unavailable, UNRESOLVED reply,
#     markers still present, missing files).
#
# Test-mode (LIFECYCLE_TEST_MODE=1) substitutes a canned behavior:
#   if the env var CLAUDE_RESOLVE_TEST_OUTCOME is set, that drives the
#   outcome (RESOLVED|UNRESOLVED|SURFACE). For RESOLVED the helper
#   strips conflict markers from each listed file by keeping the
#   "incoming" hunk between ======= and >>>>>>> (a deterministic
#   substitute for claude's judgment so the lifecycle suite can
#   exercise the ladder wiring without a network call). Default is
#   RESOLVED so existing tests that don't set the env var keep
#   passing.
claude_resolve_conflict() {
  local tier="$1"
  local prompt="$2"
  local files="$3"

  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    local outcome="${CLAUDE_RESOLVE_TEST_OUTCOME:-RESOLVED}"
    echo "  · [test-mode] claude_resolve_conflict ${tier} outcome=${outcome} files=[${files}]" >&2
    case "$outcome" in
      SURFACE)
        # Production semantic: claude tries L1-L4 to resolve, fails to
        # find a hunk-allocation that preserves both intents, and at L5
        # switches to surface-not-resolve and names the unresolved
        # hunks for the admin. The surrogate models this by returning
        # rc=1 (UNRESOLVED) for L1-L4 so the ladder escalates cleanly,
        # then rc=2 (SURFACE) at L5 so the partial reconcile branch
        # pushes as a receipt. The caller treats rc=2 as "claude
        # surfaced", distinct from a hard failure.
        if [ "$tier" = "L5" ]; then
          return 2
        fi
        return 1
        ;;
      UNRESOLVED)
        return 1
        ;;
      RESOLVED|*)
        # Deterministic test substitute for claude's edits: for each file,
        # collapse conflict markers by keeping the incoming side (the
        # part between ======= and >>>>>>>). This is a stand-in for the
        # judgment claude would apply, not the judgment itself.
        local f
        for f in $files; do
          [ -f "$f" ] || continue
          python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
with open(p, 'r', encoding='utf-8', errors='replace') as fh:
    lines = fh.read().splitlines(keepends=True)
out = []
mode = "normal"
for ln in lines:
    if ln.startswith("<<<<<<<"):
        mode = "ours"
        continue
    if ln.startswith("======="):
        mode = "theirs"
        continue
    if ln.startswith(">>>>>>>"):
        mode = "normal"
        continue
    if mode == "normal" or mode == "theirs":
        out.append(ln)
with open(p, 'w', encoding='utf-8') as fh:
    fh.writelines(out)
PY
        done
        return 0
        ;;
    esac
  fi

  ensure_claude_ready || true
  if ! command -v claude >/dev/null 2>&1; then
    echo "  · claude CLI not installed; ${tier} cannot run semantic resolution" >&2
    return 1
  fi

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  local reconcile_skill
  reconcile_skill=$(resolve_skill git-reconcile-intent)
  local skill_ref=""
  if [ -f "$reconcile_skill" ]; then
    skill_ref=" Apply the lens at $reconcile_skill (hunk-level allocation, never silent override)."
  fi

  echo "  -> ${tier} invoking claude for semantic resolution (this may take a few seconds)" >&2
  local prompt_file output rc
  prompt_file=$(mktemp -t claude-resolve.XXXXXX)
  printf '%s%s\n' "$prompt" "$skill_ref" > "$prompt_file"

  # --permission-mode acceptEdits + explicit allowlist of file-edit tools
  # lets claude Read/Edit/Write the working-tree files without prompting.
  # We pipe the prompt on stdin to keep argv small and avoid quoting
  # surprises with long contexts.
  output=$(claude -p \
    --permission-mode acceptEdits \
    --allowedTools "Read,Edit,Write,Glob,Grep,Bash(git diff:*),Bash(git status:*),Bash(git log:*),Bash(git show:*)" \
    < "$prompt_file" 2>&1)
  rc=$?
  rm -f "$prompt_file"

  if [ "$rc" -ne 0 ]; then
    echo "  ! ${tier} claude exited rc=$rc" >&2
    printf '%s\n' "$output" | head -10 >&2
    return 1
  fi

  # Parse the claude reply for the canonical tokens. UNRESOLVED is an
  # explicit failure signal; SURFACE is L5's "I named the conflicts
  # for the admin but did not edit" outcome (treated as 2 so the
  # caller can distinguish from a hard failure).
  if printf '%s' "$output" | grep -qE '^[[:space:]]*SURFACE\b'; then
    echo "  · ${tier} claude surfaced (admin review required); markers preserved" >&2
    return 2
  fi
  if printf '%s' "$output" | grep -qE '^[[:space:]]*UNRESOLVED\b'; then
    echo "  · ${tier} claude reported UNRESOLVED" >&2
    return 1
  fi

  # Verify markers actually cleared in the working tree. Claude may have
  # claimed RESOLVED but missed a hunk; the file check is the gate.
  if [ -n "$files" ]; then
    local f
    for f in $files; do
      [ -f "$f" ] || { echo "  ! ${tier} listed file missing: $f" >&2; return 1; }
      if grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$f" 2>/dev/null; then
        echo "  ! ${tier} conflict markers still present in $f after claude pass" >&2
        return 1
      fi
    done
  fi
  return 0
}

# Invoke claude as a senior engineer to convert an operator's natural-language
# ticket description into a how-git-spec ticket payload. Used by
# bin/jira-ingress in claude-driven mode so an operator can file a JIRA
# ticket from a casual prompt without composing the title / body / kind by
# hand. The function does not own the question loop; the caller drives that
# loop. Each call is a single round-trip: caller passes the original prompt
# plus any prior operator answers (verbatim), claude either returns the
# rendered JSON payload OR surfaces QUESTION: lines for gaps it cannot infer
# from senior-engineer judgment. Both outputs land on stdout for the caller
# to parse.
#
# The system prompt names the how-git spec by reference to in-repo skill
# files (so the prompt does not need to inline every rule); claude is
# expected to fetch them via the Read tool when needed.
#
# Arguments:
#   $1 = original operator prompt (verbatim natural-language description)
#   $2 = prior context (optional; previous QUESTION/ANSWER pairs as a single
#        text block, separated by newlines; empty string on first call)
#
# Stdout: the raw claude reply (either a JSON payload OR one or more
#   QUESTION: lines). Caller parses.
#
# Return codes:
#   0 on a successful claude invocation (the reply itself may still be a
#     QUESTION: line set, and the caller decides whether that is success
#     or a gap to surface).
#   1 on claude CLI absence / invocation failure / empty reply.
#
# Test-mode (LIFECYCLE_TEST_MODE=1): substitutes the value of
# CLAUDE_RENDER_TEST_REPLY (read from env) as the claude reply, so the
# lifecycle suite can drive the helper's downstream parsing + question loop
# behavior without a network call. Default reply is a minimal JSON payload
# the parser can consume so tests that don't set the env var still pass.
claude_render_spec() {
  local prompt="$1"
  local prior_context="${2:-}"

  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    local canned="${CLAUDE_RENDER_TEST_REPLY:-}"
    if [ -z "$canned" ]; then
      canned='{"title":"[NEW] Probe canned spec render under test mode","body":"Probe canned body paragraph rendered under LIFECYCLE_TEST_MODE for the jira-ingress claude pass.\n\nChanges:\n  - probe.txt\n    - notes the canned render.","kind":"feature"}'
    fi
    printf '%s\n' "$canned"
    return 0
  fi

  ensure_claude_ready || true
  if ! command -v claude >/dev/null 2>&1; then
    echo "  · claude CLI not installed; cannot render ticket spec from natural-language prompt" >&2
    return 1
  fi

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  local commit_audit_skill strategy_audit_skill
  commit_audit_skill=$(resolve_skill git-commit-audit)
  strategy_audit_skill=$(resolve_skill git-strategy-audit)

  local system_prompt
  system_prompt=$(cat <<'SYS'
You are a senior engineer composing a JIRA ticket to v4rian/how-git spec from an operator's casual natural-language description. The ticket will be filed via the jira CLI; sprint routing is the caller's job, not yours.

The how-git ticket spec is the same spec git-commit-audit and git-strategy-audit enforce on commits and branches. Apply these rules verbatim:

Title:
  - Shape: [TAG] Subject in sentence case (no JIRA prefix; ingress fills the JIRA segment when needed).
  - Approved tags (case-sensitive): [FIX], [NEW], [REFACTOR], [DOCS], [TEST], [REVERT], [HOTFIX].
  - [NEW] only for genuinely new files / classes / integrations / subsystems / dependencies / operator workflows. Helper methods inside an existing class -> [REFACTOR]. Bug repair -> [FIX] or [HOTFIX].
  - Length: 8 to 72 chars total (including the tag).
  - Banned in title prose: em-dashes (the long horizontal dash), the literal word "plus", "and"/"with"/"+"/"," joiners that signal a non-atomic change. Hyphens in identifiers and English compounds are fine.

Body:
  - First a 1-3 sentence description paragraph at subsystem / class altitude. Title says WHAT; description says WHY and at WHAT SCOPE; bullets say HOW.
  - For [FIX] / [HOTFIX]: after the description, a "Cause:" paragraph then a "Fix:" paragraph then a "Changes:" block.
  - For every other tag: after the description, a "Changes:" block.
  - "Changes:" block format: nested bullets, top-level lists a class / module name (NOT a path), methods indent under the class. Verbs third-person present tense (Normalizes, Sends, Schedules). Never bullet fields / properties / vars / constants. Never fabricate symbol names.
  - Banned in body prose: em-dashes, the literal word "plus".
  - No "Co-Authored-By:" trailer.
  - Forbidden anywhere: BAK, bak import, historical import, recovered from, reconstructed, WIP snapshot, captured in, from the zip.

Kind (separate field from tag; used by the allocator):
  - Allowed values: feature, fix, refactor, r&d, doc.
  - Map [NEW] -> feature; [FIX] / [HOTFIX] -> fix; [REFACTOR] -> refactor; [DOCS] -> doc.
  - "r&d" only when the description describes exploration with no committed outcome (spike, prototype, investigation).

JIRA code:
  - Never invent a JIRA code. The ingress CLI handles filing; you only compose the ticket contents.

Reply contract (CRITICAL):
  You return EXACTLY ONE of the following two shapes on stdout, and nothing else:

  (A) On success, a single-line JSON object on its own line:
        {"title":"[TAG] Subject in sentence case","body":"Description paragraph.\\n\\nChanges:\\n  - ClassName\\n    - methodA does X.\\n    - methodB does Y.","kind":"feature"}
      The body MUST use \\n escape sequences (literal backslash-n in the JSON string) so it is a single line. The "kind" value MUST be one of: feature, fix, refactor, r&d, doc. Do not add explanatory text before or after.

  (B) On a gap that senior-engineer judgment cannot paper over from the description alone, ONE OR MORE lines each starting with the literal token "QUESTION:" followed by the gap question phrased to the operator. Example:
        QUESTION: which subsystem does "the parser" refer to here? Inline allocator parser, or the requirement-file parser?
        QUESTION: is this a bug repair (use [FIX]) or a new feature (use [NEW])?
      Surface questions ONLY when the description leaves a gap a senior engineer cannot reasonably infer. Do not invent gaps to look thorough.

Do NOT mix the two shapes. Do NOT add markdown fences, prefatory text, or trailing commentary. The caller parses your reply with a strict regex / json.load; extra text breaks it.
SYS
)

  local user_prompt
  user_prompt=$(printf 'Original operator description:\n%s\n' "$prompt")
  if [ -n "$prior_context" ]; then
    user_prompt=$(printf '%s\nPrior operator answers to your earlier questions (verbatim):\n%s\n' \
      "$user_prompt" "$prior_context")
  fi

  local full_prompt
  full_prompt=$(printf '%s\n\nRefer to these in-repo skills for the canonical spec:\n  %s\n  %s\n\n%s' \
    "$system_prompt" "$commit_audit_skill" "$strategy_audit_skill" "$user_prompt")

  local prompt_file output rc
  prompt_file=$(mktemp -t claude-render.XXXXXX)
  printf '%s\n' "$full_prompt" > "$prompt_file"

  # Read-only allowlist: the helper never edits the working tree; it just
  # composes ticket text. Read/Grep/Glob suffice for fetching the in-repo
  # skill files when claude wants to ground its judgment in the canonical
  # spec.
  output=$(claude -p \
    --permission-mode acceptEdits \
    --allowedTools "Read,Glob,Grep" \
    < "$prompt_file" 2>&1)
  rc=$?
  rm -f "$prompt_file"

  if [ "$rc" -ne 0 ]; then
    echo "  ! claude_render_spec: claude exited rc=$rc" >&2
    printf '%s\n' "$output" | head -10 >&2
    return 1
  fi

  if [ -z "$output" ]; then
    echo "  ! claude_render_spec: empty claude reply" >&2
    return 1
  fi

  printf '%s\n' "$output"
  return 0
}


# Apply the git-commit-audit lens semantically to a single commit by
# invoking `claude -p` with the SKILL.md body as the system context and
# the commit's subject, full message, and diff as the audit subject.
# The structural lens (atomicity surface, title regex, body shape,
# bullet style, file hygiene) already runs as deterministic shell
# checks elsewhere; this pass adds the judgment layer that catches:
#
#   - tag fit: [NEW] vs [FIX] vs [REFACTOR] boundary per the rules
#     in section B of the lens and feedback_tag_new_for_genuine_new_features
#   - fabrication: bullets naming methods/symbols that do not exist
#     in the committed tree (feedback_commit_no_fabrication)
#   - non atomic mixing: ≥2 unrelated concepts buried in one commit
#   - body vs diff contradiction: the body paragraph or bullets
#     describe behavior the diff does not implement
#
# Arguments:
#   $1 = commit SHA (must be reachable from the current repo)
#   $2 = path to the git-commit-audit SKILL.md file (the lens body)
#
# Returns:
#   0 on AUDIT_PASS (or canned PASS in test mode / missing-key fallback)
#   1 on AUDIT_FAIL (claude reported a violation; reason flows to stderr)
#
# Test mode + missing-credential semantics:
#   LIFECYCLE_TEST_MODE=1     bypass real call; emit canned PASS banner.
#   COMMIT_AUDIT_DRY_RUN=1    print the planned invocation; return 0.
#   No claude CLI on PATH     return 0 with a visible WARN banner on
#                             stderr; the structural lens stays the gate.
#   No claude credential      same WARN-and-pass behavior. The helper
#                             accepts either CLAUDE_CODE_OAUTH_TOKEN
#                             (the Max-plan OAuth token from `claude
#                             setup-token`, preferred when both are set)
#                             or ANTHROPIC_API_KEY (the direct API key);
#                             both absent means the operator chose to
#                             ship without the semantic layer (e.g.
#                             local pushes, forks without secrets).
#
# Stdin/stdout contract:
#   Claude is expected to reply with one of:
#     - A line starting with AUDIT_PASS (audit ok)
#     - A line starting with AUDIT_FAIL: <named violation>
#   Anything unparseable is treated as PASS to avoid blocking on
#   transient API errors, same conservative posture as the prior
#   inline call and as claude_resolve_conflict's RESOLVED check.
claude_judge_commit() {
  local sha="$1"
  local skill_path="$2"

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

  local subj msg diff
  subj=$(git -C "$repo_root" log -1 --format='%s' "$sha" 2>/dev/null || true)
  msg=$(git -C "$repo_root" log -1 --format='%B' "$sha" 2>/dev/null || true)
  diff=$(git -C "$repo_root" show --no-color --no-renames "$sha" 2>/dev/null || true)

  if [ -z "$subj" ]; then
    echo "  ! claude_judge_commit: cannot resolve commit $sha" >&2
    return 1
  fi

  # Test-mode short-circuit: the lifecycle suite exercises the wiring
  # without paying for a real API call. Honor an env-driven outcome so
  # tests can also exercise the AUDIT_FAIL branch.
  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    local outcome="${CLAUDE_JUDGE_TEST_OUTCOME:-PASS}"
    case "$outcome" in
      FAIL)
        echo "X commit-audit [FAIL canned] $sha $subj" >&2
        echo "AUDIT_FAIL: canned test-mode outcome" >&2
        return 1
        ;;
      PASS|*)
        echo "  · [test-mode] claude_judge_commit $sha outcome=PASS"
        return 0
        ;;
    esac
  fi

  if [ "${COMMIT_AUDIT_DRY_RUN:-}" = "1" ]; then
    echo "[dry-run] would invoke claude_judge_commit (sha=$sha, subj_len=${#subj})"
    return 0
  fi

  # Missing-CLI fallback: visible WARN banner on stderr so the CI log
  # surfaces the gap, but exit 0 so the push is not blocked. The
  # structural lens that runs alongside this call (the deterministic
  # shell checks in pre-commit / pre-push / audit-pushed-branch) is
  # still the hard gate; the claude pass is the semantic layer on
  # top, not the only line of defense.
  ensure_claude_ready || true
  if ! command -v claude >/dev/null 2>&1; then
    echo "  ! commit-audit WARN: claude CLI unavailable; semantic layer skipped for $sha (structural lens still applies)" >&2
    return 0
  fi

  # Missing-credential fallback: same visible WARN posture. CI binds
  # CLAUDE_CODE_OAUTH_TOKEN (preferred, Max-plan OAuth) or
  # ANTHROPIC_API_KEY (direct API key) via the standard repo secrets;
  # both empty almost always means a fork or a local push where the
  # operator accepted shipping without the semantic layer.
  if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "  ! commit-audit WARN: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set; semantic layer skipped for $sha (structural lens still applies)" >&2
    return 0
  fi

  if [ ! -f "$skill_path" ]; then
    echo "  ! commit-audit WARN: skill file $skill_path missing; semantic layer skipped for $sha" >&2
    return 0
  fi

  local skill_body
  skill_body=$(cat "$skill_path" 2>/dev/null || true)

  # Compose the prompt. The lens body goes first as the system context;
  # the commit triple (subject, message, diff) follows as the audit
  # subject; the closing rubric pins the reply tokens so the parser is
  # deterministic. printf via %s keeps the body intact even when it
  # contains backslashes or percent signs.
  local prompt_file output rc
  prompt_file=$(mktemp -t claude-judge-commit.XXXXXX)
  {
    printf 'You are applying the git-commit-audit lens to a single commit.\n\n'
    printf 'LENS BODY (treat as authoritative):\n%s\n\n' "$skill_body"
    printf 'COMMIT UNDER AUDIT:\n\n'
    printf 'SHA: %s\n' "$sha"
    printf 'Subject: %s\n\n' "$subj"
    printf 'Full message:\n%s\n\n' "$msg"
    printf 'Diff:\n%s\n\n' "$diff"
    printf 'Apply sections A through I of the lens. Focus the judgment layer on:\n'
    printf '  - tag fit ([NEW] vs [FIX] vs [REFACTOR] vs [DOCS] boundary)\n'
    printf '  - fabrication (any method, class, or symbol named in a bullet must exist in the committed tree)\n'
    printf '  - non atomic mixing (≥2 unrelated concepts in one commit)\n'
    printf '  - body vs diff contradiction (paragraph or bullets describe behavior the diff does not implement)\n'
    printf '  - receipts (section J): a body asserting observed behavior (measured, verified, reproduces, a Cause narrative, a Fix outcome, quoted numbers) must carry a Receipts: section naming the verifying artifact; flag the unreceipted claim as AUDIT_FAIL receipts. Commits making no behavioral claims need no Receipts: section.\n\n'
    printf 'Reply with exactly one of:\n'
    printf '  AUDIT_PASS\n'
    printf '  AUDIT_FAIL: <named violation, one short sentence>\n'
  } > "$prompt_file"

  echo "  -> commit-audit invoking claude_judge_commit for $sha (this may take a few seconds)" >&2
  # Read-only inspection tools: claude needs git inspection to confirm
  # symbol existence (the V.10 verification recipes in the lens) but
  # must not edit anything. Mirroring the claude_resolve_conflict
  # invocation shape keeps the call surface consistent across the
  # toolchain.
  #
  # Credential precedence: when CLAUDE_CODE_OAUTH_TOKEN is present, it
  # is the preferred authenticator (the operator's Max-plan subscription
  # draws from the plan's quota rather than billed API spend). Unset
  # ANTHROPIC_API_KEY in the subshell so the claude CLI sees only the
  # OAuth token and routes the request through the subscription path
  # even when both secrets happen to be bound on the runner.
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    output=$(unset ANTHROPIC_API_KEY; claude -p \
      --permission-mode acceptEdits \
      --allowedTools "Read,Glob,Grep,Bash(git diff:*),Bash(git show:*),Bash(git log:*),Bash(git rev-parse:*),Bash(grep:*)" \
      < "$prompt_file" 2>&1)
  else
    output=$(claude -p \
      --permission-mode acceptEdits \
      --allowedTools "Read,Glob,Grep,Bash(git diff:*),Bash(git show:*),Bash(git log:*),Bash(git rev-parse:*),Bash(grep:*)" \
      < "$prompt_file" 2>&1)
  fi
  rc=$?
  rm -f "$prompt_file"

  if [ "$rc" -ne 0 ]; then
    echo "  ! commit-audit WARN: claude exited rc=$rc for $sha; treating as PASS to avoid blocking on transient errors" >&2
    printf '%s\n' "$output" | head -5 >&2
    return 0
  fi

  if printf '%s' "$output" | grep -qE '^[[:space:]]*AUDIT_FAIL\b'; then
    echo "X commit-audit [FAIL] $sha $subj" >&2
    printf '%s' "$output" | grep -E '^[[:space:]]*AUDIT_FAIL' | head -1 >&2
    return 1
  fi
  if printf '%s' "$output" | grep -qE '^[[:space:]]*AUDIT_PASS\b'; then
    echo "  ✓ commit-audit [PASS] $sha $subj"
    return 0
  fi

  echo "  ! commit-audit WARN: claude reply was unparseable for $sha; treating as PASS" >&2
  printf '%s\n' "$output" | head -5 >&2
  return 0
}

# claude_judge_commit_range - batched sibling of claude_judge_commit that
# spins up `claude -p` EXACTLY ONCE for the WHOLE push range instead of
# once per commit. The per-commit judgment is preserved verbatim: the
# same lens body, the same SHA/Subject/Full-message/Diff triple per
# commit, and one PASS/FAIL verdict per commit. Only the process count
# changes - N commits cost one process, not N.
#
# Arguments:
#   $1  newline-separated list of SHAs (the resolved push range)
#   $2  path to the git-commit-audit SKILL.md lens
#
# Reply contract (per commit, exactly one line each):
#   AUDIT_PASS <sha>
#   AUDIT_FAIL <sha>: <one-sentence named violation>
#
# Parsing posture mirrors the per-commit helper: any sha whose verdict
# line is missing or unparseable is treated as PASS with a WARN, so a
# parse miss never red-checks a push. Returns non-zero if ANY commit's
# verdict is AUDIT_FAIL, 0 otherwise.
#
# Fallbacks mirror claude_judge_commit exactly:
#   LIFECYCLE_TEST_MODE=1   canned outcome (CLAUDE_JUDGE_TEST_OUTCOME:
#                           FAIL => emit AUDIT_FAIL for the range + rc=1,
#                           else PASS + rc=0). No network round trip.
#   COMMIT_AUDIT_DRY_RUN=1  print a SINGLE planned-invocation line naming
#                           the commit count, then return 0.
#   no claude CLI / no creds / no skill  WARN + return 0 so a missing
#                           dependency never blocks the push; the
#                           structural lens stays the hard gate.
claude_judge_commit_range() {
  local shas_raw="$1"
  local skill_path="$2"

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

  # Normalize the input into a clean array of non-empty SHAs (bash 3.2
  # safe - no mapfile). COUNT drives the dry-run line and the test-mode
  # banners; the array drives parsing and per-commit reporting.
  local shas=()
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    shas+=("$s")
  done <<< "$shas_raw"
  local count="${#shas[@]}"

  if [ "$count" -eq 0 ]; then
    return 0
  fi

  # Test-mode short-circuit: the lifecycle suite exercises the wiring
  # without paying for a real API call. Honor the same env-driven outcome
  # as claude_judge_commit so tests can exercise both verdict branches,
  # but emit a SINGLE range-level banner rather than per-commit lines so
  # the single-invocation contract is visible in the canned path too.
  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    local outcome="${CLAUDE_JUDGE_TEST_OUTCOME:-PASS}"
    case "$outcome" in
      FAIL)
        echo "X commit-audit [FAIL canned] range of $count commit(s)" >&2
        echo "AUDIT_FAIL: canned test-mode outcome for range" >&2
        return 1
        ;;
      PASS|*)
        echo "  · [test-mode] claude_judge_commit_range $count commit(s) outcome=PASS"
        return 0
        ;;
    esac
  fi

  if [ "${COMMIT_AUDIT_DRY_RUN:-}" = "1" ]; then
    echo "[dry-run] would invoke claude_judge_commit_range ONCE for $count commit(s)"
    return 0
  fi

  # Missing-CLI fallback: visible WARN banner on stderr, exit 0 so the
  # push is not blocked. Mirrors the per-commit helper's posture; the
  # deterministic structural lens stays the hard gate.
  ensure_claude_ready || true
  if ! command -v claude >/dev/null 2>&1; then
    echo "  ! commit-audit WARN: claude CLI unavailable; semantic layer skipped for range of $count commit(s) (structural lens still applies)" >&2
    return 0
  fi

  # Missing-credential fallback: same visible WARN posture as the
  # per-commit helper. CI binds CLAUDE_CODE_OAUTH_TOKEN (preferred) or
  # ANTHROPIC_API_KEY; both empty means a fork or local push.
  if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "  ! commit-audit WARN: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set; semantic layer skipped for range of $count commit(s) (structural lens still applies)" >&2
    return 0
  fi

  if [ ! -f "$skill_path" ]; then
    echo "  ! commit-audit WARN: skill file $skill_path missing; semantic layer skipped for range of $count commit(s)" >&2
    return 0
  fi

  local skill_body
  skill_body=$(cat "$skill_path" 2>/dev/null || true)

  # Compose a SINGLE prompt: the lens body ONCE, then the per-commit
  # triple for every SHA, then a rubric that pins exactly one verdict
  # line per commit so the parser is deterministic.
  local prompt_file output rc
  prompt_file=$(mktemp -t claude-judge-commit-range.XXXXXX)
  {
    printf 'You are applying the git-commit-audit lens to a BATCH of commits in one pass.\n\n'
    printf 'LENS BODY (treat as authoritative):\n%s\n\n' "$skill_body"
    printf 'COMMITS UNDER AUDIT (%s total):\n\n' "$count"
    local sha subj msg diff
    for sha in ${shas[@]+"${shas[@]}"}; do
      subj=$(git -C "$repo_root" log -1 --format='%s' "$sha" 2>/dev/null || true)
      msg=$(git -C "$repo_root" log -1 --format='%B' "$sha" 2>/dev/null || true)
      diff=$(git -C "$repo_root" show --no-color --no-renames "$sha" 2>/dev/null || true)
      printf '========================================\n'
      printf 'SHA: %s\n' "$sha"
      printf 'Subject: %s\n\n' "$subj"
      printf 'Full message:\n%s\n\n' "$msg"
      printf 'Diff:\n%s\n\n' "$diff"
    done
    printf '========================================\n\n'
    printf 'Apply sections A through I of the lens to EACH commit independently. Focus the judgment layer on:\n'
    printf '  - tag fit ([NEW] vs [FIX] vs [REFACTOR] vs [DOCS] boundary)\n'
    printf '  - fabrication (any method, class, or symbol named in a bullet must exist in the committed tree)\n'
    printf '  - non atomic mixing (>=2 unrelated concepts in one commit)\n'
    printf '  - body vs diff contradiction (paragraph or bullets describe behavior the diff does not implement)\n'
    printf '  - receipts (section J): a body asserting observed behavior (measured, verified, reproduces, a Cause narrative, a Fix outcome, quoted numbers) must carry a Receipts: section naming the verifying artifact; flag the unreceipted claim as AUDIT_FAIL receipts. Commits making no behavioral claims need no Receipts: section.\n\n'
    printf 'Reply with EXACTLY ONE verdict line PER commit, using the commit SHA so the parser can match each verdict to its commit:\n'
    printf '  AUDIT_PASS <sha>\n'
    printf '  AUDIT_FAIL <sha>: <named violation, one short sentence>\n'
    printf 'Emit one line for every SHA listed above and nothing else on those lines.\n'
  } > "$prompt_file"

  echo "  -> commit-audit invoking claude_judge_commit_range ONCE for $count commit(s) (this may take a few seconds)" >&2
  # Same read-only inspection tools + OAuth precedence as
  # claude_judge_commit: when CLAUDE_CODE_OAUTH_TOKEN is present, unset
  # ANTHROPIC_API_KEY in the subshell so the Max-plan OAuth path wins
  # deterministically over API-key billing.
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    output=$(unset ANTHROPIC_API_KEY; claude -p \
      --permission-mode acceptEdits \
      --allowedTools "Read,Glob,Grep,Bash(git diff:*),Bash(git show:*),Bash(git log:*),Bash(git rev-parse:*),Bash(grep:*)" \
      < "$prompt_file" 2>&1)
  else
    output=$(claude -p \
      --permission-mode acceptEdits \
      --allowedTools "Read,Glob,Grep,Bash(git diff:*),Bash(git show:*),Bash(git log:*),Bash(git rev-parse:*),Bash(grep:*)" \
      < "$prompt_file" 2>&1)
  fi
  rc=$?
  rm -f "$prompt_file"

  if [ "$rc" -ne 0 ]; then
    echo "  ! commit-audit WARN: claude exited rc=$rc for range of $count commit(s); treating as PASS to avoid blocking on transient errors" >&2
    printf '%s\n' "$output" | head -5 >&2
    return 0
  fi

  # Parse: for each input SHA, find its verdict line. The lens replies
  # with the SHA on each verdict line so we match on the SHA substring.
  # Per-sha PASS goes to stdout, FAIL to stderr (mirroring the styling of
  # claude_judge_commit). A missing or unparseable verdict for a SHA is a
  # WARN-and-treat-as-PASS, same lenient posture as the per-commit helper.
  local failed=0
  local verdict subj_for_report
  for sha in ${shas[@]+"${shas[@]}"}; do
    subj_for_report=$(git -C "$repo_root" log -1 --format='%s' "$sha" 2>/dev/null || true)
    verdict=$(printf '%s\n' "$output" | grep -E "^[[:space:]]*AUDIT_(PASS|FAIL)[[:space:]:]*$sha" | head -1)
    if [ -z "$verdict" ]; then
      # Fall back to a looser match: any verdict line that names the sha
      # anywhere on the line (the model may prefix or reformat).
      verdict=$(printf '%s\n' "$output" | grep -E "^[[:space:]]*AUDIT_(PASS|FAIL)\b" | grep -F "$sha" | head -1)
    fi
    if [ -z "$verdict" ]; then
      echo "  ! commit-audit WARN: no parseable verdict for $sha; treating as PASS" >&2
      continue
    fi
    if printf '%s' "$verdict" | grep -qE '^[[:space:]]*AUDIT_FAIL\b'; then
      echo "X commit-audit [FAIL] $sha $subj_for_report" >&2
      printf '%s\n' "$verdict" >&2
      failed=$((failed + 1))
    else
      echo "  ✓ commit-audit [PASS] $sha $subj_for_report"
    fi
  done

  if [ "$failed" -gt 0 ]; then
    return 1
  fi
  return 0
}


# v4rian mode accessors. The mode lives in .io.v4rian.how-git/MODE
# and is one of: connected, off-grid. See bin/set-mode for details.

get_mode() {
  local repo_root mode_file
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  mode_file="$repo_root/.io.v4rian.how-git/MODE"
  if [ ! -f "$mode_file" ]; then
    echo "connected"
    return 0
  fi
  tr -d '\n' < "$mode_file"
}

# require_repo_admin TOOL MODE ACTION - the admin gate shared by the
# committed repo-property flips (bin/set-mode, bin/warp,
# bin/set-merge-policy). Connected mode checks the actor's GitHub admin
# permission through the collaborators API and exits 3 when it is not
# admin; off-grid has no enforceable check, so the operator is trusted
# with an advisory warning. LIFECYCLE_TEST_MODE=1 bypasses the gate for
# the offline test rig.
require_repo_admin() {
  local tool="$1" mode="$2" action="$3" origin repo actor perm
  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    echo "! LIFECYCLE_TEST_MODE: admin gate bypassed"
    return 0
  fi
  if [ "$mode" != "connected" ]; then
    echo "! off-grid mode: admin gate is advisory only - trusting the operator"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "X $tool: gh CLI required to verify admin permission in connected mode" >&2
    exit 3
  fi
  origin=$(git config --get remote.origin.url 2>/dev/null || true)
  if [ -z "$origin" ]; then
    echo "X $tool: connected mode but no origin remote configured - inconsistent state" >&2
    exit 3
  fi
  repo=$(echo "$origin" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
  actor=$(gh api /user --jq '.login' 2>/dev/null || echo "")
  [ -z "$actor" ] && { echo "X $tool: gh not authenticated; cannot verify admin permission" >&2; exit 3; }
  perm=$(gh api "repos/${repo}/collaborators/${actor}/permission" --jq '.permission' 2>/dev/null || echo "unknown")
  if [ "$perm" != "admin" ]; then
    echo "X $tool: actor '${actor}' has permission '${perm}' on ${repo} but admin is required to ${action}" >&2
    echo "  Fix, one of:" >&2
    echo "    gh auth switch --user <an admin of ${repo}>   then rerun $tool" >&2
    echo "    ask an admin of ${repo} to run the same .io.v4rian.how-git/bin/$tool command" >&2
    echo "    stay local: .io.v4rian.how-git/bin/set-mode off-grid (needs no GitHub admin)" >&2
    exit 3
  fi
  echo "-> admin gate ok (actor=${actor} permission=${perm})"
}

# SPEC provenance accessors. Consumer repos carry a committed
# .io.v4rian.how-git/SPEC file recording where the vendored framework copy
# came from. It is written only by the vendoring tools (bin/attach,
# bin/sync-framework, bootstrap-ci consumer stamping); the framework source
# repo itself (FRAMEWORK_REPO marker present) never carries SPEC because its
# identity is its own tag chain. SPEC is provenance metadata, not a live
# version file: it never participates in version derivation (tags stay the
# seal per the pool/n10 model). Shape, one key=value per line:
#   source=<clone url or local path of the framework source>
#   ref=<full sha of the source commit the copy was taken from, or unknown>
#   tag=<nearest source tag at that ref, or none>
#   stamped=<UTC timestamp of the stamping operation>

get_spec_field() {
  local field="$1" repo_root spec_file
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  spec_file="$repo_root/.io.v4rian.how-git/SPEC"
  [ -f "$spec_file" ] || return 1
  sed -n "s/^${field}=//p" "$spec_file" | head -1
}

stamp_spec() {
  local source="$1" ref="${2:-unknown}" tag="${3:-none}" repo_root spec_file
  # SPEC is committed: never let a credential in (hg_strip_url_credentials).
  source=$(hg_strip_url_credentials "$source")
  if hg_has_credentials "$source"; then
    echo "X stamp_spec: refusing to stamp source=: the value still carries a credential after stripping userinfo" >&2
    return 1
  fi
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  spec_file="$repo_root/.io.v4rian.how-git/SPEC"
  {
    printf 'source=%s\n' "$source"
    printf 'ref=%s\n' "$ref"
    printf 'tag=%s\n' "$tag"
    printf 'stamped=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$spec_file"
}

# ---------------------------------------------------------------------------
# Hook correctness helpers (one block, shared by githooks/ and scripts/).
# ---------------------------------------------------------------------------

# Branch naming: the single source of truth. Every hook and script that
# validates a pool/safety/vault name sources these instead of carrying its
# own copy (copies drift: post-checkout once lost the vYYYY.MAIN/ segment).
# The optional vYYYY.MAIN/ segment is the release-line prefix the allocator
# writes; the flat layout stays valid for branches allocated before it.
HG_BRANCH_KINDS='feature|fix|r&d|refactor|reconcile|doc'
HG_BRANCH_SUFFIX_RE="(v[0-9]{4}\.[0-9]+/)?n[0-9]+\.(${HG_BRANCH_KINDS})\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9-]*"
HG_BRANCH_RE="^(pool|safety)/${HG_BRANCH_SUFFIX_RE}\$"
HG_POOL_BRANCH_RE="^pool/${HG_BRANCH_SUFFIX_RE}\$"
HG_VAULT_BRANCH_RE="^vault/${HG_BRANCH_SUFFIX_RE}\$"
# Preflight backup branches (~/.claude/hooks/git-preflight.sh and the
# git-snapshot-preflight skill): preflight-bak-YYYY-MM-DD/NN, nothing else.
# Only pre-push admits them; they are never working branch names.
HG_PREFLIGHT_BRANCH_RE='^preflight-bak-[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9]{2}$'
HG_POOL_PREFIX_RE="^pool/(v[0-9]{4}\.[0-9]+/)?n[0-9]+\.(${HG_BRANCH_KINDS})\."
HG_BRANCH_FORMAT="(pool|safety)/[vYYYY.MAIN/]nN.(${HG_BRANCH_KINDS}).[sprintX-][JIRA-]short_name"

# hg_branch_name_ok <name>: 0 for main, dev, or a well-formed pool/safety
# name; 1 otherwise (including a detached HEAD's literal "HEAD").
hg_branch_name_ok() {
  local b="$1"
  case "$b" in main|dev) return 0 ;; esac
  [[ "$b" =~ $HG_BRANCH_RE ]]
}

# Commit message policy. The prepare-commit-msg auto-fix rewrites messages;
# it can be switched off for one command (HOW_GIT_AUTOFIX=0) or for a repo
# or user (git config howgit.autofix false), and it never rewrites a rebase
# or cherry-pick replay. Switching it off never switches the rules off:
# commit-msg and pre-push run hg_message_violations on every message.

# hg_autofix_enabled: 0 unless the operator opted out.
hg_autofix_enabled() {
  case "${HOW_GIT_AUTOFIX:-}" in 0|false|off|no) return 1 ;; esac
  [ "$(git config --bool howgit.autofix 2>/dev/null || true)" = "false" ] && return 1
  return 0
}

# hg_replay_in_progress: 0 while git replays existing commits (rebase,
# cherry-pick); their messages were written and checked when first made.
hg_replay_in_progress() {
  local p path
  for p in rebase-merge rebase-apply CHERRY_PICK_HEAD; do
    path=$(git rev-parse --git-path "$p" 2>/dev/null) || continue
    [ -e "$path" ] && return 0
  done
  return 1
}

# Message rules, one implementation for the gate (hg_message_violations)
# and the scrub (hg_scrub_message_file) so the two never disagree.
#
# Banned words come from AUTO_FIX_BANNED_WORDS: comma separated entries,
# each trimmed (so a phrase such as "as well as" works); "word=replacement"
# sets what the scrub writes; a bare entry is refused by the gate and never
# rewritten by the scrub, except the default "plus", which the scrub turns
# into "and". Default list: plus.
#
# Identifiers are not prose: inline code spans in backticks, tokens holding
# a "/" (ref names such as pool/..., paths, URLs), JIRA keys (PROJ-12), and
# hyphen compounds (plus-sized) are masked before the word rule runs and
# restored byte for byte after the scrub. Dashes and the Claude co-author
# trailer are judged on the whole text.
_HG_MSG_RULES_PY='
import re, sys
mode, path, words_csv, strip, cc = sys.argv[1:6]
with open(path, encoding="utf-8", errors="replace") as f:
    text = f.read()
entries = []
for raw in words_csv.split(","):
    w = raw.strip()
    if not w:
        continue
    if "=" in w:
        w, r = [x.strip() for x in w.split("=", 1)]
    else:
        r = "and" if w.lower() == "plus" else None
    if w:
        entries.append((w, r))
IDENT = re.compile(r"(`[^`\n]*`|\S*/\S*|\b[A-Z][A-Z0-9]*-[0-9]+\b|\b\w+(?:-\w+)+\b)")
def word_re(w):
    return re.compile(r"(?<!\w)" + re.escape(w).replace(r"\ ", r"\s+") + r"(?!\w)", re.IGNORECASE)
lines = text.split("\n")
cut = next((i for i, l in enumerate(lines) if re.match(r"^# -+ >8 -+$", l)), len(lines))
body, tail = lines[:cut], lines[cut:]
if mode == "check":
    if strip == "1":
        body = [l for l in body if not l.startswith(cc)]
    joined = "\n".join(body)
    bad = []
    if "—" in joined or "–" in joined:
        bad.append("em or en dash (write a comma, a colon, or a plain hyphen)")
    prose = IDENT.sub(" ", joined)
    for w, r in entries:
        if word_re(w).search(prose):
            hint = ("write \"%s\" or rephrase" % r) if r else "rephrase"
            bad.append("the banned word \"%s\" in prose (%s; code spans, refs, paths, keys, and compounds are exempt)" % (w, hint))
    if re.search(r"(?im)^co-authored-by:\s*claude", joined):
        bad.append("a Co-Authored-By: Claude trailer")
    for b in bad:
        print(b)
    sys.exit(1 if bad else 0)
out = []
for line in body:
    if not line.startswith("#"):
        if re.match(r"(?i)^co-authored-by:\s*claude", line):
            continue
        line = re.sub(r"\s+—\s+", ", ", line).replace("—", "-").replace("–", "-")
        parts = IDENT.split(line)
        for i in range(0, len(parts), 2):
            for w, r in entries:
                if r is not None:
                    parts[i] = word_re(w).sub(r, parts[i])
        line = "".join(parts)
    out.append(line)
new = "\n".join(out + tail)
if new != text:
    with open(path, "w", encoding="utf-8") as f:
        f.write(new)
'

# Subject shape rules, the deterministic part of git-commit-audit (the
# gitlint-equivalent set the jev evaluation adopted). Human tags need a
# sentence case subject; [MERGE], [REQ] and [MODE] are machine shapes whose
# text after the tag is a ref name or a mode word, so only the tag is
# checked. fixup!, squash! and amend! subjects are checked after the marker,
# since autosquash folds them away.
HG_SUBJECT_TAGS='NEW|FIX|TEST|DOCS|REFACTOR|PERF|REVERT|HOTFIX'
HG_MACHINE_TAGS='MERGE|REQ|MODE'

# hg_subject_violations <subject>: prints the broken shape rule and returns
# 1, or returns 0. Length bounds stay in commit-msg.
hg_subject_violations() {
  local subj="$1"
  while :; do
    case "$subj" in
      "fixup! "*|"squash! "*|"amend! "*) subj=${subj#* } ;;
      *) break ;;
    esac
  done
  if [[ "$subj" =~ ^\[($HG_MACHINE_TAGS)\]\ [^[:space:]] ]]; then return 0; fi
  if [[ "$subj" =~ ^\[($HG_SUBJECT_TAGS)\]\ [A-Z0-9] ]]; then return 0; fi
  if [[ "$subj" =~ ^\[([A-Z]+)\]\  ]]; then
    case "|$HG_SUBJECT_TAGS|$HG_MACHINE_TAGS|" in
      *"|${BASH_REMATCH[1]}|"*)
        echo "subject after [${BASH_REMATCH[1]}] must start with a capital letter (sentence case)" ;;
      *) echo "unknown tag [${BASH_REMATCH[1]}]; use one of [${HG_SUBJECT_TAGS//|/], [}]" ;;
    esac
    return 1
  fi
  echo "subject must start with a [TAG] and one space, e.g. [FIX] Guard empty args"
  return 1
}

# hg_message_violations <msg-file> [strip-comments]: prints one line per
# broken message rule and returns 1 when any rule is broken: an em or en
# dash, a banned word in prose, a Co-Authored-By: Claude trailer. The rules
# hold for every message whatever its subject says ([REQ], [MERGE]
# included): machine-written messages comply because their text goes
# through hg_scrub_message_file when it is written. The scissors block is
# always ignored. Comment lines are ignored only with "strip-comments"
# (commit-msg, where the editor template still sits in the file), using
# core.commentChar; a stored message (pre-push) is checked whole, because
# git keeps "#" lines for -m and -F messages.
hg_message_violations() {
  local f="$1" strip=0 cc=""
  if [ "${2:-}" = "strip-comments" ]; then
    strip=1
    cc=$(git config core.commentChar 2>/dev/null || true)
    case "$cc" in ""|auto) cc="#" ;; esac
  fi
  python3 -c "$_HG_MSG_RULES_PY" check "$f" "${AUTO_FIX_BANNED_WORDS:-plus}" "$strip" "${cc:-#}"
}

# hg_scrub_message_file <file>: rewrites only what the message rules ban,
# keeping every line break and list: em dashes become ", " (spaced) or "-",
# en dashes "-", banned words with a replacement are replaced in prose, and
# Claude co-author trailers are dropped. Identifiers and comment lines are
# left alone. Used by the auto-fix, for [MERGE] bodies (whose nested list
# the full auto-fix must not reshape), and for the allocator's [REQ]
# commit message (written by plumbing, no hooks).
hg_scrub_message_file() {
  [ -f "$1" ] || return 0
  python3 -c "$_HG_MSG_RULES_PY" scrub "$1" "${AUTO_FIX_BANNED_WORDS:-plus}" 0 "#"
}

# Dash policy, shared by the pre-commit scrub and the CI commit-audit dash
# gate so the two never disagree. The em and en dash ban is a prose rule:
# it applies to markdown, text, reStructuredText, AsciiDoc, Org, and
# extensionless README-style docs. Code and data keep their bytes, because
# a dash inside a string literal, a regex, or quoted requirement text is
# semantics, not prose (a scrub that rewrote one once broke a [--] regex).
# In a consumer repo (no FRAMEWORK_REPO marker) the vendored namespace is
# exempt as well: it must stay byte-identical to the framework source.
# hg_dash_rule_applies <repo-relative path> [repo-root]: 0 when it applies.
hg_dash_rule_applies() {
  local p="$1" root="${2:-}" base
  case "$p" in
    .io.v4rian.how-git/*)
      [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
      [ -f "$root/.io.v4rian.how-git/FRAMEWORK_REPO" ] || return 1
      ;;
  esac
  base=$(printf '%s' "${p##*/}" | tr '[:upper:]' '[:lower:]')
  case "$base" in
    *.md|*.markdown|*.mdx|*.txt|*.rst|*.adoc|*.asciidoc|*.org) return 0 ;;
    readme|changelog|contributing|authors|notice|license|copying) return 0 ;;
  esac
  # Markup that embeds code (.html, .tex) stays out of scope by design.
  return 1
}

# Fenced code inside markdown is code, by CommonMark rules: a fence is 3+
# backticks or tildes indented at most 3 spaces; it closes only on the same
# character, at least as long, with nothing after it. Fenced lines keep
# their bytes in the scrub and are skipped by the gate. The fence walk is
# _HG_FENCE_PY, shared by both helpers.
# hg_dash_fenced_lines <file|->: prints the 1-based line numbers inside
# fences (fence lines included) for a markdown file; nothing otherwise.
# hg_scrub_prose_file <path>: replaces em/en dashes outside fences.
_HG_FENCE_PY='
import re
OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
def fenced_flags(lines):
    flags, fence = [], None
    for line in lines:
        m = OPEN.match(line)
        if fence is None:
            if m and not (m.group(1)[0] == "`" and "`" in line[m.end():]):
                fence = m.group(1)
                flags.append(True)
            else:
                flags.append(False)
        else:
            flags.append(True)
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not line[m.end():].strip():
                fence = None
    return flags
'
hg_dash_fenced_lines() {
  python3 -c "$_HG_FENCE_PY"'
import sys
src = sys.stdin if sys.argv[1] == "-" else open(sys.argv[1], encoding="utf-8", errors="replace")
for n, f in enumerate(fenced_flags(src.read().split("\n")), 1):
    if f:
        print(n)
' "$1"
}

hg_scrub_prose_file() {
  local p="$1" md=0
  case "$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')" in
    *.md|*.markdown|*.mdx) md=1 ;;
  esac
  python3 -c "$_HG_FENCE_PY"'
import sys
p, md = sys.argv[1], sys.argv[2] == "1"
with open(p, "r", encoding="utf-8", errors="replace") as f:
    lines = f.read().split("\n")
flags = fenced_flags(lines) if md else [False] * len(lines)
out = [l if f else l.replace("\u2014", "-").replace("\u2013", "-") for l, f in zip(lines, flags)]
new = "\n".join(out)
if new != "\n".join(lines):
    with open(p, "w", encoding="utf-8") as f:
        f.write(new)
' "$p" "$md"
}

# Active requirement, one file per lane. The allocator's [REQ] commit used
# to add the single shared .io.v4rian.how-git/active-requirement on every
# pool, so the second lane merged into dev hit an add/add conflict (also on
# forge-side merges, where no local merge driver runs). Each lane now gets
# its own path, keyed by its pool ref, so two lanes never touch the same
# file: merges in any direction and on any host stay clean, and a lane that
# merges dev still reads its own file. scripts/get-active-requirement.sh
# resolves per-lane file, then the [REQ] commit body, then the legacy
# shared file, so lanes allocated before this change keep working.
HG_REQUIREMENTS_DIR=".io.v4rian.how-git/requirements"

# hg_requirement_path <pool-ref>: the lane's requirement file path, the
# branch name with each "/" turned into "__"
# (pool/v2026.0/n3.fix.x -> requirements/pool__v2026.0__n3.fix.x).
hg_requirement_path() {
  local r="${1#refs/heads/}"
  printf '%s/%s' "$HG_REQUIREMENTS_DIR" "$(printf '%s' "$r" | sed 's#/#__#g')"
}

# Legacy layout: lanes allocated before per-lane files carry this shared
# path. hg_legacy_requirement_lanes prints the local pool/* lanes whose tip
# tracks it with text they changed since forking from dev (local dev, else
# origin/dev, else the root), so a copy merely inherited from dev never
# counts; scripts/migrate-active-requirement.sh moves them.
HG_LEGACY_REQUIREMENT=".io.v4rian.how-git/active-requirement"
hg_legacy_requirement_lanes() {
  local b tip base blob base_blob dev_ref=""
  for dev_ref in refs/heads/dev refs/remotes/origin/dev ""; do
    [ -z "$dev_ref" ] && break
    git rev-parse -q --verify "$dev_ref" >/dev/null 2>&1 && break
  done
  git for-each-ref --format='%(refname:short)' refs/heads/pool/ | while read -r b; do
    tip=$(git rev-parse "refs/heads/$b")
    blob=$(git rev-parse -q --verify "$tip:$HG_LEGACY_REQUIREMENT" 2>/dev/null) || continue
    git cat-file -e "$tip:$(hg_requirement_path "$b")" 2>/dev/null && continue
    base_blob=""
    if [ -n "$dev_ref" ] && base=$(git merge-base "$tip" "$dev_ref" 2>/dev/null); then
      base_blob=$(git rev-parse -q --verify "$base:$HG_LEGACY_REQUIREMENT" 2>/dev/null || true)
    fi
    [ "$blob" = "$base_blob" ] || printf '%s\n' "$b"
  done
}

# Credentials never reach a written file. A checkout cloned with
# https://user:token@host/... reports that URL as its origin; anything the
# vendoring tools stamp (SPEC source=) or print goes through
# hg_strip_url_credentials first, and stamp_spec refuses a value that still
# matches hg_has_credentials.
# hg_strip_url_credentials <url>: the userinfo is everything up to the LAST
# "@" before the first "/" after "scheme://" (a password may itself hold
# "@"). Every scheme loses all of it (a bare token can sit in the user
# field, git+https included) except ssh, which keeps a password-free user
# (ssh://git@host). scp-style git@host:path and local paths pass as is.
hg_strip_url_credentials() {
  local u="$1" scheme rest authority path userinfo user
  case "$u" in
    *://*) ;;
    *) printf '%s' "$u"; return 0 ;;
  esac
  scheme="${u%%://*}"
  rest="${u#*://}"
  authority="${rest%%/*}"
  path="${rest#"$authority"}"
  case "$authority" in
    *@*) ;;
    *) printf '%s' "$u"; return 0 ;;
  esac
  userinfo="${authority%@*}"
  authority="${authority##*@}"
  case "$scheme" in
    [Ss][Ss][Hh]|*+[Ss][Ss][Hh]|[Ss][Ss][Hh]+*)
      user="${userinfo%%:*}"
      printf '%s://%s@%s%s' "$scheme" "$user" "$authority" "$path" ;;
    *)
      printf '%s://%s%s' "$scheme" "$authority" "$path" ;;
  esac
}

# hg_has_credentials <text>: 0 when the text carries a known token shape or
# a user:password@ URL userinfo.
hg_has_credentials() {
  printf '%s' "$1" | grep -qE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|://[^/@[:space:]]+:[^/@[:space:]]+@'
}

# SPEC provenance must resolve at the recorded source. A local checkout's
# tag can point at a different commit than the same tag at its origin (a
# rewritten lineage with the same tree), so the vendoring tools and doctor
# ask the source itself. Both helpers are read-only on the caller's repo
# and never prompt for credentials.
# hg_source_tag_sha <source> <tag>: prints the commit the tag resolves to
# at the source (peeled), or nothing when the tag is absent or the source
# cannot be reached.
hg_source_tag_sha() {
  local src="$1" tag="$2" out
  out=$(GIT_TERMINAL_PROMPT=0 git ls-remote "$src" "refs/tags/$tag" "refs/tags/$tag^{}" 2>/dev/null) || return 0
  printf '%s\n' "$out" | awk -v t="refs/tags/$tag" '$2 == t"^{}" {p=$1} $2 == t {d=$1} END {if (p) print p; else if (d) print d}'
}

# hg_source_has_commit <source> <sha>: 0 when the source can serve that
# commit (fetched by id into a throwaway bare repo), 1 when it cannot, 2
# when the source itself is unreachable.
hg_source_has_commit() {
  hg_source_tree_at "$1" "$2" >/dev/null
}

# hg_source_tree_at <source> <sha> [path]: prints the tree id of <path>
# (default: the whole tree) at <sha> as the source serves it, fetched into
# a throwaway bare repo so the caller's repositories never gain objects or
# a FETCH_HEAD. Returns like hg_source_has_commit.
hg_source_tree_at() {
  local src="$1" sha="$2" path="${3:-}" tmp rc=0
  GIT_TERMINAL_PROMPT=0 git ls-remote "$src" HEAD >/dev/null 2>&1 || return 2
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/hg-src-probe.XXXXXX") || return 2
  git init -q --bare "$tmp"
  if GIT_TERMINAL_PROMPT=0 git -C "$tmp" fetch -q --depth=1 "$src" "$sha" >/dev/null 2>&1; then
    git -C "$tmp" rev-parse --verify --quiet "${sha}^{tree}${path:+:$path}" 2>/dev/null || true
  else
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# end hook correctness helpers

# hg_kind_ok <kind>: 0 when <kind> is one of HG_BRANCH_KINDS, the one list the
# allocator and every branch-name check share (scripts/lint-protocol.sh fails
# on a drifting copy).
hg_kind_ok() {
  case "$1" in ''|*'|'*) return 1 ;; esac
  case "|$HG_BRANCH_KINDS|" in *"|$1|"*) return 0 ;; esac
  return 1
}

# Resolve the source branch name (the head ref) for a merge commit by its SHA.
# Used by claim-dev-merge.sh and claim-main-release.sh to recover the merged
# branch when the legacy "Merge pull request #N from <user>/<branch>" subject
# pattern does not appear (bootstrap-ci sets merge_commit_title=PR_TITLE so the
# default GitHub merge subject becomes "<PR title> (#N)" instead - the legacy
# parser silently misses every merge under that config).
#
# Resolution order:
#   1. gh pr list --search "<sha>" - finds the merged PR by its merge commit.
#      Returns the headRefName when exactly one merged PR matches; this is the
#      cheap path that covers the vast majority of cases.
#   2. Walk recent merged PRs and match headRefName candidates against the
#      merge commit's second parent SHA via gh api repos/<owner>/<repo>/
#      git/refs/heads/<candidate> - slow fallback for the case where the SHA
#      search misses (rare; defensive).
#   3. Empty stdout when both probes fail; caller decides whether that is
#      fatal or only blocks the dependent step.
#
# Args:
#   $1 - merge commit SHA (typically HEAD or HEAD^1 of a freshly-merged target)
#   $2 - owner/repo (e.g. joelquatro/how-git); resolved from origin URL when
#        empty
#
# Stdout: source ref name on success (e.g. pool/v2026.0/n78.fix.something), or
# empty string when no source ref could be resolved. Exit code is 0 either way
# so callers can distinguish "resolved" from "unresolved" via the stdout value
# rather than rc; this matches the gh CLI's own pattern of returning empty for
# no-match queries without throwing.
resolve_source_ref_for_merge_sha() {
  local merge_sha="$1"
  local owner_repo="${2:-}"
  if [ -z "$merge_sha" ]; then
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi
  if [ -z "$owner_repo" ]; then
    local remote_url
    remote_url=$(git config --get remote.origin.url 2>/dev/null || true)
    owner_repo=$(echo "$remote_url" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
  fi
  if [ -z "$owner_repo" ]; then
    return 0
  fi

  # Probe 1: gh's --search hits the GraphQL search index, which keys merged
  # PRs by their merge commit SHA. One round-trip per claim invocation.
  local head_ref
  head_ref=$(gh pr list --repo "$owner_repo" --state merged --search "$merge_sha" \
    --json number,headRefName --jq '.[0].headRefName' 2>/dev/null || true)
  if [ -n "$head_ref" ]; then
    printf '%s' "$head_ref"
    return 0
  fi

  # Probe 2: enumerate the last 30 merged PRs and match each one's mergeCommit
  # SHA against the target. Slow path; only fires when the search index has not
  # yet indexed the merge (race condition window of seconds after a merge).
  local match
  match=$(gh pr list --repo "$owner_repo" --state merged --limit 30 \
    --json number,headRefName,mergeCommit \
    --jq ".[] | select(.mergeCommit.oid == \"$merge_sha\") | .headRefName" \
    2>/dev/null | head -1 || true)
  if [ -n "$match" ]; then
    printf '%s' "$match"
    return 0
  fi
  return 0
}

# Enumerate the open pool branches at this moment and emit one line per
# branch with the branch name, first commit date, and last commit date.
# Used by claim-main-release to append an "open work pool branches at
# release" section to the dev->main merge commit body so the release log
# carries an honest picture of what was still in flight when the cut went
# out.
#
# Output format (one branch per line, fields tab-separated):
#
#   <pool-ref-name>\t<first-commit-date>\t<last-commit-date>
#
# Dates are ISO 8601 short form (YYYY-MM-DD) via git log --format='%cs'.
# Order is ascending by first-commit-date so the oldest open branch is
# first and the most recently started is last, the natural "what's
# been waiting longest" reading order.
#
# Sourcing rules:
#   - Connected mode: read from refs/remotes/origin/pool/* so the view
#     reflects what the remote considers open right now. The script's
#     caller (claim-main-release.sh) has already pulled main, so origin
#     refs are fresh.
#   - Off-grid mode: read from refs/heads/pool/* since no remote view
#     applies. Local refs are the authority.
#
# Exclusions (NOT counted as "open work"):
#   - Reconcile sub-branches (.reconcile. in the name); those are the
#     transient rolling pointers produced by the auto-rebase ladder, not
#     developer-authored open work. See feedback_how_git_never_rewrites_history.
#   - Branches whose tip is reachable from main (just landed; the merge
#     that triggered this release may have brought them in).
#
# First-commit-date resolution per branch:
#   1. If a paired safety/ ref exists (same nN, kind, slug, prefix), use
#      git log --reverse --format='%cs' safety..pool | sed -n 1p to get
#      the date of the first commit on the pool branch that the safety
#      anchor does not contain. This is the "first developer commit on
#      this allocation" date.
#   2. If no commits exist beyond the safety anchor (empty allocation),
#      fall back to the safety anchor's own committer date so the line
#      is still honest about the empty pool.
#   3. If no paired safety/ ref can be located (rare; manual branches
#      that bypassed the allocator), fall back to the date of the first
#      commit reachable from the pool ref not reachable from main;
#      conceptually the same intent, computed against a different
#      reference point.
#
# Last-commit-date per branch:
#   git log -1 --format='%cs' <pool-ref> for the tip's committer date.
#
# Arguments: none.
# Stdout: zero or more lines, one per open pool branch. Empty stdout when
# no branches are open (caller decides how to render that state).
# Always returns 0.
list_open_pool_branches() {
  local mode pool_refspace main_ref
  mode=$(get_mode 2>/dev/null || printf 'connected')
  if [ "$mode" = "off-grid" ]; then
    pool_refspace='refs/heads/pool/'
    # Local main is the authoritative landing target off-grid.
    main_ref='main'
  else
    pool_refspace='refs/remotes/origin/pool/'
    # origin/main is the authoritative landing target connected. Fall back
    # to local main when the remote tracking ref is absent (scratch repos
    # without a fetched origin/main).
    if git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
      main_ref='origin/main'
    else
      main_ref='main'
    fi
  fi

  # Enumerate candidate pool refs. for-each-ref handles both the flat
  # legacy layout (refs/.../pool/nN.<kind>.<slug>) and the prefixed
  # vYYYY.MAJOR layout (refs/.../pool/vYYYY.MAJOR/nN.<kind>.<slug>) under
  # the same root prefix.
  local candidates
  candidates=$(git for-each-ref --format='%(refname)' "${pool_refspace}**" 2>/dev/null || true)
  [ -n "$candidates" ] || return 0

  local tmp_rows
  tmp_rows=$(mktemp -t v4rian-open-pool-XXXXXX)

  local refname short_ref kind first_date last_date safety_ref
  while IFS= read -r refname; do
    [ -n "$refname" ] || continue
    # short_ref is the form printed in the merge commit body (e.g.
    # pool/v2026.0/n55.feature.foo); strip the leading refs/heads/ or
    # refs/remotes/origin/ namespace so connected and off-grid emit
    # identical surface text.
    short_ref=${refname#refs/heads/}
    short_ref=${short_ref#refs/remotes/origin/}

    # Exclude reconcile sub-branches; they are transient rolling pointers.
    case "$short_ref" in
      *.reconcile.*) continue ;;
    esac

    # Exclude branches already reachable from main; those have landed.
    if git merge-base --is-ancestor "$refname" "$main_ref" 2>/dev/null; then
      continue
    fi

    # Locate the paired safety ref. Replace the leading "pool/" with
    # "safety/" and probe both ref spaces (the remote-tracking copy
    # connected, and the local copy as a fallback).
    safety_ref=""
    local safety_short candidate
    safety_short="safety/${short_ref#pool/}"
    for candidate in "refs/remotes/origin/$safety_short" "refs/heads/$safety_short"; do
      if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
        safety_ref="$candidate"
        break
      fi
    done

    # First-commit-date: commits in safety..pool, oldest first.
    first_date=""
    if [ -n "$safety_ref" ]; then
      first_date=$(git log --reverse --format='%cs' "${safety_ref}..${refname}" 2>/dev/null | sed -n 1p)
      if [ -z "$first_date" ]; then
        # Empty allocation: safety tip and pool tip refer to the same
        # commit (or a strict ancestor chain). Honest answer: the safety
        # anchor's own committer date.
        first_date=$(git log -1 --format='%cs' "$safety_ref" 2>/dev/null || true)
      fi
    else
      # No safety pair found: fall back to first commit reachable from
      # pool that main does not contain.
      first_date=$(git log --reverse --format='%cs' "${main_ref}..${refname}" 2>/dev/null | sed -n 1p)
      if [ -z "$first_date" ]; then
        first_date=$(git log -1 --format='%cs' "$refname" 2>/dev/null || true)
      fi
    fi

    last_date=$(git log -1 --format='%cs' "$refname" 2>/dev/null || true)
    [ -n "$first_date" ] || first_date="$last_date"
    [ -n "$last_date" ]  || last_date="$first_date"

    # Skip refs that yielded no date at all (broken ref, unreachable
    # object). Better silent than wrong.
    if [ -z "$first_date" ] && [ -z "$last_date" ]; then
      continue
    fi

    printf '%s\t%s\t%s\n' "$short_ref" "$first_date" "$last_date" >>"$tmp_rows"
  done <<EOF
$candidates
EOF

  # Sort ascending by first-commit-date (field 2). Tab is the delimiter;
  # the trailing -k1,1 keeps ordering stable across same-date branches
  # by ref name (oldest-first AND deterministic).
  sort -t $'\t' -k2,2 -k1,1 "$tmp_rows"
  rm -f "$tmp_rows"
  return 0
}

assert_mode() {
  local expected actual
  expected="$1"
  actual=$(get_mode)
  if [ "$actual" != "$expected" ]; then
    echo "X this tool requires ${expected} mode; current mode is ${actual}" >&2
    case "$expected" in
      connected) echo "  switch with: bin/set-mode connected" >&2 ;;
      off-grid)  echo "  switch with: bin/set-mode off-grid"  >&2 ;;
    esac
    return 1
  fi
  return 0
}

# Dependency + precondition helpers
# ---------------------------------
#
# These helpers exist so admin tooling (`apply-repo-rules.sh`, `bootstrap-ci`,
# future lifecycle CLIs) can self-detect and self-install their CLI prereqs
# instead of refusing with a "set this env var first" message that pushes the
# burden onto the operator. The precondition_banner emitter routes failures to
# STDOUT (not STDERR) so operators piping through pagers or terminals that
# swallow STDERR still see the actionable text. The whole shape is project
# agnostic: no hardcoded owner/repo, no JIRA assumption (per the
# feedback_jira_is_integration_not_component principle: admin tooling works
# without the integrations preconfigured).

# Emit a visible banner to STDOUT. First arg is the script identifier;
# remaining args are body lines. Used by every precondition failure path.
precondition_banner() {
  local script="$1"; shift
  local line
  printf '\n'
  printf '+----------------------------------------------------------------+\n'
  printf '| %-62s |\n' "$script: precondition failed"
  printf '+----------------------------------------------------------------+\n'
  for line in "$@"; do
    printf '  %s\n' "$line"
  done
  printf '\n'
}

# Best effort OS detector. Returns one of: mac, debian, rhel, arch, alpine,
# unknown. Used by ensure_dep to pick the right package manager. Reads
# /etc/os-release on Linux and `uname` on macOS. No sudo invocation; that
# decision is the caller's, and the per-platform install snippet below
# surfaces sudo as text (NEVER executes sudo) per the workspace's
# no-root-access rule.
detect_os() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'mac\n'; return 0 ;;
  esac
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
      *debian*|*ubuntu*) printf 'debian\n'; return 0 ;;
      *rhel*|*fedora*|*centos*) printf 'rhel\n'; return 0 ;;
      *arch*) printf 'arch\n'; return 0 ;;
      *alpine*) printf 'alpine\n'; return 0 ;;
    esac
  fi
  printf 'unknown\n'
}

# Print the canonical install one-liner for a tool on the detected OS to
# STDOUT. Does NOT execute. The caller decides whether to attempt the
# command or surface it as text. Returns 0 always (text is the answer).
suggest_install_cmd() {
  local tool="$1" os="$2"
  case "$tool" in
    gh)
      case "$os" in
        mac)    printf 'brew install gh\n' ;;
        debian) printf 'sudo apt install -y gh\n' ;;
        rhel)   printf 'sudo dnf install -y gh\n' ;;
        arch)   printf 'sudo pacman -S --noconfirm github-cli\n' ;;
        alpine) printf 'sudo apk add github-cli\n' ;;
        *)      printf 'see https://cli.github.com/manual/installation\n' ;;
      esac
      ;;
    jq)
      case "$os" in
        mac)    printf 'brew install jq\n' ;;
        debian) printf 'sudo apt install -y jq\n' ;;
        rhel)   printf 'sudo dnf install -y jq\n' ;;
        arch)   printf 'sudo pacman -S --noconfirm jq\n' ;;
        alpine) printf 'sudo apk add jq\n' ;;
        *)      printf 'see https://jqlang.github.io/jq/download/\n' ;;
      esac
      ;;
    python3)
      case "$os" in
        mac)    printf 'brew install python\n' ;;
        debian) printf 'sudo apt install -y python3\n' ;;
        rhel)   printf 'sudo dnf install -y python3\n' ;;
        arch)   printf 'sudo pacman -S --noconfirm python\n' ;;
        alpine) printf 'sudo apk add python3\n' ;;
        *)      printf 'see https://www.python.org/downloads/\n' ;;
      esac
      ;;
    curl)
      case "$os" in
        mac)    printf 'brew install curl\n' ;;
        debian) printf 'sudo apt install -y curl\n' ;;
        rhel)   printf 'sudo dnf install -y curl\n' ;;
        arch)   printf 'sudo pacman -S --noconfirm curl\n' ;;
        alpine) printf 'sudo apk add curl\n' ;;
        *)      printf 'see https://curl.se/download.html\n' ;;
      esac
      ;;
    *)
      printf 'install %s via your platform package manager\n' "$tool"
      ;;
  esac
}

# Ensure a CLI is on PATH; auto-install on macOS via Homebrew when possible.
# Linux installs require root and are surfaced as a printable hint rather
# than executed (workspace rule: never invoke sudo from scripts). When the
# tool is already on PATH, returns 0 silently. When the install attempt
# succeeds, returns 0 with a brief note on STDOUT. When the tool is missing
# and cannot be auto-installed, prints a precondition banner to STDOUT and
# returns non-zero.
#
# Usage:
#   ensure_dep gh           # required tool; non-zero on absence
#   ensure_dep jq optional  # optional; returns non-zero without banner so
#                           # caller decides how loud to be
ensure_dep() {
  local tool="$1" mode="${2:-required}"
  if command -v "$tool" >/dev/null 2>&1; then
    return 0
  fi
  local os install_cmd
  os=$(detect_os)
  install_cmd=$(suggest_install_cmd "$tool" "$os")
  # Auto-install path: macOS + brew on PATH + no sudo needed.
  if [ "$os" = "mac" ] && command -v brew >/dev/null 2>&1; then
    printf '  -> %s missing; attempting auto-install via Homebrew (brew install %s)\n' "$tool" "$tool"
    if brew install "$tool" >/dev/null 2>&1; then
      if command -v "$tool" >/dev/null 2>&1; then
        printf '     installed %s -> %s\n' "$tool" "$(command -v "$tool")"
        return 0
      fi
    fi
    printf '     brew install %s did not produce a usable binary on PATH\n' "$tool"
  fi
  # Optional dependencies stay quiet; the caller decides whether to surface.
  if [ "$mode" = "optional" ]; then
    return 1
  fi
  precondition_banner "ensure_dep" \
    "Required CLI '$tool' is not on PATH and could not be auto-installed." \
    "Detected OS: $os" \
    "Install with: $install_cmd" \
    "Then re-run this script."
  return 1
}

# Verify gh is authenticated. Does NOT verify scope (admin/repo/etc.); the
# subsequent API call surfaces scope-missing errors with the actual HTTP
# status. Returns 0 if `gh auth status` succeeds for at least one host;
# emits a banner and returns non-zero otherwise.
# gh_workflow_dispatch <gh workflow run args...>: runs `gh workflow run` and prints
# its output (the run URL on gh >= 2.87) on stdout. GitHub registers the
# workflows of a freshly created or seeded repo a few seconds late and answers
# "HTTP 404: workflow ... not found" until then; that answer alone is retried,
# every 5 s for up to GH_DISPATCH_WAIT seconds (default 60). Any other failure,
# or a 404 past the wait, returns non-zero with gh's output on stderr.
gh_workflow_dispatch() {
  local out rc deadline=$(( SECONDS + ${GH_DISPATCH_WAIT:-60} ))
  while :; do
    out=$(gh workflow run "$@" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then printf '%s\n' "$out"; return 0; fi
    case "$out" in
      *"HTTP 404"*"not found"*)
        if [ "$SECONDS" -lt "$deadline" ]; then
          echo "  · workflow not registered on GitHub yet; retrying the dispatch in 5 s" >&2
          sleep 5; continue
        fi ;;
    esac
    printf '%s\n' "$out" >&2
    return "$rc"
  done
}

ensure_gh_auth() {
  if gh auth status >/dev/null 2>&1; then
    return 0
  fi
  precondition_banner "ensure_gh_auth" \
    "gh CLI is installed but no host is authenticated." \
    "Run one of:" \
    "  gh auth login                     # interactive OAuth flow" \
    "  export GH_TOKEN=<token>           # PAT or fine-grained token" \
    "" \
    "The token must carry admin scope on the target repo for" \
    "branch protection and Repository Rules to apply."
  return 1
}

# Push refs to origin under the right lifecycle identity for the
# context. Privileged ref operations (vault/* creation, pool/* deletion
# at archive time, pool/*.reconcile.* candidate publication, claim tags)
# are ruleset locked to admins: in a LOCAL shell the operator's own
# credentials ride the plain origin push (the gh session OAuth - never
# a token input, never a secret), and an admin operator clears the
# ruleset through the RepositoryRole / OrganizationAdmin bypass. Inside
# a workflow the optional CLAIM_TAG_PUSH_TOKEN (the documented CI bot
# App installation token) is used when configured - its pushes count as
# an external actor so downstream tag/ref events still fire - otherwise
# the plain GITHUB_TOKEN push is attempted and the caller surfaces the
# rejection loudly; the admin then completes the transition locally via
# bin/post-merge-lifecycle.
#
# All arguments pass through to `git push` verbatim (refspecs + flags
# such as --no-verify / --atomic / --delete). stderr flows upstream so
# callers surface the real rejection text.
lifecycle_push() {
  local owner_repo
  owner_repo=$(git config --get remote.origin.url 2>/dev/null \
    | sed -nE 's|^https?://([^@/]+@)?github\.com/([^/]+/[^/]+)$|\2|p; s|^git@github\.com:([^/]+/[^/]+)$|\1|p' \
    | sed -E 's|\.git$||')
  if [ -n "${CLAIM_TAG_PUSH_TOKEN:-}" ] && [ -n "$owner_repo" ]; then
    git push "https://x-access-token:${CLAIM_TAG_PUSH_TOKEN}@github.com/${owner_repo}.git" "$@"
  else
    git push origin "$@"
  fi
}
# Read an org's plan name (free / team / business / enterprise) via the API.
# Prints the plan name to STDOUT on success; returns non-zero on failure
# (token may lack the org-read scope, org may not exist, etc.). Used by
# apply-repo-rules to short-circuit the visibility gate when the plan
# clearly supports Repository Rules. gh's stderr flows upstream so the
# caller can route it into a precondition_banner.
get_org_plan_name() {
  local org="$1"
  local plan rc
  # Exit-code preservation: gh's rc must reach the caller; piping to head -1 would mask a 404
  # or 401 as success.
  plan=$(gh api "/orgs/$org" --jq '.plan.name')
  rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  plan=$(printf '%s\n' "$plan" | head -1)
  if [ -z "$plan" ] || [ "$plan" = "null" ]; then
    # gh succeeded but the response carried no .plan.name (private
    # API field requires the token to have the org's billing or
    # admin:org scope on most plans). Emit the actionable diagnostic
    # on stderr so run_capture_stderr can route it to the caller's
    # banner instead of leaving the operator with empty text.
    printf 'gh /orgs/%s returned no .plan.name field; the token likely lacks admin:org or read:org scope on this org\n' "$org" >&2
    return 1
  fi
  printf '%s\n' "$plan"
}

# Check whether a repo's effective plan supports Repository Rules. Returns 0
# if the plan is known to support rulesets (team, business, enterprise) or
# the repo is public on free; non-zero otherwise. Reads the repo's owner
# kind (User vs Organization) and visibility plus the org plan when
# applicable. Used to decide whether to even attempt the ruleset POSTs vs
# surface a clear "this account/plan does not enable Rules" message.
# gh's stderr flows upstream when the /repos/<owner>/<repo> lookup itself
# fails so callers can surface the real API error (404, scope missing,
# rate limit) rather than masking it as "could not confirm support".
repo_supports_rulesets() {
  local owner="$1" repo="$2"
  local resp visibility owner_type plan
  resp=$(gh api "/repos/$owner/$repo")
  if [ -z "$resp" ]; then
    return 1
  fi
  visibility=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('visibility',''))
except Exception:
    print('')")
  owner_type=$(printf '%s' "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('owner',{}).get('type',''))
except Exception:
    print('')")
  # Public visibility supports rulesets on every account/plan.
  if [ "$visibility" = "public" ]; then
    return 0
  fi
  # Private repo: plan must be team / business / enterprise. The nested
  # get_org_plan_name lookup may itself emit gh stderr; that text is
  # informational here (the plan check is a soft probe) so we route it
  # to /dev/null intentionally; see the run_capture_stderr helper for
  # the precondition path that DOES surface stderr.
  if [ "$owner_type" = "Organization" ]; then
    plan=$(get_org_plan_name "$owner" 2>/dev/null || true)
    case "$plan" in
      team|business|enterprise) return 0 ;;
    esac
  fi
  # User-owned private repo: requires GitHub Pro.
  if [ "$owner_type" = "User" ]; then
    plan=$(gh api "/users/$owner" --jq '.plan.name' 2>/dev/null | sed -n 1p)
    case "$plan" in
      pro|business|enterprise) return 0 ;;
    esac
  fi
  return 1
}

# Run a command and capture its stdout AND stderr into named caller
# variables, plus expose the exit code. Used by admin tooling that needs
# to route a helper's stderr into a precondition_banner instead of letting
# it disappear into the terminal. The pattern wraps the classic bash
# 3.2-compatible trick:
#
#   { OUT=$(cmd); } 2> >(read err; echo "$err")
#
# but generalizes it so callers can pick the variable names. The exit
# code is written to the third variable. Always returns 0 so callers can
# inspect the captured rc themselves; that lets the caller decide whether
# a non-zero rc plus empty stdout means "fail loud" or "fall through".
#
# Usage:
#   run_capture_stderr OUT ERR RC -- get_org_plan_name "$ORG"
#   if [ "$RC" -ne 0 ]; then
#     precondition_banner "tool" "lookup failed:" "  $ERR"
#   fi
#
# Implementation note: bash 3.2 lacks the {fd}> redirection sugar, so we
# use a tmpfile for the stderr stream. The tmpfile is cleaned up on
# every invocation. Quote the command + args with -- so the helper does
# not need to parse flags.
run_capture_stderr() {
  local _out_var="$1" _err_var="$2" _rc_var="$3" _sep="$4"
  if [ "$_sep" != "--" ]; then
    echo "run_capture_stderr: usage: run_capture_stderr OUT ERR RC -- cmd args..." >&2
    return 2
  fi
  shift 4
  local _err_file _stdout _rc _prev_e
  _err_file=$(mktemp -t v4rian-capture-stderr-XXXXXX)
  # Snapshot the caller's `set -e` state so we can restore it. The whole
  # point of this helper is to surface a non-zero rc through the
  # caller's banner; if `set -e` is active in the caller, the command
  # substitution below would propagate and abort the script BEFORE the
  # banner ran. Disable `-e` locally, capture rc, then restore.
  _prev_e=0
  case "$-" in *e*) _prev_e=1 ;; esac
  set +e
  _stdout=$("$@" 2>"$_err_file")
  _rc=$?
  if [ "$_prev_e" = 1 ]; then
    set -e
  fi
  local _stderr
  _stderr=$(cat "$_err_file" 2>/dev/null || true)
  rm -f "$_err_file"
  # Use printf -v in bash 3.2+ to assign by name without eval.
  printf -v "$_out_var" '%s' "$_stdout"
  printf -v "$_err_var" '%s' "$_stderr"
  printf -v "$_rc_var" '%s' "$_rc"
  return 0
}
# Test-mode: LIFECYCLE_TEST_MODE=1 short-circuits the gh PR lookup to
# "none" so offline lifecycle tests can drive the helper deterministically
# without a network call. Git-side metadata is still read from the real
# refs so the test exercises the ref-walking path.
classify_pool_branch() {
  local raw_ref="${1:-}"
  local days="${2:-30}"
  local owner_repo="${3:-}"

  if [ -z "$raw_ref" ]; then
    return 0
  fi

  # Normalize ref shape; callers may pass either "pool/v2026.0/nN.kind.x"
  # or "refs/heads/pool/..." or "origin/pool/..." depending on whether
  # they walked git for-each-ref or git branch -r.
  local branch="$raw_ref"
  branch="${branch#refs/heads/}"
  branch="${branch#refs/remotes/}"
  branch="${branch#origin/}"

  # The helper is pool-branch-only. Refuse safety/, vault/, and anything
  # else by returning an empty record (caller skips).
  case "$branch" in
    pool/*) ;;
    *) return 0 ;;
  esac

  if [ -z "$owner_repo" ]; then
    local remote_url
    remote_url=$(git config --get remote.origin.url 2>/dev/null || true)
    owner_repo=$(echo "$remote_url" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
  fi

  # Resolve the pool tip SHA. Prefer origin's view (the report is about
  # candidates on origin); fall back to local refs when the caller is
  # walking a local-only branch.
  local pool_sha
  pool_sha=$(git rev-parse "refs/remotes/origin/$branch" 2>/dev/null \
    || git rev-parse "refs/heads/$branch" 2>/dev/null || true)
  if [ -z "$pool_sha" ]; then
    return 0
  fi

  # Allocation date: prefer the paired safety anchor's commit date
  # (immutable allocation receipt per reference_v4rian_safety_anchor_pairs).
  # The pair has identical suffix under the safety/ prefix.
  local safety_branch="safety/${branch#pool/}"
  local alloc_iso
  alloc_iso=$(git log -1 --format=%cI "refs/remotes/origin/$safety_branch" 2>/dev/null \
    || git log -1 --format=%cI "refs/heads/$safety_branch" 2>/dev/null || true)
  if [ -z "$alloc_iso" ]; then
    # Fall back to the first commit on the pool branch when the safety
    # anchor is unreachable (legacy pre-allocator branches, test repos).
    alloc_iso=$(git log --reverse --format=%cI "$pool_sha" 2>/dev/null | head -1 || true)
  fi
  local alloc_date="${alloc_iso%%T*}"
  [ -z "$alloc_date" ] && alloc_date="unknown"

  # Last commit on the pool branch (staleness signal).
  local last_iso
  last_iso=$(git log -1 --format=%cI "$pool_sha" 2>/dev/null || true)
  local last_date="${last_iso%%T*}"
  [ -z "$last_date" ] && last_date="unknown"

  # Owner inference: author login of the latest commit. Falls back to the
  # email local-part when the host configures emails as login proxies
  # (GitHub noreply addresses, etc.). Truly anonymous commits emit "unknown".
  local last_email last_login
  last_email=$(git log -1 --format=%ae "$pool_sha" 2>/dev/null || true)
  case "$last_email" in
    *@users.noreply.github.com)
      # GitHub noreply: NNNNNN+login@users.noreply.github.com or
      # login@users.noreply.github.com.
      last_login="${last_email%@users.noreply.github.com}"
      last_login="${last_login##*+}"
      ;;
    *)
      last_login=$(git log -1 --format=%an "$pool_sha" 2>/dev/null || true)
      ;;
  esac
  [ -z "$last_login" ] && last_login="unknown"

  # Reachable-from-main check: a pool branch whose tip is reachable from
  # origin/main has already shipped (its content is in a tag chain). It
  # may still be unvaulted on origin, but it is NOT abandoned. Classify
  # as "merged" and skip the PR probe.
  if git merge-base --is-ancestor "$pool_sha" \
      "refs/remotes/origin/main" 2>/dev/null; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$branch" "merged" "$alloc_date" "$last_date" "merged" "$last_login" \
      "tip reachable from origin/main (already released)"
    return 0
  fi

  # PR probe: which PR states ever existed for this head ref? In test-mode
  # we short-circuit to "none" so the offline lifecycle suite can exercise
  # the helper without network. In production, gh's --search keys by head
  # ref name and returns every PR (open + merged + closed) for that branch.
  local pr_states="none"
  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    pr_states="none"
  elif [ -n "$owner_repo" ] && command -v gh >/dev/null 2>&1; then
    local states_raw
    states_raw=$(gh pr list --repo "$owner_repo" --state all --head "$branch" \
      --json state --jq '[.[].state] | join(",")' 2>/dev/null || true)
    if [ -n "$states_raw" ]; then
      pr_states="$states_raw"
    fi
  fi

  # Last PR state in priority order: merged beats open beats closed beats
  # none. The gh query returns states as a comma-joined list in
  # most-recent-first order; we scan for the highest-priority match so
  # one merged PR in the list (even an old superseded one) wins over a
  # later closed-not-merged.
  local last_pr_state="none"
  case ",$pr_states," in
    *,MERGED,*|*,merged,*) last_pr_state="merged" ;;
    *,OPEN,*|*,open,*)     last_pr_state="open" ;;
    *,CLOSED,*|*,closed,*) last_pr_state="closed" ;;
  esac

  # A pool with a merged PR has already shipped semantically, even when
  # the tip is not reachable from origin/main (e.g. squash merges that
  # leave the original SHA orphaned). Classify as "merged".
  if [ "$last_pr_state" = "merged" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$branch" "merged" "$alloc_date" "$last_date" "$last_pr_state" "$last_login" \
      "at least one merged PR exists for this branch"
    return 0
  fi

  # Active: an open PR is the strongest signal that someone is still
  # working on this branch. Skip even when the last commit is old.
  if [ "$last_pr_state" = "open" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$branch" "active" "$alloc_date" "$last_date" "$last_pr_state" "$last_login" \
      "open PR exists; not abandoned"
    return 0
  fi

  # Staleness gate. Compute the age in days from last_iso. If the branch
  # has had a commit within the threshold, classify as "fresh" so the
  # caller can see it was considered and rejected on age alone.
  local age_days="unknown"
  if [ -n "$last_iso" ] && [ "$last_iso" != "" ]; then
    local now_epoch last_epoch normalized
    now_epoch=$(date -u +%s)
    # Normalize the ISO 8601 timestamp so both GNU and BSD date can parse
    # it. git %cI emits "YYYY-MM-DDTHH:MM:SS-07:00" (TZ offset with a
    # colon); BSD date's %z wants "-0700" (no colon). The two-step sed
    # collapses the offset colon and converts a trailing Z to +0000 so
    # the BSD fallback below succeeds on either shape.
    normalized=$(echo "$last_iso" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/; s/Z$/+0000/')
    if last_epoch=$(date -u -d "$last_iso" +%s 2>/dev/null); then
      :
    else
      last_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S%z" \
        "$normalized" +%s 2>/dev/null || echo "")
    fi
    if [ -n "$last_epoch" ]; then
      age_days=$(( (now_epoch - last_epoch) / 86400 ))
    fi
  fi

  if [ "$age_days" != "unknown" ] && [ "$age_days" -lt "$days" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$branch" "fresh" "$alloc_date" "$last_date" "$last_pr_state" "$last_login" \
      "last commit ${age_days}d ago; below ${days}d threshold"
    return 0
  fi

  # Candidate. No merged PR, no open PR, last commit older than threshold.
  # Distinguish the closed-not-merged case from the no-PR-at-all case in
  # the reason text since they call for different operator follow-ups
  # (a closed PR is a deliberate abandonment receipt; no PR at all is a
  # branch the developer may have forgotten about).
  local reason
  if [ "$last_pr_state" = "closed" ]; then
    reason="closed-not-merged PR exists; last commit ${age_days}d ago"
  else
    reason="no PR ever opened; last commit ${age_days}d ago"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$branch" "candidate" "$alloc_date" "$last_date" "$last_pr_state" "$last_login" \
    "$reason"
  return 0
}
# Work-tree guard for the claim ceremonies (claim-dev-merge, claim-main-release,
# finalize-pool-merge, ship). The claims write the work tree in two places
# only: the merge-commit amend, which commits the INDEX (a staged change
# would be folded into the published merge), and the dev sync or release
# checkout, which carries tracked edits onto another base. Untracked files
# are neither read nor written by either step, and git refuses on its own a
# checkout that would overwrite one, so they are listed and left in place:
# nothing is stashed or moved behind the operator's back.
#
# Usage: claim_tree_guard <tool> <rerun command>
# Returns 0 when the claim may proceed, 2 (after printing the exact recovery
# commands) when tracked changes or unresolved conflicts are present.
# claim_head_ok - 0 when HEAD may be claimed: on dev, or detached on a
# merge that descends from local dev. The detached form lets a linked
# worktree merge and claim while dev is checked out in another worktree
# (git refuses to check one branch out twice; friction ledger FP-12).
claim_head_ok() {
  local head
  head=$(git rev-parse --abbrev-ref HEAD)
  [ "$head" = "dev" ] && return 0
  [ "$head" = "HEAD" ] || return 1
  git rev-parse -q --verify refs/heads/dev >/dev/null || return 1
  git merge-base --is-ancestor refs/heads/dev HEAD
}

# claim_advance_local_dev OLD - after a claim from a detached HEAD, move
# local dev from OLD to the claimed HEAD: fast-forward the worktree that
# has dev checked out when it is clean, update the ref when none has it,
# otherwise print the one command that finishes the move. No-op on dev.
claim_advance_local_dev() {
  local old="$1" new wt
  [ "$(git rev-parse --abbrev-ref HEAD)" = "HEAD" ] || return 0
  new=$(git rev-parse HEAD)
  wt=$(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} /^branch refs\/heads\/dev$/{print w; exit}')
  if [ -z "$wt" ]; then
    git update-ref refs/heads/dev "$new" "$old" && echo "-> local dev advanced to $new"
    return 0
  fi
  if [ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] \
      && git -C "$wt" -c core.hooksPath=/dev/null merge -q --ff-only "$new"; then
    echo "-> local dev fast-forwarded to $new in $wt"
  else
    echo "! local dev in $wt not moved (tracked changes or not a fast-forward); finish with:" >&2
    echo "    git -C '$wt' merge --ff-only $new" >&2
  fi
}

claim_tree_guard() {
  local tool="$1" rerun="$2"
  local unmerged staged unstaged untracked paths
  unmerged=$(git diff --name-only --diff-filter=U 2>/dev/null)
  staged=$(git diff --cached --name-only 2>/dev/null)
  unstaged=$(git diff --name-only 2>/dev/null)
  untracked=$(git ls-files --others --exclude-standard 2>/dev/null)
  if [ -n "$unmerged" ]; then
    echo "X $tool: unresolved merge conflicts; the claim never seals a half-finished merge." >&2
    printf '%s\n' "$unmerged" | sed 's/^/    /' >&2
    echo "  Resolve and commit the merge (or abort it with: git merge --abort), then rerun:" >&2
    echo "    $rerun" >&2
    return 2
  fi
  if [ -n "$staged$unstaged" ]; then
    paths=$(printf '%s\n%s\n' "$staged" "$unstaged" | sed '/^$/d' | sort -u)
    echo "X $tool: tracked changes in the work tree would be folded into the merge commit or carried across the sync." >&2
    if [ -n "$staged" ]; then
      echo "  staged:" >&2
      printf '%s\n' "$staged" | sed 's/^/    /' >&2
    fi
    if [ -n "$unstaged" ]; then
      echo "  modified:" >&2
      printf '%s\n' "$unstaged" | sed 's/^/    /' >&2
    fi
    echo "  Park them, rerun, then restore them:" >&2
    printf '    git stash push -m "before %s" --' "$tool" >&2
    printf '%s\n' "$paths" | while IFS= read -r p; do printf " '%s'" "$p"; done >&2
    printf '\n    %s\n    git stash pop\n' "$rerun" >&2
    return 2
  fi
  if [ -n "$untracked" ]; then
    echo "→ $tool: $(printf '%s\n' "$untracked" | wc -l | tr -d ' ') untracked file(s) left in place (the claim never writes them; a sync that would overwrite one is refused by name)"
  fi
  return 0
}

# Fallback post-merge hook for a repo whose core.hooksPath went missing
# (fresh config, a tool that unset it, a hand edit). git then runs the
# default hooks dir, where this shim warns, restores core.hooksPath and
# hands over to the framework post-merge so the claim still runs at merge
# time. Installed only when the slot is empty or already ours; a consumer's
# own post-merge there is never overwritten. Silent unless it writes.
ensure_merge_hook_fallback() {
  local common hooks_dir shim marker
  marker="how-git fallback post-merge"
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  hooks_dir="$common/hooks"
  shim="$hooks_dir/post-merge"
  if [ -f "$shim" ] && ! grep -q "$marker" "$shim" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$hooks_dir" || return 0
  local body
  body=$(cat <<'SHIM'
#!/bin/sh
# how-git fallback post-merge. git runs this file only while core.hooksPath
# does not point at the framework hooks; it restores the setting and runs
# the framework post-merge so the version claim is not skipped.
root=$(git rev-parse --show-toplevel) || exit 0
ns=.io.v4rian.how-git
[ -x "$root/$ns/githooks/post-merge" ] || exit 0
echo "post-merge: WARNING core.hooksPath was '$(git config core.hooksPath || echo unset)'; the framework hooks were off for this merge." >&2
echo "post-merge: restoring core.hooksPath = $ns/githooks and running the claim now." >&2
git config core.hooksPath "$ns/githooks"
exec "$root/$ns/githooks/post-merge" "$@"
SHIM
)
  if [ ! -f "$shim" ] || [ "$(cat "$shim")" != "$body" ]; then
    printf '%s\n' "$body" > "$shim" || return 0
  fi
  # git skips a hook without its exec bit; restore it even when the body
  # already matches.
  [ -x "$shim" ] || chmod +x "$shim" || return 0
  return 0
}

# Prints one doctor issue line when the hooks-off fallback post-merge is not
# installed in the default hooks dir (nothing when it is, or when a
# consumer's own post-merge occupies the slot). Read-only.
merge_hook_fallback_issue() {
  local common shim
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  shim="$common/hooks/post-merge"
  if [ ! -f "$shim" ]; then
    echo "fallback post-merge missing in $common/hooks (a merge with core.hooksPath unset would go unclaimed); run heal.sh"
  elif grep -q "how-git fallback post-merge" "$shim" 2>/dev/null && [ ! -x "$shim" ]; then
    echo "fallback post-merge in $common/hooks is not executable; run heal.sh"
  fi
}
