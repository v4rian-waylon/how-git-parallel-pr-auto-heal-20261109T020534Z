#!/usr/bin/env bash
# jira-ingress.sh - file a how-git-spec JIRA ticket from manual fields OR a casual prompt.
#
# Two operating modes:
#
#   Manual mode: --title T --body B --kind K [--sprint S]
#     The operator hand-composes the ticket. The script validates every
#     field against the same rules git-commit-audit and git-strategy-audit
#     enforce on commits and branches (title shape, kind allowlist, body
#     shape, em-dash ban, no fabricated JIRA codes), then submits the
#     ticket to JIRA via the official Atlassian CLI `acli`
#     (https://developer.atlassian.com/cloud/acli/). When --sprint is
#     omitted the ticket lands in the backlog; when --sprint <N> is
#     supplied the ticket binds to that sprint via the JIRA Cloud
#     custom-field path (default field id customfield_10020; override
#     via JIRA_SPRINT_FIELD) so the existing JIRA Automation rule that
#     watches in-sprint ticket creates fires
#     `gh workflow run allocate-pool-branch.yml` to spawn the paired
#     pool + safety pair against the framework repo.
#
#   Claude-driven mode: --prompt "casual description" [--sprint S]
#     The operator passes a one-line natural-language description. The
#     script spawns `claude -p` via the shared claude_render_spec helper
#     in _lib.sh with a system prompt that names the in-repo
#     git-commit-audit and git-strategy-audit skill files plus inlines
#     the title shape, kind allowlist, body shape, bullet rules, em-dash
#     ban, and the no-fabricated-JIRA-codes contract. Claude returns
#     either a complete title/body/kind JSON payload OR one or more
#     QUESTION: lines if senior-engineer judgment detects gaps the prompt
#     does not cover (the parser is named, the subsystem is ambiguous,
#     etc.). The CLI surfaces questions to the operator (interactive
#     `read -r` when stdin is a TTY, batched --answers <file> for
#     non-interactive runs), re-invokes claude with the augmented
#     context, and iterates until claude returns the JSON payload. The
#     payload is then validated like manual mode and submitted to JIRA.
#
# Sprint routing:
#
#   No sprint -> backlog. `acli jira workitem create -p <proj> -t Task
#   -s T -d B`. Verify via `acli jira workitem search`.
#
#   Active sprint -> in-sprint. Sprint binding goes through the
#   custom-field path because `acli jira workitem create` does not
#   expose a dedicated --sprint flag (the documented input flags cover
#   project, summary, description, type, parent, label, assignee). The
#   script renders the title plus description into a JSON payload that
#   also carries `fields.<JIRA_SPRINT_FIELD>: <sprint_id>` and invokes
#   `acli jira workitem create --from-json <payload.json>`. The JIRA
#   Cloud default sprint custom-field id is customfield_10020; override
#   via the JIRA_SPRINT_FIELD env var when the operator's instance
#   uses a different id. The existing JIRA Automation watches in-sprint
#   ticket creates and fires the gh allocator workflow.
#
# Off-grid awareness (per feedback_jira_is_integration_not_component):
#
#   When get_mode returns off-grid, JIRA is not reachable. The tool still
#   renders a spec'd ticket structure (printed to STDOUT and saved to
#   .io.v4rian.how-git/.local/jira-drafts/<stamp>.md) so the operator can
#   submit it later; emits a synthetic JIRA-less branch name suggestion
#   (pool/v<MAJOR>/n<N>.<kind>.<short> with no JIRA segment).
#
#   --no-submit skips the JIRA API call entirely (useful in any mode for
#   previewing what would be filed).
#
# acli dependency:
#
#   The Atlassian `acli` CLI (https://developer.atlassian.com/cloud/acli/)
#   is required for the submit path. If absent, the tool emits a
#   precondition banner naming the install command:
#     brew tap atlassian/homebrew-acli && brew install acli
#   on macOS, and the project install guide for Linux. Auto-install is
#   NOT attempted (workspace rule: no auto-installs of root-level deps).
#   The operator runs the install, then `acli jira auth login --site
#   <site> --email <email> --token` once, then re-runs the ingress tool.
#
# Usage:
#   jira-ingress.sh --title T --body B --kind K [--sprint N] [--project P]
#                                               [--type T] [--no-submit] [--dry-run]
#   jira-ingress.sh --prompt "natural language" [--sprint N] [--project P]
#                                               [--type T] [--answers FILE]
#                                               [--no-submit] [--dry-run]
#   jira-ingress.sh --from-prompt-file PATH    (read prompt body from file)
#   jira-ingress.sh -h | --help
#
# Flags:
#
#   --title T               Manual-mode title; must match [TAG] subject (8-72 chars).
#   --body B                Manual-mode body; must include description paragraph.
#   --kind K                Manual-mode or claude-mode override; one of:
#                           feature, fix, refactor, r&d, doc.
#   --sprint N              Active sprint id; routes to in-sprint
#                           creation via the custom-field path
#                           (triggers JIRA Automation -> gh allocator).
#                           Omit to route to backlog.
#   --prompt TEXT           Claude-mode operator description (verbatim).
#   --from-prompt-file PATH Claude-mode operator description (read from file).
#                           Overrides --prompt when both supplied.
#   --answers FILE          Claude-mode batched answer source for any
#                           QUESTION: lines surfaced. The file is a
#                           plain-text list of answers, one per line,
#                           in the same order claude asked them. When
#                           absent and stdin is a TTY, the tool prompts
#                           interactively via `read -r`. When absent and
#                           stdin is non-TTY, the tool fails with exit 5.
#   --project P             JIRA project key (e.g. PROJ). Default: derive
#                           from the JIRA_PROJECT env var; refuse if
#                           neither set.
#   --type T                JIRA issue type. Default: Task.
#   --no-submit             Skip the acli submit call; render + validate only.
#                           Useful for previewing the spec'd ticket.
#   --dry-run               Render and print the planned `acli jira workitem
#                           create` command but do not execute it. Implies
#                           --no-submit. Always exits 0 on a successful render.
#   -h | --help             Show this help and exit.
#
# Environment:
#   JIRA_PROJECT            Default --project when the flag is absent.
#   JIRA_DEFAULT_TYPE       Default --type when the flag is absent.
#                           Falls back to "Task".
#   JIRA_SPRINT_FIELD       JIRA Cloud custom-field id for sprint binding.
#                           Default: customfield_10020 (the Atlassian
#                           Cloud factory default). Override when the
#                           operator's instance uses a different id.
#   LIFECYCLE_TEST_MODE     When set to 1, every `acli` CLI call is
#                           replaced with a print of the planned command,
#                           and claude_render_spec returns a canned
#                           payload. Used by the offline lifecycle suite.
#   CLAUDE_RENDER_TEST_REPLY  When set under LIFECYCLE_TEST_MODE, drives
#                           the canned claude reply (see _lib.sh).
#
# Exit codes:
#   0    ticket rendered + (when --no-submit / --dry-run) printed, or
#        submitted to JIRA successfully.
#   2    bad CLI inputs (missing required flag, both modes selected, etc.).
#   3    missing system dependency (bash, python3, acli).
#   4    validation failure (title shape, kind allowlist, body shape,
#        em-dash present, fabricated JIRA code, etc.).
#   5    claude-driven question loop needs operator input but stdin is
#        not a TTY and no --answers FILE was supplied.
#   6    acli submit call failed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate script + namespace + repo
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS_DIR=$(dirname "$SCRIPT_DIR")
REPO_ROOT=$(cd "$NS_DIR/.." 2>/dev/null && pwd)
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TITLE=""
BODY=""
KIND=""
SPRINT=""
PROMPT=""
PROMPT_FILE=""
ANSWERS_FILE=""
PROJECT="${JIRA_PROJECT:-}"
ISSUE_TYPE="${JIRA_DEFAULT_TYPE:-Task}"
SPRINT_FIELD="${JIRA_SPRINT_FIELD:-customfield_10020}"
NO_SUBMIT=false
DRY_RUN=false

usage() { sed -n '2,138p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --title)             TITLE="$2"; shift 2 ;;
    --body)              BODY="$2"; shift 2 ;;
    --kind)              KIND="$2"; shift 2 ;;
    --sprint)            SPRINT="$2"; shift 2 ;;
    --prompt)            PROMPT="$2"; shift 2 ;;
    --from-prompt-file)  PROMPT_FILE="$2"; shift 2 ;;
    --answers)           ANSWERS_FILE="$2"; shift 2 ;;
    --project)           PROJECT="$2"; shift 2 ;;
    --type)              ISSUE_TYPE="$2"; shift 2 ;;
    --no-submit)         NO_SUBMIT=true; shift ;;
    --dry-run)           DRY_RUN=true; NO_SUBMIT=true; shift ;;
    -h|--help)           usage 0 ;;
    *) echo "X jira-ingress: unknown flag: $1" >&2; usage 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Mode resolution: manual XOR claude-driven.
#   Manual: --title + --body + --kind all present.
#   Claude: --prompt OR --from-prompt-file supplied.
# Mixing the two is a usage error (the script will not silently prefer one).
# ---------------------------------------------------------------------------
MANUAL_MODE=false
CLAUDE_MODE=false

if [ -n "$TITLE" ] || [ -n "$BODY" ] || [ -n "$KIND" ]; then
  MANUAL_MODE=true
fi
if [ -n "$PROMPT" ] || [ -n "$PROMPT_FILE" ]; then
  CLAUDE_MODE=true
fi

if $MANUAL_MODE && $CLAUDE_MODE; then
  echo "X jira-ingress: --title/--body/--kind and --prompt/--from-prompt-file are mutually exclusive" >&2
  echo "  pick one mode: manual (you compose the fields) or claude-driven (claude composes from a prompt)" >&2
  exit 2
fi
if ! $MANUAL_MODE && ! $CLAUDE_MODE; then
  echo "X jira-ingress: pick a mode" >&2
  echo "  manual:        --title T --body B --kind K [--sprint N]" >&2
  echo "  claude-driven: --prompt \"natural language description\" [--sprint N]" >&2
  exit 2
fi

# --from-prompt-file overrides --prompt when both supplied (matches the
# allocator's --requirement-file precedence so the two CLIs feel consistent).
if [ -n "$PROMPT_FILE" ]; then
  if [ ! -f "$PROMPT_FILE" ]; then
    echo "X jira-ingress: --from-prompt-file '$PROMPT_FILE' does not exist" >&2
    exit 2
  fi
  PROMPT=$(cat "$PROMPT_FILE")
fi

# ---------------------------------------------------------------------------
# Dependency probe. python3 + acli are needed for submit; bash + python3
# alone suffice for render-only (--dry-run / --no-submit / off-grid). The
# acli check uses precondition_banner (per the project-agnostic admin
# tooling pattern in _lib.sh) so the install command shows clearly.
# ---------------------------------------------------------------------------
for t in bash python3; do
  if ! command -v "$t" >/dev/null 2>&1; then
    precondition_banner "jira-ingress" \
      "Missing required CLI '$t'." \
      "Install with: $(suggest_install_cmd "$t" "$(detect_os)")" \
      "Then re-run jira-ingress."
    exit 3
  fi
done

# acli is only mandatory for the actual submit. Render-only paths
# (manual --no-submit, --dry-run, off-grid mode) can complete without it.
# When the submit IS in scope and acli is missing, emit the banner and
# exit 3 so the operator sees the install command rather than a confusing
# downstream error.
need_acli() {
  $NO_SUBMIT && return 1
  local mode
  mode=$(get_mode 2>/dev/null || echo "connected")
  if [ "$mode" = "off-grid" ]; then
    # Off-grid never submits. The render still happens; the draft lands
    # under .io.v4rian.how-git/.local/jira-drafts/.
    return 1
  fi
  return 0
}

if need_acli; then
  if ! command -v acli >/dev/null 2>&1; then
    precondition_banner "jira-ingress" \
      "Required CLI 'acli' (the official Atlassian CLI) is not on PATH." \
      "This tool files JIRA tickets to the v4rian how-git spec via acli." \
      "" \
      "Install:" \
      "  macOS:   brew tap atlassian/homebrew-acli && brew install acli" \
      "  Linux:   see https://developer.atlassian.com/cloud/acli/guides/install-acli/" \
      "" \
      "Then authenticate once:" \
      "  echo <api-token> | acli jira auth login \\" \
      "    --site \"<site>.atlassian.net\" --email \"<you>@example.com\" --token" \
      "" \
      "Then re-run jira-ingress." \
      "" \
      "To preview without submitting (no acli needed):" \
      "  --no-submit    render + validate the ticket; do not file it." \
      "  --dry-run      print the planned 'acli jira workitem create' command."
    exit 3
  fi
fi

# ---------------------------------------------------------------------------
# Validation helpers. Encode the same lens git-commit-audit applies to
# commit titles + bodies so the JIRA ticket Joel ends up with carries a
# title + body that pass commit audit on the resulting branch.
# ---------------------------------------------------------------------------

# Allowed kinds (the same allowlist scripts/allocate-pool-branch.sh validates
# against). Used for the --kind input and the kind field in the claude reply.
ALLOWED_KINDS_REGEX='^(feature|fix|refactor|r&d|doc)$'

# Allowed title tags (the same allowlist git-commit-audit Section B uses).
# Reconcile and merge are excluded; jira-ingress files NEW work, not
# reconcile receipts or merge tags.
ALLOWED_TAGS_REGEX='^\[(FIX|NEW|REFACTOR|DOCS|TEST|REVERT|HOTFIX)\] '

# Em-dash and en-dash characters. The pre-commit hook scrubs these from
# commit messages; the ingress validation refuses them upfront so the
# ticket text matches the spec the eventual commit message will adhere to.
contains_emdash() {
  printf '%s' "$1" | grep -P '[\xE2][\x80][\x93-\x94]' >/dev/null 2>&1
}

# Validate the title against the same shape git-commit-audit enforces on
# commit titles. The audit runs BEFORE the JIRA call so the operator gets
# a clear refusal on a malformed title instead of a JIRA ticket that
# would fail audit on the resulting commit message.
validate_title() {
  local t="$1"
  if [ -z "$t" ]; then
    echo "X title is empty" >&2; return 1
  fi
  local len=${#t}
  if [ "$len" -lt 8 ] || [ "$len" -gt 72 ]; then
    echo "X title length is $len chars; spec requires 8 to 72 inclusive" >&2; return 1
  fi
  if ! printf '%s' "$t" | grep -qE "$ALLOWED_TAGS_REGEX"; then
    echo "X title does not start with one of [FIX] [NEW] [REFACTOR] [DOCS] [TEST] [REVERT] [HOTFIX] (case-sensitive, with trailing space)" >&2
    return 1
  fi
  if contains_emdash "$t"; then
    echo "X title contains an em-dash or en-dash; spec bans both in title prose" >&2; return 1
  fi
  return 0
}

# Validate the body against git-commit-audit Section C. The body must open
# with a description paragraph; for [FIX] / [HOTFIX] titles, the body must
# also contain "Cause:" and "Fix:" sections. Em/en-dashes are banned in
# body prose. Forbidden zip-mechanism words are checked too.
validate_body() {
  local b="$1"
  local t="$2"
  if [ -z "$b" ]; then
    echo "X body is empty; spec requires a 1-3 sentence description paragraph at minimum" >&2; return 1
  fi
  if contains_emdash "$b"; then
    echo "X body contains an em-dash or en-dash; spec bans both in body prose" >&2; return 1
  fi
  case "$t" in
    "[FIX] "*|"[HOTFIX] "*)
      if ! printf '%s' "$b" | grep -qE '(^|[[:space:]])Cause:'; then
        echo "X body lacks 'Cause:' section (mandatory for [FIX] / [HOTFIX] per git-commit-audit Section C)" >&2
        return 1
      fi
      if ! printf '%s' "$b" | grep -qE '(^|[[:space:]])Fix:'; then
        echo "X body lacks 'Fix:' section (mandatory for [FIX] / [HOTFIX] per git-commit-audit Section C)" >&2
        return 1
      fi
      ;;
  esac
  # Forbidden zip-mechanism vocabulary (a subset of the same list
  # git-commit-audit Section C.16 forbids).
  local banned
  for banned in 'BAK' 'bak import' 'historical import' 'recovered from' 'reconstructed' 'WIP snapshot' 'from the zip'; do
    if printf '%s' "$b" | grep -qF "$banned"; then
      echo "X body contains forbidden zip-mechanism phrase: '$banned'" >&2
      return 1
    fi
  done
  return 0
}

validate_kind() {
  local k="$1"
  if [ -z "$k" ]; then
    echo "X kind is empty; must be one of feature, fix, refactor, r&d, doc" >&2; return 1
  fi
  if ! printf '%s' "$k" | grep -qE "$ALLOWED_KINDS_REGEX"; then
    echo "X kind '$k' is not in allowlist (feature, fix, refactor, r&d, doc)" >&2
    return 1
  fi
  return 0
}

validate_sprint() {
  local s="$1"
  [ -z "$s" ] && return 0
  if ! printf '%s' "$s" | grep -qE '^[0-9]+$'; then
    echo "X sprint '$s' must be a positive integer (or omitted for backlog routing)" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Claude-driven mode: drive the question loop until claude returns a JSON
# payload. The loop bounds itself at MAX_TURNS to prevent runaway iteration
# in case claude keeps surfacing new gaps (legitimate or not).
# ---------------------------------------------------------------------------
MAX_TURNS=5

run_claude_loop() {
  local seed_prompt="$1"
  local turns=0
  local prior=""
  local reply
  while [ "$turns" -lt "$MAX_TURNS" ]; do
    turns=$(( turns + 1 ))
    echo "  -> claude_render_spec turn $turns of $MAX_TURNS" >&2
    if ! reply=$(claude_render_spec "$seed_prompt" "$prior"); then
      echo "X claude_render_spec failed at turn $turns" >&2
      return 1
    fi
    # Detect QUESTION: lines. The contract is exclusive: claude returns
    # EITHER a JSON payload OR one-or-more QUESTION: lines, never both.
    if printf '%s' "$reply" | grep -qE '^[[:space:]]*QUESTION:'; then
      echo "  · claude surfaced gap questions at turn $turns" >&2
      local questions
      questions=$(printf '%s' "$reply" | grep -E '^[[:space:]]*QUESTION:' | sed -E 's/^[[:space:]]*//')
      local answers ra_rc
      answers=$(read_answers_for_questions "$questions"); ra_rc=$?
      if [ "$ra_rc" -ne 0 ]; then
        # Preserve the special exit code 5 (no TTY, no --answers) so the
        # caller can map it directly to its own exit 5 path instead of
        # collapsing to a generic claude-failure exit 4.
        return "$ra_rc"
      fi
      # Compose the prior-context block: each Q paired with its A,
      # verbatim, so claude's next turn sees the same content the
      # operator entered.
      prior=$(printf '%s\n%s' "${prior:+$prior$'\n'}" "$(paste_qa "$questions" "$answers")")
      continue
    fi
    # No QUESTION lines: treat reply as the JSON payload. Parser is
    # downstream; here we just return the raw reply.
    printf '%s\n' "$reply"
    return 0
  done
  echo "X claude_render_spec exceeded $MAX_TURNS turns without converging on a payload" >&2
  return 1
}

# Surface QUESTION: lines to the operator and gather answers. When
# --answers FILE is supplied, read one answer per line. When stdin is a
# TTY, prompt interactively. Otherwise refuse (exit 5) so a CI run that
# accidentally enters claude mode without --answers fails loudly instead
# of hanging on read.
read_answers_for_questions() {
  local questions="$1"
  local q_count
  q_count=$(printf '%s\n' "$questions" | wc -l | tr -d ' ')
  local answers=""
  if [ -n "$ANSWERS_FILE" ]; then
    if [ ! -f "$ANSWERS_FILE" ]; then
      echo "X --answers file '$ANSWERS_FILE' does not exist" >&2
      return 1
    fi
    answers=$(cat "$ANSWERS_FILE")
    local a_count
    a_count=$(printf '%s\n' "$answers" | wc -l | tr -d ' ')
    if [ "$a_count" -lt "$q_count" ]; then
      echo "X --answers file has $a_count lines; claude surfaced $q_count questions" >&2
      return 1
    fi
  elif [ -t 0 ]; then
    # Interactive: echo each question, read one line of answer per question.
    local line
    while IFS= read -r line; do
      printf '%s\n' "$line" >&2
      printf '  > ' >&2
      local ans
      IFS= read -r ans
      answers=$(printf '%s\n%s' "${answers:+$answers$'\n'}" "$ans")
    done < <(printf '%s\n' "$questions")
  else
    echo "X claude surfaced $q_count question(s) but stdin is not a TTY and --answers FILE was not supplied" >&2
    echo "  re-run with --answers <file> listing one answer per line in the same order as the questions:" >&2
    printf '%s\n' "$questions" | sed 's/^/    /' >&2
    return 5
  fi
  printf '%s' "$answers"
  return 0
}

# Pair each QUESTION: line with the corresponding ANSWER: line so claude's
# next turn sees a clean Q-A transcript.
paste_qa() {
  local questions="$1"
  local answers="$2"
  paste -d'\n' <(printf '%s\n' "$questions") <(printf '%s\n' "$answers" | sed 's/^/ANSWER: /')
}

# Parse the claude JSON payload into TITLE / BODY / KIND. Returns 0 on
# success; non-zero on parse failure. Uses python3 (already required by
# the dependency probe at the top of the script).
parse_claude_payload() {
  local reply="$1"
  local extracted_title extracted_body extracted_kind extracted_sprint
  # The reply may contain extra newlines around the JSON object; the
  # python parser tolerates that. We try `json.loads(whole text)` first,
  # then each non-blank line, then the longest {...} substring. Writing
  # the python script to a tmpfile (instead of an inline heredoc) lets
  # us pipe the reply on stdin; an inline `python3 <<PY` claims stdin
  # for the heredoc and the piped reply never reaches the script.
  local py_file parsed
  py_file=$(mktemp -t jira-ingress-parse-XXXXXX)
  cat >"$py_file" <<'PY'
import json, sys
text = sys.stdin.read()
candidates = []
text_stripped = text.strip()
if text_stripped:
    candidates.append(text_stripped)
for line in text.splitlines():
    line_stripped = line.strip()
    if line_stripped:
        candidates.append(line_stripped)
start = text.find('{')
end = text.rfind('}')
if start != -1 and end != -1 and end > start:
    candidates.append(text[start:end+1])
for cand in candidates:
    try:
        d = json.loads(cand)
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    title = d.get('title', '')
    body = d.get('body', '')
    kind = d.get('kind', '')
    sprint = d.get('sprint', '')
    print(json.dumps({'title': title, 'body': body, 'kind': kind, 'sprint': sprint}))
    sys.exit(0)
sys.exit(1)
PY
  parsed=$(printf '%s' "$reply" | python3 "$py_file" || true)
  rm -f "$py_file"
  if [ -z "$parsed" ]; then
    return 1
  fi
  extracted_title=$(printf '%s' "$parsed" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("title",""))')
  extracted_body=$(printf '%s' "$parsed" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body",""))')
  extracted_kind=$(printf '%s' "$parsed" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("kind",""))')
  extracted_sprint=$(printf '%s' "$parsed" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sprint",""))')
  TITLE="$extracted_title"
  BODY="$extracted_body"
  KIND="$extracted_kind"
  # Only adopt the claude-suggested sprint if the operator did not already
  # supply --sprint on the CLI (the CLI value wins because sprint routing
  # is an operator decision, not a claude decision).
  if [ -z "$SPRINT" ] && [ -n "$extracted_sprint" ]; then
    SPRINT="$extracted_sprint"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch by mode
# ---------------------------------------------------------------------------
if $CLAUDE_MODE; then
  if [ -z "$PROMPT" ]; then
    echo "X jira-ingress: claude-driven mode requires --prompt or --from-prompt-file with content" >&2
    exit 2
  fi
  echo "-> claude-driven render from operator prompt" >&2
  REPLY=$(run_claude_loop "$PROMPT") || {
    rc=$?
    [ "$rc" = "5" ] && exit 5
    exit 4
  }
  if ! parse_claude_payload "$REPLY"; then
    echo "X failed to parse JSON payload from claude reply" >&2
    echo "  raw reply:" >&2
    printf '%s\n' "$REPLY" | sed 's/^/    /' >&2
    exit 4
  fi
  echo "  rendered title: $TITLE" >&2
  echo "  rendered kind:  $KIND" >&2
fi

# ---------------------------------------------------------------------------
# Validation (applies to both modes). Manual mode validates the
# operator-supplied fields verbatim; claude mode validates the parsed
# payload so a claude reply that drifts from the spec fails loudly.
# ---------------------------------------------------------------------------
validate_title "$TITLE"   || exit 4
validate_body  "$BODY" "$TITLE" || exit 4
validate_kind  "$KIND"    || exit 4
validate_sprint "$SPRINT" || exit 4

if [ -z "$PROJECT" ]; then
  precondition_banner "jira-ingress" \
    "No JIRA project key provided." \
    "Pass --project <KEY> or export JIRA_PROJECT=<KEY> in your environment." \
    "" \
    "The project key is the prefix of every JIRA issue in the target project" \
    "(for example: PROJ for PROJ-123, RND for RND-42)."
  exit 2
fi

# ---------------------------------------------------------------------------
# Off-grid render-only path. When the repo is in off-grid mode, JIRA is by
# design unreachable; the tool still produces a rendered draft so the
# operator can paste it into JIRA later when connectivity is restored.
# The draft lands under .io.v4rian.how-git/.local/jira-drafts/<stamp>.md
# (.local is the operator's per-clone scratch space; the rest of the
# framework reserves it for similar non-tracked artifacts).
# ---------------------------------------------------------------------------
MODE=$(get_mode 2>/dev/null || echo "connected")

render_jira_draft_path() {
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  local dir="$REPO_ROOT/.io.v4rian.how-git/.local/jira-drafts"
  mkdir -p "$dir"
  printf '%s/%s.md\n' "$dir" "$stamp"
}

if [ "$MODE" = "off-grid" ]; then
  draft=$(render_jira_draft_path)
  {
    printf '# %s\n\n' "$TITLE"
    printf '%s\n' "$BODY"
    printf '\n---\nproject: %s\ntype: %s\nkind: %s\n' "$PROJECT" "$ISSUE_TYPE" "$KIND"
    [ -n "$SPRINT" ] && printf 'sprint: %s\n' "$SPRINT"
    printf 'mode: off-grid (JIRA unreachable; submit later)\n'
  } > "$draft"
  echo "+----------------------------------------------------------------+"
  echo "| off-grid mode: JIRA submit skipped; draft saved for later      |"
  echo "+----------------------------------------------------------------+"
  echo "  draft: $draft"
  # Suggest a JIRA-less branch name per
  # feedback_jira_is_integration_not_component so the operator can
  # allocate against the rendered ticket without waiting for a JIRA key.
  major=""
  if [ -x "$NS_DIR/bin/version" ]; then
    seal=$("$NS_DIR/bin/version" --seal 2>/dev/null || true)
    if printf '%s' "$seal" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
      major="${seal%.*}"
    fi
  fi
  short_slug=$(printf '%s' "$TITLE" | sed -E 's/^\[[A-Z]+\][[:space:]]+//' \
    | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')
  if [ -n "$major" ]; then
    suggested="pool/$major/n<N>.$KIND.$short_slug"
  else
    suggested="pool/n<N>.$KIND.$short_slug"
  fi
  echo "  suggested branch (no JIRA segment): $suggested"
  echo "  allocate via: bin/create-pool-branch \"$short_slug\" --no-jira --kind $KIND"
  exit 0
fi

# ---------------------------------------------------------------------------
# Build the planned acli invocation.
#
# Two code paths:
#
#   Backlog (no --sprint): the documented acli flags suffice. We pass
#   --project, --type, --summary, --description directly.
#
#   In-sprint (--sprint N): acli jira workitem create does NOT expose a
#   --sprint flag (the documented input flags cover project, summary,
#   description, type, parent, label, assignee). Sprint binding goes
#   through the --from-json path so we can write the sprint custom-field
#   id into the payload. The default custom-field id is
#   customfield_10020 (Atlassian Cloud factory default); override via
#   the JIRA_SPRINT_FIELD env var when the operator's instance uses a
#   different id. The from-json payload also carries project, type,
#   summary, description so the JSON file is fully self-contained.
# ---------------------------------------------------------------------------

# Path 1: backlog (no sprint binding). Direct flag invocation.
build_backlog_args() {
  ACLI_ARGS=( jira workitem create
    -p "$PROJECT"
    -t "$ISSUE_TYPE"
    -s "$TITLE"
    -d "$BODY"
  )
}

# Path 2: in-sprint. Build a JSON payload with the sprint custom-field
# binding plus all the same project / type / summary / description fields
# we would otherwise pass as flags, then invoke acli with --from-json.
# The JSON file is created in a tmpdir and cleaned up on script exit;
# PAYLOAD_FILE is a script-level (NOT function-local) so the EXIT trap
# can still see it after the function returns.
PAYLOAD_FILE=""
cleanup_payload_file() {
  if [ -n "${PAYLOAD_FILE:-}" ] && [ -f "$PAYLOAD_FILE" ]; then
    rm -f "$PAYLOAD_FILE"
  fi
}
trap cleanup_payload_file EXIT

build_in_sprint_args() {
  PAYLOAD_FILE=$(mktemp -t jira-ingress-payload-XXXXXX.json)
  PROJECT_KEY="$PROJECT" \
  ISSUE_TYPE_NAME="$ISSUE_TYPE" \
  SUMMARY="$TITLE" \
  DESCRIPTION="$BODY" \
  SPRINT_ID="$SPRINT" \
  SPRINT_FIELD_NAME="$SPRINT_FIELD" \
    python3 -c '
import json, os
payload = {
  "fields": {
    "project": {"key": os.environ["PROJECT_KEY"]},
    "issuetype": {"name": os.environ["ISSUE_TYPE_NAME"]},
    "summary": os.environ["SUMMARY"],
    "description": os.environ["DESCRIPTION"],
    os.environ["SPRINT_FIELD_NAME"]: int(os.environ["SPRINT_ID"]),
  }
}
print(json.dumps(payload, indent=2))
' > "$PAYLOAD_FILE"
  ACLI_ARGS=( jira workitem create --from-json "$PAYLOAD_FILE" )
}

if [ -n "$SPRINT" ]; then
  build_in_sprint_args
else
  build_backlog_args
fi

if $DRY_RUN; then
  echo "[dry-run] planned acli invocation:"
  printf '  acli'
  for arg in ${ACLI_ARGS[@]+"${ACLI_ARGS[@]}"}; do
    printf ' %q' "$arg"
  done
  printf '\n'
  if [ -n "$SPRINT" ]; then
    echo "[dry-run] sprint routing: in-sprint ($SPRINT) -> binds via $SPRINT_FIELD in --from-json payload -> triggers JIRA Automation -> gh allocator dispatch"
    if [ -n "${PAYLOAD_FILE:-}" ] && [ -f "$PAYLOAD_FILE" ]; then
      echo "[dry-run] payload that would be passed to --from-json:"
      sed 's/^/    /' "$PAYLOAD_FILE"
    fi
  else
    echo "[dry-run] sprint routing: backlog (no automation fires)"
  fi
  exit 0
fi

if $NO_SUBMIT; then
  echo "[no-submit] rendered ticket follows; acli not invoked."
  echo "  title: $TITLE"
  echo "  kind:  $KIND"
  if [ -n "$SPRINT" ]; then
    echo "  sprint: $SPRINT (binds via $SPRINT_FIELD)"
  else
    echo "  sprint: (none; routes to backlog)"
  fi
  echo "---"
  printf '%s\n' "$BODY"
  echo "---"
  exit 0
fi

# ---------------------------------------------------------------------------
# Actually file the ticket. In LIFECYCLE_TEST_MODE the call is replaced by
# a print so the offline lifecycle suite can assert the planned invocation
# without invoking acli for real.
# ---------------------------------------------------------------------------
if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
  echo "[test-mode] would invoke: acli ${ACLI_ARGS[*]:-}"
  if [ -n "$SPRINT" ]; then
    echo "[test-mode] sprint routing: in-sprint ($SPRINT) -> binds via $SPRINT_FIELD -> triggers JIRA Automation -> gh allocator dispatch"
  else
    echo "[test-mode] sprint routing: backlog"
  fi
  exit 0
fi

echo "-> filing JIRA ticket via acli"
if ! acli ${ACLI_ARGS[@]+"${ACLI_ARGS[@]}"}; then
  echo "X acli submit failed; the rendered ticket was:" >&2
  echo "  title: $TITLE" >&2
  echo "  kind:  $KIND" >&2
  if [ -n "$SPRINT" ]; then
    echo "  sprint: $SPRINT (would bind via $SPRINT_FIELD)" >&2
  fi
  echo "---" >&2
  printf '%s\n' "$BODY" >&2
  echo "---" >&2
  exit 6
fi

if [ -n "$SPRINT" ]; then
  echo "  ticket filed in sprint $SPRINT (via $SPRINT_FIELD); JIRA Automation should fire the gh allocator"
  echo "  if no pool/safety pair appears on origin within a few seconds, verify the JIRA"
  echo "  Automation rule that watches in-sprint creates is configured to call"
  echo "  POST /repos/<owner>/<repo>/actions/workflows/allocate-pool-branch.yml/dispatches"
  echo "  with inputs.jira_key, inputs.kind, inputs.short_name (and inputs.sprint)."
else
  echo "  ticket filed in backlog (no allocator dispatch; promote into a sprint when ready)"
fi

exit 0
