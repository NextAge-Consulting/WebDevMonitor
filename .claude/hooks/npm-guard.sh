#!/bin/bash
# npm Install Guard — enforces rule I of `.claude/rules/dependencies.md`.
#
# Blocks a BARE `npm install` / `npm i` (no package named) when a
# package-lock.json already exists. That command is free to REWRITE the
# lockfile, and on a machine with a different npm version it will — silently
# churning the committed lockfile and breaking everyone else's install.
# `npm ci` installs strictly from the lockfile and never rewrites it.
#
# ALLOWED (never blocked):
#   - `npm ci`                       — the disciplined install
#   - `npm install <pkg>` / `-D pkg` — deliberately adding a dependency
#   - bare `npm install` when NO package-lock.json exists — the legitimate
#     first install that CREATES the lockfile (npm ci can't: it needs one)
#
# Detection is pragmatic, not a full shell parser (same stance as the other
# guards): it splits the command on && || ; | and inspects each segment. The
# lockfile is checked in the payload cwd. A chained `cd subdir && npm install`
# is checked against cwd, not subdir — so an odd monorepo bootstrap could slip
# through (errs toward allowing, never toward a false block). Override always
# available.
#
# Emergency override (user-authorized only): prefix with SKIP_NPM_GUARD=1

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# Emergency override. Tested against the COMMAND STRING, because that is both how it
# is documented and the only way a caller can actually reach it: a
# `SKIP_NPM_GUARD=1 npm install` prefix sets the variable for the npm process, never
# for this hook, which runs in Claude's own environment. The env test is kept as a
# secondary path for a caller that exported it deliberately.
if [ "${SKIP_NPM_GUARD:-}" = "1" ] || printf '%s' "$COMMAND" | grep -q "^SKIP_NPM_GUARD=1"; then
    exit 0
fi

# Only audit Bash-class tool calls.
if [ "$TOOL_NAME" != "Bash" ] && [ "$TOOL_NAME" != "mcp__acp__Bash" ]; then
    exit 0
fi

# Fall back to the hook's own cwd if the payload didn't carry one.
[ -n "$CWD" ] || CWD=$(pwd)

# No lockfile in the target dir → nothing to churn. Allow everything (this is
# the bootstrap case where bare `npm install` is the RIGHT command).
if [ ! -f "$CWD/package-lock.json" ]; then
    exit 0
fi

# Echoes "yes" if the segment is a bare `npm install` / `npm i` — the install
# subcommand with no positional package argument.
is_bare_npm_install() {
    local seg="$1"
    local -a words
    read -ra words <<< "$seg"

    local i=0 n=${#words[@]}

    # Skip leading VAR=value environment assignments.
    while [ "$i" -lt "$n" ]; do
        case "${words[$i]}" in
            *=*) i=$((i+1)) ;;
            *) break ;;
        esac
    done

    # Need `npm <subcommand>`.
    [ "$i" -lt "$n" ] || return
    [ "${words[$i]}" = "npm" ] || return
    i=$((i+1))
    [ "$i" -lt "$n" ] || return   # bare `npm` with no subcommand — not install

    case "${words[$i]}" in
        install|i|add) ;;      # install aliases we guard
        *) return ;;           # ci, run, x, test, exec, ... — not our concern
    esac
    i=$((i+1))

    # Any remaining NON-flag token is a package/path/url → deliberate add.
    while [ "$i" -lt "$n" ]; do
        case "${words[$i]}" in
            -*) ;;             # a flag → keep scanning
            '') ;;             # empty → skip
            *) return ;;       # a positional arg → NOT bare, allow
        esac
        i=$((i+1))
    done

    echo yes
}

# Split on command separators so a bare install chained after other commands
# is still inspected on its own.
SEGMENTS=$(printf '%s' "$COMMAND" | sed -e 's/&&/\
/g' -e 's/||/\
/g' -e 's/;/\
/g' -e 's/|/\
/g')

BLOCK=""
while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    if [ "$(is_bare_npm_install "$seg")" = "yes" ]; then
        BLOCK="1"
        break
    fi
done <<< "$SEGMENTS"

if [ -n "$BLOCK" ]; then
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
        "🚫 BARE npm install BLOCKED\n\nCommand: " + cmd + "\n\n"
        "A package-lock.json already exists here, and a bare `npm install` is free to "
        "REWRITE it. On a machine with a different npm version it will — silently churning "
        "the committed lockfile and breaking everyone else'"'"'s install "
        "(rules/dependencies.md §I).\n\n"
        "Use instead:\n"
        "  • `npm ci`                 — routine install, reads the lockfile, never edits it\n"
        "  • `npm install <pkg>`      — ONLY when deliberately adding a dependency\n\n"
        "Emergency override (user-authorized only): prefix with SKIP_NPM_GUARD=1"}}))
' "$COMMAND"
    exit 0
fi

exit 0
