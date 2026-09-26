# Custom Column Types

Drizzle's `customType` is the escape hatch for anything the standard column
builders cannot say. It is the correct answer whenever you would otherwise
hand-edit generated SQL.

`dataType()` returns the raw SQL for the column type, so anything valid in a
`CREATE TABLE` can ride along — including clauses Drizzle has no concept of.
`toDriver()` / `fromDriver()` convert values on the way out and in.

```ts
import { customType } from 'drizzle-orm/pg-core';
```

## Collation — `ciVarchar` / `ciText`

Drizzle has no collation option on any `pg-core` builder, so the clause goes in
the type string:

```ts
/** varchar with the case-insensitive collation. */
export const ciVarchar = customType<{ data: string; config: { length: number } }>({
  dataType(config) {
    return `varchar(${config!.length}) COLLATE case_insensitive`;
  },
});

/** text with the case-insensitive collation. */
export const ciText = customType<{ data: string }>({
  dataType() {
    return 'text COLLATE case_insensitive';
  },
});
```

`drizzle-kit` emits the collation on both `CREATE TABLE` and `ADD COLUMN`, and
re-running `generate` reports no changes — the collation becomes part of the type
string in the snapshot and stays stable. Semantics and when NOT to use it:
`collation.md`.

## Binary — `bytea`

Introspection emits `bytea` columns as a `customType` reference that must be
wired to a real helper:

```ts
export const bytea = customType<{ data: Buffer; notNull: false; default: false }>({
  dataType() { return 'bytea'; },
  toDriver(value: Buffer): Buffer { return value; },
  fromDriver(value: unknown): Buffer { return value as Buffer; },
});
```

## Storage-format conversion

When a column's stored representation differs from what application code should
handle — a datetime stored as naive wall-clock in a fixed zone, an enum stored as
a legacy code — the conversion belongs in `toDriver`/`fromDriver`, not at every
call site. Callers then work in the natural type and cannot get it wrong
individually.

The tell that you need one: the same conversion appearing at more than one call
site, or a comment explaining what the raw column "really" means.

## After `drizzle-kit pull`, restore what it dropped

**Introspection does not emit collation, and it emits custom types as bare
references.** A re-pull therefore replaces every `ciVarchar` with plain `varchar`
and every helper-backed column with a stub — the schema silently stops describing
the database.

So a pull is a bootstrap step, never a refresh. After every one, before
committing:

1. Query the database for which columns actually carry the collation (query in
   `collation.md`).
2. Rewrite those columns to `ciVarchar` / `ciText`, driven off the query.
3. Re-wire `bytea` and any other custom types to their helpers.
4. Confirm `drizzle-kit generate` reports **no schema changes**. If it wants to
   alter columns, the schema and database disagree — resolve that before
   committing rather than letting the migration run.

Introspection gets you 95% of the way; the last 5% is this fixed, documented
pass. Skipping it is how a schema quietly starts lying.

## Watch the emitted identifier

A `customType` does not change how Drizzle quotes column names, and Drizzle
quotes them exactly as declared. A key or explicit name whose case differs from
the real column — `mobilefor2Fa` against a database column `mobilefor2fa` —
produces SQL that fails at runtime with "column does not exist", and `generate`
will not catch it because it never looks at the database. When bootstrapping from
introspection, verify the emitted names against the catalog.
