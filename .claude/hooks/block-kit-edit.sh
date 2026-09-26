#!/bin/bash
#
# block-kit-edit.sh — PreToolUse guard (Edit, Write).
#
# Stops a CONSUMER machine's AI from modifying kit-OWNED files. The set is read
# from the committed `.claude/.kit-sync.json` manifest — present on every
# consumer, no kit repo needed — and it is the `mode` on each entry that
# decides, never the presence of the key: `owned` is guarded, `template` is the
# project's own file and passes through. See the mode table below.
#
# The kit MAINTAINER is exempt: if `~/.claude/kitmaster` exists the hook is
# inert. That marker exists only on the maintainer's machine (one-time
# `touch ~/.claude/kitmaster`), so consumers get teeth and the maintainer edits
# freely.
#
# Deny contract: emit hookSpecificOutput.permissionDecision=deny on stdout,
# exit 0. Allow: exit 0 with no output. (Models block-drizzle-handroll.sh.)

INPUT=$(cat)

# Maintainer machine → inert.
[ -f "$HOME/.claude/kitmaster" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name')
# MultiEdit carries a file_path exactly like Edit/Write; omitting it here let a
# multi-edit rewrite a kit-owned file straight past this guard.
case "$TOOL_NAME" in
    Edit|Write|MultiEdit) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE_PATH" ] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
MANIFEST="$PROJECT_DIR/.claude/.kit-sync.json"
[ -f "$MANIFEST" ] || exit 0     # not a kit-managed project → nothing to guard

# Normalize the target to a project-root-relative path (manifest keys are relative).
case "$FILE_PATH" in
    "$PROJECT_DIR"/*) REL="${FILE_PATH#"$PROJECT_DIR"/}" ;;
    /*)               exit 0 ;;   # absolute path outside the project → not kit
    *)                REL="$FILE_PATH" ;;
esac

# Is this path kit-managed, and if so under which mode?
#
#   (absent)  → not kit-managed. Allow.
#   owned     → the kit owns the content. Deny.
#   template  → the kit ships a starting point; the project owns the file. Allow.
#
# Tolerates both lockfile schemas: a legacy bare-string value means `owned`.
MODE=$(jq -r --arg p "$REL" '
    .files[$p] // empty
    | if type == "object" then (.mode // "owned") else "owned" end
' "$MANIFEST" 2>/dev/null)

if [ -n "$MODE" ] && [ "$MODE" != "template" ]; then
    REASON="$REL is synced and owned by the dev kit. Consumer projects must not edit kit-managed files. If it needs to change, describe the change to the kit maintainer — do not edit it here."
    jq -cn --arg r "$REASON" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
fi

exit 0
