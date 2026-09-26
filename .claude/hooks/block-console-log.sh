#!/bin/bash

# Block console.log in projects using Pino logger
# Only activates if package.json contains "pino" dependency

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Only check the file-writing tools
case "$TOOL_NAME" in
    Edit|Write|MultiEdit) ;;
    *) exit 0 ;;
esac

# Check if project uses Pino (skip if not)
if [ ! -f "package.json" ]; then
    exit 0
fi

if ! grep -q '"pino"' package.json 2>/dev/null; then
    # Also check for monorepo shared package
    if [ -f "packages/shared/package.json" ]; then
        if ! grep -q '"pino"' packages/shared/package.json 2>/dev/null; then
            exit 0
        fi
    else
        exit 0
    fi
fi

# Get the content being written
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
# MultiEdit carries neither new_string nor content — its payload is edits[].new_string.
# Without that branch this guard is INVOKED on a MultiEdit and matches nothing, which is
# an allow that looks exactly like a pass.
NEW_CONTENT=$(echo "$INPUT" | jq -r '
    .tool_input.new_string
    // .tool_input.content
    // ([.tool_input.edits[]?.new_string] | join("\n"))
    // ""')

# Only check TypeScript/JavaScript files
if ! echo "$FILE_PATH" | grep -qE '\.(ts|tsx|js|jsx)$'; then
    exit 0
fi

# Check for console.log patterns
if echo "$NEW_CONTENT" | grep -qE 'console\.(log|error|warn|info|debug)'; then
    # Emit via a JSON encoder, never string interpolation. The echoed-back snippet is
    # ATTACKER-SHAPED by construction: it is the user's own source, so it routinely
    # carries quotes, backslashes and backticks. A `sed 's/"/\\"/g'` pass escapes
    # quotes but not backslashes, so `console.log("she said \"hi\"")` produced an
    # unparseable payload — and an unparseable deny is silently DISCARDED, letting the
    # console.log straight through.
    #
    # The content arrives on STDIN, never as an argv. A Write carries the WHOLE FILE, and
    # an argv is bounded by ARG_MAX — so a large enough file made python3 die with E2BIG,
    # which prints nothing and falls through to the `exit 0` below. That is an ALLOW: the
    # guard failed open on exactly the large files most likely to be carrying a stray
    # console.log. stdin has no such bound.
    printf '%s' "$NEW_CONTENT" | python3 -c '
import json, re, sys
content = sys.stdin.read()
snippet = "\n".join(
    [l for l in content.splitlines()
       if re.search(r"console\.(log|error|warn|info|debug)", l)][:3])
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason":
        "🚫 CONSOLE.LOG BLOCKED\n\nThis project uses Pino for structured logging.\n\n"
        "You wrote:\n" + snippet + "\n\n"
        "Use Pino instead:\n"
        "  import { logger } from \"~/lib/logger\";\n"
        "  logger.info(\"message\");\n"
        "  logger.error({ err }, \"error message\");\n\n"
        "CLIENT-SIDE CODE IS NOT AN EXCEPTION. Pino has a browser build; the logger\n"
        "should detect its environment and drop the transport in the browser. If it\n"
        "does not, fix the logger — do NOT bypass this hook and do NOT leave the\n"
        "catch empty (constitution §X).\n\n"
        "See: .claude/rules/typescript-rules.md §II (Logging)"}}))
'
    exit 0
fi

exit 0
