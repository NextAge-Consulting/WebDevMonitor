#!/bin/bash
# Dev Server Guard Hook — enforces rule 4 of `.claude/rules/dev-server.md`:
# "Never kill processes you didn't start."
#
# Rules 1–3 + 5 of the dev-server protocol are behavioral (read the rule
# file, follow it). This hook only catches the rule the user hits hardest:
# killing the dev server mid-test destroys their flow.
#
# Prior versions of this hook also blocked `npm run dev` / `npm start`
# starts outright. That was removed because it over-corrected for a
# separate behavioral problem (reckless starts) that the revised rule
# handles via "always check first" + "use an occupied port". Blocking
# every start forced a permission ping-pong on every legitimate E2E run.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Emergency override. Tested against the COMMAND STRING, because that is both how it
# is documented and the only way a caller can reach it: a `SKIP_SERVER_GUARD=1 pkill …`
# prefix sets the variable for the pkill process, never for this hook, which runs in
# Claude's own environment. The env test is the secondary path for a deliberate export.
if [ "${SKIP_SERVER_GUARD:-}" = "1" ] || printf '%s' "$COMMAND" | grep -q "^SKIP_SERVER_GUARD=1"; then
    exit 0
fi

# Only audit Bash-class tool calls.
if [ "$TOOL_NAME" != "Bash" ] && [ "$TOOL_NAME" != "mcp__acp__Bash" ]; then
    exit 0
fi

# Block: kill / pkill / fuser targeting dev servers or the ports they run on. Matches
# the common patterns without being exhaustive — a determined bypass is available via
# SKIP_SERVER_GUARD=1 (which the user gates).
#
# The pattern is SINGLE-quoted deliberately. Double-quoted, the shell collapses `\$`
# to a bare `$`, which grep then reads as an end-of-line ANCHOR — so the
# `kill $(lsof …)` alternative silently matched nothing at all.
KILL_PATTERN='pkill.*vite|pkill.*npm.*dev|pkill.*node.*dev|fuser -k|kill -9.*vite|kill.*\$\(lsof|lsof.*\| *xargs.*kill'

# Drop heredoc BODIES before matching. A heredoc body is data being written to a file,
# never a command being run — so documenting `pkill -f vite` used to trip this guard,
# and the kit's own dev-server rule quotes every command in the pattern. A false block
# here stops ordinary writing dead and teaches the bypass as a habit.
# Any failure in the stripper falls back to the raw command: fail closed.
SCAN_COMMAND=$(python3 -c '
import re, sys
lines = sys.argv[1].split("\n")
out, i = [], 0
while i < len(lines):
    out.append(lines[i])
    m = re.search(r"<<-?\s*[\x27\"]?([A-Za-z_][A-Za-z0-9_]*)[\x27\"]?", lines[i])
    if m:
        delim = m.group(1)
        i += 1
        while i < len(lines) and lines[i].strip() != delim:
            i += 1
    i += 1
print("\n".join(out))
' "$COMMAND" 2>/dev/null) || SCAN_COMMAND="$COMMAND"
[ -n "$SCAN_COMMAND" ] || SCAN_COMMAND="$COMMAND"

if printf '%s' "$SCAN_COMMAND" | grep -qE "$KILL_PATTERN"; then
    # Emit via a JSON encoder, never string interpolation: any command carrying a
    # double quote or backslash produced an unparseable payload, and an unparseable
    # deny is silently DISCARDED — the guard reads as protection while blocking nothing.
    python3 -c '
import json, sys
cmd = sys.argv[1]
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason":
        "🚫 DEV SERVER KILL BLOCKED\n\nCommand: " + cmd + "\n\n"
        "Rule 4 of .claude/rules/dev-server.md — Never kill processes you didn'"'"'t start. "
        "99% of the time a dev server is running, the user is actively testing against it. "
        "Killing it mid-stream destroys their session.\n\n"
        "If you need to restart a server because it'"'"'s misbehaving, surface it to the user "
        "— don'"'"'t cull it.\n\n"
        "Emergency override (user-authorized only): prefix the command with SKIP_SERVER_GUARD=1"}}))
' "$COMMAND"
    exit 0
fi

# Everything else — including `npm run dev` starts — is allowed. Rule 1
# ("always check first") + rule 2 ("if the port is occupied, USE IT")
# + rule 5 ("leave servers running after use") govern start behavior.
exit 0
