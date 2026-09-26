# Migrations

A migration is **three coupled files** that must stay in sync:

- the `.sql` body
- its `meta/NNNN_snapshot.json` — the schema as of that migration
- an entry in `meta/_journal.json` — the ordering

Only `drizzle-kit generate` writes all three atomically. Hand-creating a `.sql`,
or editing the journal or a snapshot, desyncs the chain: the next `db:generate`
diffs against a missing or mismatched snapshot, which is painful to unravel.

## The workflow

| Step | Command / action |
|---|---|
| Schema-derived migration | `db:generate` — drizzle diffs the schema and writes all three files |
| Data-only / custom SQL | `db:generate --custom` — scaffolds an empty `.sql` plus its bookkeeping |
| Write the SQL | Edit ONLY the generated `.sql` body |
| Apply | `db:migrate` — **never** `db:push` |

Applying is human-gated (`postgres-drizzle.md`, `block-db-commands.sh`): an
approved `db:migrate` run is prefixed `SKIP_DB_GUARD=1`, and autonomous sessions
run under their standing authorization. `db:generate` is not gated — it writes
files and opens no connection, so run it freely.

## Forbidden

| Never | Why |
|---|---|
| Create a `.sql` in a migrations dir by hand | Bypasses snapshot + journal; desyncs the chain |
| Edit `meta/_journal.json` | Drizzle bookkeeping — corrupts ordering |
| Edit `meta/*_snapshot.json` | Drizzle bookkeeping — the next `generate` diffs wrong |
| `db:push` | Skips the migration files entirely; no audit trail |

`block-drizzle-handroll.sh` blocks the first three at the tool layer. Hitting it
means you are hand-rolling — run `db:generate --custom` and edit what it makes.

## When the DDL is already true: empty the body

Sometimes the schema catches up to a database that already matches — adopting a
collation-carrying custom type, or recording a name that was only ever wrong in
the schema. `generate` still emits the full diff, and running it would rewrite
tables for no gain.

1. Run `generate` and **read the emitted SQL**. Confirm it contains only the
   statements you expect and nothing destructive — no `DROP`, no unexpected
   `CREATE`, no data-type change you did not intend.
2. Replace the `.sql` body with a comment saying why it is empty and what the
   database already has.
3. Re-run `generate`. It must report **no schema changes** — that is the proof
   the snapshot now describes the database.

Editing a generated `.sql` is allowed and is the correct move here. The
bookkeeping stays untouched, so the chain remains valid and `db:migrate` simply
records the row.

## `generate` compares against the snapshot, not the database

This is the trap behind most "why didn't it notice?" moments. `drizzle-kit
generate` never connects to the database — it diffs the schema files against the
last snapshot. So a database that has drifted from the snapshot is **invisible**:
generate will happily report no changes while the schema and the real database
disagree.

Anything that could have drifted (a column added out-of-band, a name that
introspection mangled at bootstrap) has to be checked against the database
directly with a catalog query. See the audit query in `collation.md`.

## Renames need an interactive answer

When a column name changes, `generate` cannot tell a rename from a drop plus an
add, so it prompts. In a non-TTY context it fails with `Interactive prompts
require a TTY terminal`.

Answer **rename** when it is one — a drop-and-create loses the column's data and
records the wrong intent in the snapshot. If the session has no TTY, run it from
a terminal that does rather than working around the prompt.
