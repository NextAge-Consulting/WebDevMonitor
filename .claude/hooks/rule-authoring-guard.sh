#!/bin/bash
# Rule Authoring Guard — routes rule/skill authoring through the `rule-authoring` skill.
#
# Skills are model-invoked: unlike rules, they have no path targeting, so a skill fires
# only if the model decides to reach for it. `rule-authoring` names the exact globs it
# covers in its own description and STILL gets skipped, because nothing in the mechanism
# connects "writing to .claude/skills/**" to "load that skill first". This hook is that
# connection.
#
# Fires on a Write/Edit to an authored-prose surface:
#   .claude/rules/**.md          (including rules/project/**)
#   .claude/skills/**.md
#   .claude/output-styles/**.md
#   CLAUDE.md
#   the kit's own _claude-project/{rules,skills}/**.md source surfaces
#
# ONCE PER SESSION, then allows everything after. The hook cannot see whether the skill
# is loaded, so a permanent deny would block every rule edit forever — and a guard that
# false-blocks gets routed around within a day (`hook-testing.md`). One nudge, capped.
#
# Markdown only. A shell script under .claude/skills/<name>/scripts/ is code, not prose
# that binds, and rule-authoring has nothing to say about it.
#
# Override (user-authorized only): export SKIP_RULE_AUTHORING=1. There is no command
# string to prefix — Write/Edit carry a file_path, not a command.

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')

if [ "${SKIP_RULE_AUTHORING:-}" = "1" ]; then
    exit 0
fi

case "$TOOL_NAME" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
esac

[ -n "$FILE_PATH" ] || exit 0

# Prose surfaces only.
case "$FILE_PATH" in
    *.md) ;;
    *) exit 0 ;;
esac

MATCH=""
case "$FILE_PATH" in
    */.claude/rules/*|*/.claude/skills/*|*/.claude/output-styles/*) MATCH=1 ;;
    .claude/rules/*|.claude/skills/*|.claude/output-styles/*)       MATCH=1 ;;
    */_claude-project/rules/*|*/_claude-project/skills/*)           MATCH=1 ;;
    _claude-project/rules/*|_claude-project/skills/*)               MATCH=1 ;;
esac
case "${FILE_PATH##*/}" in
    CLAUDE.md) MATCH=1 ;;
esac

[ -n "$MATCH" ] || exit 0

# One nudge per session. Fall back to a cwd-keyed marker when the payload carried no
# session id, so the cap still holds rather than degrading to a permanent block.
KEY="$SESSION_ID"
if [ -z "$KEY" ]; then
    KEY=$(printf '%s' "$CWD" | shasum -a 256 2>/dev/null | awk '{print $1}')
    [ -n "$KEY" ] || KEY="nosession"
fi
MARKER="${TMPDIR:-/tmp}/.claude-rule-authoring-${KEY}"

if [ -f "$MARKER" ]; then
    exit 0
fi
: > "$MARKER" 2>/dev/null || exit 0

python3 -c '
import json, sys
path = sys.argv[1]
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason":
        "📐 Load the `rule-authoring` skill before writing this.\n\n"
        "Target: " + path + "\n\n"
        "This is an authored-prose surface — a rule, skill, output style or CLAUDE.md. "
        "The rule-authoring skill carries how these are written so they bind: instruction "
        "not explanation, reasoning in the commit message rather than the file, no counted "
        "lists, and every named file/flag/skill verified to exist.\n\n"
        "Invoke it, then repeat this edit — you will not be asked again this session.\n\n"
        "Override (user-authorized only): export SKIP_RULE_AUTHORING=1"}}))
' "$FILE_PATH"

exit 0
