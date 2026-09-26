---
name: postgres-neon-drizzle
description: How we build on PostgreSQL + Neon + Drizzle ORM — migrations and their bookkeeping, nondeterministic (case-insensitive) collations, custom column types, Neon branching for dev and tests, and provisioning a new database. Use when writing or changing a Drizzle schema, generating or applying a migration, adding a text column, writing a query against a converted database, provisioning a tenant database, or setting up DB-backed tests. Does NOT apply to projects on another engine — MSSQL, MySQL and SQLite work differently, and engine-agnostic naming conventions live in the constitution.
user-invocable: false
---

# PostgreSQL + Neon + Drizzle

Read the section you need; the detail lives in `references/`, one file per job.

**Check the engine first**, and check the declared one rather than inferring it
from a config file — a SQL Server project has a `drizzle.config.ts` too:

```bash
jq -r '.DB_ENGINE // ""' .claude/sync-substitutions.json
```

Anything other than `PostgreSQL` → nothing here applies. On `SQLServer` the rule
is `sqlserver-drizzle.md`. On an empty value the engine has not been declared —
ask, rather than assuming Postgres.

## What is deliberately NOT here

- **Naming conventions** — singular tables, `{table}id` primary keys on UUID v7,
  foreign keys matching the parent PK, lowercase fields. House standards that
  hold on any engine, so they live in the constitution (§V). A project on MSSQL
  still follows them; it does not follow this skill.
- **The human gate on applying migrations** — the always-on engine rule
  (`postgres-drizzle.md` here, `sqlserver-drizzle.md` on SQL Server), backed by a
  hook. A skill is consulted by choice; a safety gate cannot be.
- **The three silent failures** — the always-on `postgres-drizzle.md` rule. They
  are there rather than here because you would never think to invoke a skill
  before typing `ilike`.

## The opinions

**The schema files are the source of truth, not the database.** Hand-owned, one
file per table; `db:generate` diffs them into versioned SQL; a human applies it.
There is no ongoing `db:pull` — introspection is a bootstrap step, and it
silently drops everything the schema knows that the database cannot report back
as a type (collation, custom types). Any pull is therefore followed by a fixed
post-processing pass, not treated as a refresh.

**What Drizzle cannot express, a `customType` carries.** Collation, `bytea`,
storage-format conversion — all of it rides in `dataType()` / `toDriver()` /
`fromDriver()`, so `drizzle-kit` emits the right SQL on both `CREATE TABLE` and
`ADD COLUMN`. If you are reaching for a hand-edited migration to add something
the schema could not say, the custom type is the fix instead.

**Dev databases are Neon branches of production.** That is what makes them real
enough to trust. It also means anything created on a dev branch is wiped by the
next reset from parent — so anything expressible as a migration IS a migration,
including a data seed, and reaches every branch by the normal path. Ad-hoc SQL
against dev is erased by the reset and never reaches prod. A fix SQL alone cannot
express is human-gated, the same as `db:migrate`.

**DB-backed tests fork their own branch.** An ephemeral branch per run, deleted in
teardown, so tests see real data and production is never written.

**A migration whose DDL is already true is emptied, not run.** When the schema
catches up to a database that already matches — adopting a custom type, recording
a rename that only ever existed in the schema — `generate` still emits the diff.
Empty the generated `.sql` body and keep the bookkeeping.

## References

| File | Read it when |
|---|---|
| `collation.md` | Adding a text column, writing a search, or a query errors on a collation |
| `migrations.md` | Generating, editing or applying a migration; the diff is not what you expected |
| `custom-types.md` | Drizzle cannot express what the column needs; after any `pull` |
| `neon.md` | Branching dev from prod, resetting, ephemeral test branches, provisioning a new database |
