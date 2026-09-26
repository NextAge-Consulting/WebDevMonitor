#!/bin/bash

# Drizzle/migration guard — default-DENY with an explicit-approval bypass.
# The rule this enforces (the project's engine rule — postgres-drizzle.md or
# sqlserver-drizzle.md): commands that CHANGE a database
# are never run on Claude's own judgment. When the human has explicitly approved
# a run in the current conversation, Claude prefixes the command with
# SKIP_DB_GUARD=1 and it passes. Same trust model as git-guard's SKIP_GIT_GUARD=1.
#
# db:generate is deliberately NOT guarded. It diffs the schema against
# meta/*_snapshot.json and writes files into the repo; it opens no connection and
# changes no database, and block-drizzle-handroll.sh names it as the ONLY correct
# way to author a migration. Guarding the sanctioned path taught SKIP_DB_GUARD as
# routine muscle memory, which is exactly what must stay exceptional.

# Read input from Claude Code
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Check if this is a Bash command with database operations
if [ "$TOOL_NAME" = "Bash" ] || [ "$TOOL_NAME" = "mcp__acp__Bash" ]; then
    # Scan the command WITHOUT heredoc bodies. A heredoc body is data being written
    # to a file, never a command being run — so a doc or test fixture that mentions
    # `drizzle-kit` used to trip this guard. A false block is the costly failure
    # here (see the test suite header), and the bypass it teaches is habit-forming.
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

    # A migration command must be INVOKED, not merely named. Grepping the whole
    # command string blocked its own documentation: `grep -rn db:migrate .` and
    # `echo "run npm run db:migrate" > doc.md` are text handling, not migrations.
    # So a segment counts only when its FIRST token is a package runner or
    # drizzle-kit itself — the same invoked-vs-mentioned test the psql branch below
    # already uses. db:generate and `drizzle-kit generate` are absent by design.
    if python3 -c '
import re, sys
cmd = sys.argv[1]
Q = chr(34) + chr(39)
RUNNERS = ("npm", "pnpm", "yarn", "bun", "npx", "pnpx", "bunx")
for seg in re.split(r"\|\||&&|[|;\n]", cmd):
    toks = seg.strip().split()
    while toks and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0]):
        toks.pop(0)                      # step over VAR=value prefixes
    if not toks:
        continue
    base = re.sub(r".*/", "", toks[0].strip(Q))
    if base not in RUNNERS and base != "drizzle-kit":
        continue
    rest = [t.strip(Q) for t in toks[1:]]
    if "db:migrate" in rest or "db:push" in rest:
        sys.exit(0)                      # a real migration run
    if base == "drizzle-kit":
        sub = rest
    elif "drizzle-kit" in rest:
        sub = rest[rest.index("drizzle-kit") + 1:]
    else:
        sub = []
    for t in sub:
        if t in ("migrate", "push"):
            sys.exit(0)
sys.exit(1)
' "$SCAN_COMMAND" 2>/dev/null; then
        # Explicit-approval bypass: the human authorized this run.
        if echo "$COMMAND" | grep -q "^SKIP_DB_GUARD=1"; then
            exit 0
        fi
        # Emit via a JSON encoder, never string interpolation: a command carrying a
        # double quote (`drizzle-kit migrate --config="drizzle.config.ts"`) produced
        # an unparseable payload, and an unparseable deny is silently DISCARDED,
        # letting the very command this guards run unguarded.
        python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason":
        "🚫 DATABASE COMMAND BLOCKED\n\nYou attempted to run: " + sys.argv[1] + "\n\n"
        "This command CHANGES a database. Per postgres-drizzle.md it runs ONLY with "
        "the human'"'"'s explicit approval in the current conversation.\n\n"
        "If the human has ALREADY approved this specific run: re-run it prefixed with "
        "SKIP_DB_GUARD=1.\n"
        "If not: run db:generate (never blocked — it only writes files) and ask for "
        "approval to apply it.\nNever use db:push."}}))
' "$COMMAND"
        exit 0
    fi

    # Ad-hoc WRITE SQL through a client. Reads stay free — `psql -c "SELECT …"` is
    # the documented way to inspect a database and must never be blocked. What is
    # gated is writing by hand, because a hand-run statement lands on one branch
    # only: the next reset from parent erases it, prod never receives it, and the
    # gap surfaces at deploy. Anything expressible as a migration IS a migration.
    # Word boundaries matter — `SELECT updatedat` must not read as UPDATE.
    # Only a segment that actually INVOKES psql counts. Merely naming it — in prose,
    # a grep pattern, a test fixture — is data, exactly like a heredoc body.
    if python3 -c '
import re, sys
cmd = sys.argv[1]
WRITE = re.compile(r"(?<![A-Za-z0-9_])(INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER|GRANT|REVOKE|CREATE)(?![A-Za-z0-9_])", re.I)
FILE  = re.compile(r"(?:^|\s)-f(?:\s|=)")
for seg in re.split(r"\|\||&&|[|;\n]", cmd):
    toks = seg.strip().split()
    while toks and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0]):
        toks.pop(0)                      # step over VAR=value prefixes
    if not toks:
        continue
    if re.sub(r".*/", "", toks[0]) not in ("psql", "pgcli"):
        continue
    rest = " ".join(toks[1:])
    if WRITE.search(rest) or FILE.search(" " + rest):
        sys.exit(0)                      # a real hand-run write
sys.exit(1)
' "$SCAN_COMMAND" 2>/dev/null; then
        if echo "$COMMAND" | grep -q "^SKIP_DB_GUARD=1"; then
            exit 0
        fi
        python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason":
        "🚫 HAND-RUN SQL BLOCKED\n\nYou attempted to run: " + sys.argv[1] + "\n\n"
        "Writing by hand lands on ONE branch. The next reset from parent erases it, "
        "production never receives it, and the gap surfaces at deploy.\n\n"
        "Anything expressible as a migration IS a migration — including a data seed. "
        "Run db:generate and edit the body of the generated .sql.\n\n"
        "If this genuinely cannot be a migration (it needs scripting, parsing, or "
        "per-row judgement): say what you intend to run, get the human'"'"'s approval in "
        "this conversation, then re-run prefixed with SKIP_DB_GUARD=1.\n\n"
        "Reads are never blocked — psql -c \"SELECT …\" needs no approval."}}))
' "$COMMAND"
        exit 0
    fi
fi

# Allow all other commands
exit 0
