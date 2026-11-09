#!/bin/bash
# how-git agent hook adapter for Codex CLI PreToolUse. Codex sends the same hook envelope as
# Claude Code (tool_name, tool_input, cwd) and honours the same deny output
# (hookSpecificOutput.permissionDecision "deny"), but two inputs differ, so this adapter
# reshapes them and hands off to the shared guards next to it:
#   bash   tool_input.command may arrive as an argv array; ["bash","-lc","<script>"] (or sh/zsh,
#          -c) becomes "<script>", any other array is joined with spaces. -> guard-destructive.sh
#   patch  apply_patch carries the patch text in tool_input.command; every "*** Add File:",
#          "*** Update File:", "*** Delete File:" and "*** Move to:" path (relative ones resolved
#          against cwd) is checked by guard-write.sh, the first deny wins. Edit/Write inputs with
#          tool_input.file_path pass straight through.
#   identity  the same argv normalisation, then identity-env.sh --agent codex: a git write in a mapped
#          repo comes back as permissionDecision "allow" with updatedInput.command carrying the
#          exported org identity (Codex rewrites a Bash call only through "allow" + updatedInput).
# A missing guard fails closed (deny with the reinstall command).
# Usage (from hooks.json): codex-adapter.sh bash|patch|identity   < hook JSON on stdin
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# installed: the guards sit next to this adapter; in the framework tree they are in ../shared
[ -x "$here/guard-destructive.sh" ] || here="$(cd "$here/../shared" 2>/dev/null && pwd)"
input=$(cat)
if [ ! -x "$here/guard-destructive.sh" ] || [ ! -x "$here/guard-write.sh" ]; then
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"how-git: the shared guards are missing next to codex-adapter.sh; re-run bin/install-agent-hooks --codex."}}'
  exit 0
fi
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
case "${1:-}" in
  bash|identity)
    norm=$(printf '%s' "$input" | jq -c '.tool_input.command |= (if type == "array" then
        (if length == 3 and (.[0] | test("(^|/)(ba|z)?sh$")) and (.[1] == "-lc" or .[1] == "-c") then .[2] else join(" ") end)
      else . end)' 2>/dev/null)
    if [ "$1" = bash ]; then printf '%s' "$norm" | "$here/guard-destructive.sh"
    elif [ -x "$here/identity-env.sh" ]; then printf '%s' "$norm" | "$here/identity-env.sh" --agent codex; fi ;;
  patch)
    fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if [ -n "$fp" ]; then printf '%s' "$input" | "$here/guard-write.sh"; exit 0; fi
    printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.input // empty | if type == "array" then join("\n") else . end' 2>/dev/null \
      | sed -n -E 's/^\*\*\* (Add File|Update File|Delete File|Move to): +//p' \
      | while IFS= read -r p; do
          [ -z "$p" ] && continue
          case "$p" in /*) ;; *) p="${cwd:-$PWD}/$p" ;; esac
          out=$(jq -nc --arg f "$p" '{tool_name:"Write",tool_input:{file_path:$f}}' | "$here/guard-write.sh")
          if [ -n "$out" ]; then printf '%s\n' "$out"; break; fi
        done ;;
  *) echo "codex-adapter.sh: usage: codex-adapter.sh bash|patch|identity" >&2; exit 0 ;;
esac
exit 0
