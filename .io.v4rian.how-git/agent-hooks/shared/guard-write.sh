#!/bin/bash
# how-git agent hook: PreToolUse(Write|Edit|NotebookEdit) guard for Claude Code (Codex reaches it
# through codex/codex-adapter.sh, one call per patched path). Deterministic. Denies any write under
# a vendored .io.v4rian.how-git/ copy: consumers change the canonical framework repo and pull the
# change with bin/sync-framework, never edit the copy in place. Exception: the framework source
# repo itself, recognised by the FRAMEWORK_REPO marker at <root>/.io.v4rian.how-git/FRAMEWORK_REPO
# (the same marker the framework's own test gates read), whatever its remote is.
set -u
input=$(cat)
fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
[ -z "$fp" ] && exit 0
deny() { jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
framework_source() { [ -f "${fp%%/.io.v4rian.how-git/*}/.io.v4rian.how-git/FRAMEWORK_REPO" ]; }
case "$fp" in
  */.io.v4rian.how-git/*)
    framework_source && exit 0
    deny "Write blocked (how-git protocol): vendored .io.v4rian.how-git copies are never edited; change the canonical framework repo and run .io.v4rian.how-git/bin/sync-framework <ref> here. Path: $fp" ;;
esac
exit 0
