#!/bin/bash

# Block hand-authoring of Drizzle migration bookkeeping.
#
# Drizzle's migration state is three coupled files per migration: the `.sql`,
# its `meta/NNNN_snapshot.json`, and an entry in `meta/_journal.json`. Only
# `drizzle-kit generate` (use `--custom` for data-only migrations) writes all
# three atomically. Hand-editing the journal or a snapshot, or hand-creating a
# `.sql`, desyncs the snapshot chain — the next `db:generate` diffs against a
# missing/mismatched snapshot, which is painful to unravel.
#
# What this blocks (Write or Edit):
#   - */migrations/meta/_journal.json      — drizzle bookkeeping, never hand-touch
#   - */migrations/meta/*_snapshot.json    — drizzle bookkeeping, never hand-touch
#   - Write (create/overwrite) of */migrations/*.sql IN a drizzle dir
#     (one whose meta/_journal.json exists) — scaffold via db:generate instead
#
# What this ALLOWS:
#   - Edit of an existing */migrations/*.sql — pasting the SQL body into the
#     file drizzle already generated is the correct workflow.
#   - drizzle-kit itself: it writes via its CLI (a Bash subprocess), which this
#     Write/Edit hook never sees.
#
# There is intentionally no bypass token: the legitimate path (db:generate, then
# Edit the generated .sql body) is always open, so a bypass is never needed.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Only the file-writing tools carry a file_path we guard. MultiEdit carries one too,
# and omitting it here let a multi-edit walk straight past this guard.
case "$TOOL_NAME" in
    Edit|Write|MultiEdit) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE_PATH" ] && exit 0

deny() {
    cat <<BLOCK
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "$1"
  }
}
BLOCK
    exit 0
}

GUIDANCE="Never hand-author Drizzle migration files. Run \`npm run db:generate\` (add \`--custom --name=<name>\` for a data-only migration) to scaffold the .sql + snapshot + journal entry together, then Edit ONLY the generated .sql body. See constitution §XI (canonical path, not the quick hack)."

# --- Drizzle bookkeeping: _journal.json and snapshots — blocked on Write OR Edit ---
if echo "$FILE_PATH" | grep -qE '/migrations/meta/_journal\.json$'; then
    deny "🚫 DRIZZLE JOURNAL BLOCKED\n\n$FILE_PATH is Drizzle's migration journal — hand-editing it desyncs the snapshot chain.\n\n$GUIDANCE"
fi

if echo "$FILE_PATH" | grep -qE '/migrations/meta/.*_snapshot\.json$'; then
    deny "🚫 DRIZZLE SNAPSHOT BLOCKED\n\n$FILE_PATH is a Drizzle schema snapshot — it is generated, never hand-written.\n\n$GUIDANCE"
fi

# --- New .sql created by hand in a drizzle dir — blocked on Write only ---
# (Edit of an existing generated .sql is the correct way to add the SQL body.)
if [ "$TOOL_NAME" = "Write" ] && echo "$FILE_PATH" | grep -qE '/migrations/[^/]+\.sql$'; then
    MIG_DIR=$(dirname "$FILE_PATH")
    # Only treat it as Drizzle if the journal sibling exists — avoids false
    # positives on unrelated tools that keep hand-written .sql migrations.
    if [ -f "$MIG_DIR/meta/_journal.json" ]; then
        deny "🚫 DRIZZLE MIGRATION BLOCKED\n\n$FILE_PATH would be a hand-created Drizzle migration (its dir has meta/_journal.json). Creating the .sql without the matching snapshot + journal entry breaks db:generate.\n\n$GUIDANCE"
    fi
fi

exit 0
