# Postgres + Drizzle: The Three Silent Failures

**Gate — read this first.** This file applies only when the project declares
PostgreSQL:

```bash
jq -r '.DB_ENGINE // ""' .claude/sync-substitutions.json
```

`PostgreSQL` → this rule applies. `SQLServer` → read `sqlserver-drizzle.md`
instead; nothing here transfers. `Other` or `None` → none of this applies, stop
here. Empty → **the engine has not been declared, which is not the same as not
having one.** Ask before applying any engine-specific guidance, and get the key
populated.

The gate is the declared engine, never the presence of a `drizzle.config.ts`. A
config file proves Drizzle is in use; it says nothing about the dialect, and a
SQL Server project has one too — so gating on the file makes this rule fire on a
project where `ILIKE`, `ciVarchar` and Neon branches are all wrong answers.

Everything else about this stack — how to define the types, run the migration,
branch the database, provision a new one — is the **postgres-neon-drizzle**
skill. This file is only the failures you would not think to look up, because
nothing catches them until production.

**1. On a nondeterministic (case-insensitive) collation, `ILIKE` and regex
throw.** `nondeterministic collations are not supported for ILIKE` / `for regular
expressions` — so no `~`, `~*`, `regexp_*` either. `=` and `LIKE` are already
case-insensitive on those columns; use them, and never wrap in `LOWER()`. When
you genuinely need a regex, `COLLATE "C"` on the expression makes it
deterministic — and case-sensitive, so handle case in the pattern.

**2. A new text column does not inherit its neighbours' collation.** It takes the
database default, so it lands case-SENSITIVE in a table where everything else is
not. Queries succeed and compare differently. Declare it with the project's
collation-carrying custom type (`ciVarchar` / `ciText`) — never a hand-written
`ALTER` in a migration.

**3. Never hand-author migration bookkeeping.** A migration is three coupled
files — the `.sql`, its `meta/NNNN_snapshot.json`, and the `meta/_journal.json`
entry. Only `drizzle-kit generate` writes all three together; hand-creating a
`.sql` or editing the journal or a snapshot desyncs the chain. Editing the body
of a `.sql` that `generate` produced is fine and often correct.

**Applying a migration needs the human's explicit approval.** `db:migrate` and
`drizzle-kit migrate` change a database, so they run only with the human's
explicit approval in the current conversation; an approved run is prefixed
`SKIP_DB_GUARD=1`. Never `db:push` at all. An autonomous session follows whatever
authorization the human gave it at handoff (`autonomous-sessions.md`); with none,
the approval rule still stands.

`db:generate` is not gated and needs no approval. It diffs the schema against the
stored snapshots and writes files into the repo, opening no connection to any
database — and failure 3 above makes it the only correct way to author a
migration. The generated migration is inert until someone applies it, which is
where the gate belongs.

**Which branch am I on? Ask, don't guess.** `node scripts/db-branch.mjs` reads
`DATABASE_URL`, resolves its endpoint through the Neon API, and prints the branch
name. `DEV` (exit 0) means a resettable fork — reads and tests against it are
normal work, so proceed without asking, and a migration there is the routine case
of the approval above rather than an alarm. `PRODUCTION` (exit 1) means the
project's default or protected branch — stop, and say so when you ask.
`UNKNOWN` (exit 2) means it could not tell, which is never the same as safe.

Your local `.env` normally points at a dev branch. Run the check rather than
inferring in either direction: stalling on a dev branch wastes the session, and
assuming a dev branch on prod is worse.

Naming conventions (singular tables, `{table}id`) are engine-agnostic and live
in the constitution, not here. The id itself is UUID v7 in the native `uuid`
column type — free on Postgres, no engine-specific cost, always the default.
