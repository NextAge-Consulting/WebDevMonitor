# SQL Server + Drizzle

**Gate — read this first.** This file applies only when the project declares SQL
Server:

```bash
jq -r '.DB_ENGINE // ""' .claude/sync-substitutions.json
```

`SQLServer` → this rule applies. `PostgreSQL` → read `postgres-drizzle.md`
instead. `Other` or `None` → stop here. Empty → the engine has not been
declared, which is not the same as not having one; ask, and get the key
populated.

**Nothing in `postgres-drizzle.md` or the `postgres-neon-drizzle` skill transfers.**
No `ILIKE`, no nondeterministic collations, no `ciVarchar`/`ciText`, no Neon
branching. Engine-agnostic naming (singular tables, `{table}id`, UUID v7) still
comes from the constitution §V.

## I. The dialect is on the 1.0 release-candidate channel — pin it exactly

Drizzle's MSSQL dialect does **not** exist on the stable line. It ships only on
the 1.0 pre-release channel:

```bash
npm i drizzle-orm@<exact 1.0 rc version> mssql
npm i -D drizzle-kit@<same exact version>
```

- **Import from `drizzle-orm/node-mssql`**; table builders from
  `drizzle-orm/mssql-core`. The driver is `mssql`.
- **Pin the exact version. Never the `@rc` tag** — the tag moves, and a pre-release
  moving under a project is how a green build becomes a broken one with no commit
  to blame.
- Adopting this puts the project on a different Drizzle major from every project
  on the stable line. That is a real cost, and it is unavoidable: there is no
  "Drizzle, but stable" option for this engine.

Treat every RC upgrade as a change that needs the §III register re-verified.

## II. The connection string has exactly one working form

The `mssql` driver rejects both URL schemes. Only the ADO-style keyword string
connects:

```
mssql://user:pass@host:1433/db          ✗  "config.server property is required"
sqlserver://host:1433;database=…        ✗  "config.server property is required"
Server=host,1433;Database=…;User Id=…   ✓
```

So `dbCredentials.url` takes keyword form, assembled from discrete env values:

```ts
const url = `Server=${process.env.DB_SERVER},${process.env.DB_PORT ?? 1433};`
  + `Database=${process.env.DB_DATABASE};User Id=${process.env.DB_USER};`
  + `Password=${process.env.DB_PASSWORD};Encrypt=true;TrustServerCertificate=true`;
```

A project here typically carries discrete `DB_*` keys rather than the single
`DATABASE_URL` the Postgres projects use. Kit tooling that assumes one URL needs
checking against that.

## III. The RC defect register — re-verify every one on every upgrade

These are current-as-of-adoption defects in Drizzle's MSSQL support, each with a
standing workaround. **A Drizzle upgrade is not complete until each row here has
been re-tested and the row updated or deleted.** A workaround left in place after
upstream fixes it is a permanent, invisible tax; a workaround silently dropped
because someone assumed a fix is a regression.

Record the register in the project's own documentation with the version it was
last verified against.

| Defect | Symptom | Standing workaround |
|---|---|---|
| **`pull --init` WRITES to the database** | Creates a `__drizzle_migrations` table in a `drizzle` schema on the target | Use plain `drizzle-kit pull`. It is read-only and produces the same schema file. **Never `--init`, never against production.** |
| **Duplicate index names across tables break introspection** | `Failed to map the introspected schema` — no detail, no object named, even with stderr isolated | SQL Server scopes index names per table, so the same name on two tables is legal; introspection flattens them and collides. Find duplicates with the query below, then exclude one table via `tablesFilter` and hand-write its schema. |
| **Check constraints emit a missing comma** | Generated `schema.ts` does not parse where a `check()` follows a `unique()` | One post-processing pass after every pull (below) |
| **No relational query API** | `db.query` is `undefined` — no `findMany({ with: … })` | Explicit `select().from().leftJoin()`. Transactions do work. |
| **No `.limit()` on the select chain** | `db.select(…).limit is not a function` on 1.0.0-rc.5 | **Page with `.orderBy(…).offset(n).fetch(m)`**, which is SQL Server's own `OFFSET n ROWS FETCH NEXT m ROWS ONLY` and is what this dialect exposes instead. Verified against a live SQL Server 2019 on 1.0.0-rc.5: two adjacent pages returned the requested row counts and no overlapping rows. **Both `.orderBy()` and `.offset()` are mandatory, `.offset(0)` included.** `.fetch()` alone emits a `FETCH NEXT` with no `OFFSET` clause, which the server rejects with *"Invalid usage of the option next in the FETCH statement"* — so taking a single row is `.orderBy(…).offset(0).fetch(1)`, never `.fetch(1)`. A `where` on a unique or primary-key column needs none of it: it matches at most one row by construction |
| **No `uniqueidentifier` column builder** | Not in `drizzle-orm/mssql-core`'s exports on 1.0.0-rc.5 — every other SQL Server scalar type is there, this one isn't | `customType<{ data: string }>({ dataType: () => 'uniqueidentifier' })`. Drop the custom type the day this ships natively. |

Find duplicate index names before the first introspection — it is the difference
between a five-minute fix and an afternoon:

```sql
SELECT i.name, COUNT(*) n
FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id
WHERE i.name IS NOT NULL
GROUP BY i.name HAVING COUNT(*) > 1;
```

The check-constraint fix, run after every `pull`:

```bash
perl -0pi -e 's/([^,\s])\n(check\()/$1,\n\t$2/g' schema.ts
```

Typecheck the generated file under `--strict` as part of the pull step. It is the
only thing that catches a new codegen defect on an upgrade.

## IV. Trailing-space padding is invisible to SQL (Zero Tolerance)

A `char` column, and a `varchar` written by a fixed-width client, stores values
padded to the column width. **SQL Server's `=` and `<>` ignore trailing spaces**,
so the obvious detection query cannot see it:

```sql
WHERE col <> RTRIM(col)          -- always zero rows, even on a fully padded column
WHERE DATALENGTH(col) > LEN(col) -- the only reliable test
```

Values reach the application padded, and it is the data, not the driver. Decide
once where trimming happens — a shared read helper or a custom column type — and
never at individual call sites, because the call site that forgets is the one that
ships a padded value into a comparison, a key, or a UI.

The same rule makes comparisons case-insensitive under the common
`SQL_Latin1_General_CP1_CI_AS` collation. Do not wrap comparisons in
`UPPER()`/`LOWER()`; it only suppresses index use.

## IV-b. Primary key id strategy — a per-project decision, not inherited

Postgres gets UUID v7 for free: its native `uuid` type compares bytewise, so v7
costs nothing over v4. SQL Server does not cooperate — `uniqueidentifier` sorts by
its **last six bytes**, not its bit pattern, so a v7's leading timestamp is ignored
and its time-ordering benefit is silently destroyed. Getting v7's real payoff
(insert-order index locality) means abandoning the native GUID type for a generic
`CHAR(36)`/`BINARY(16)` column, generating the id in the application, and losing
`uniqueidentifier`'s tooling integration along the way. That is a real cost, not a
formality, so **decide it per project** rather than inheriting the Postgres answer.

**Default: native `uniqueidentifier`, `NEWID()`.** Standard type, standard
tooling, no shoehorning. Take the CHAR(36)/BINARY(16) route only when the project
has an actual coordination-free-generation or cross-instance-replication
requirement that the native type can't satisfy — record that requirement and the
choice in the project's own schema rules when it's made; don't default into it.

If a project does choose the v7 route, the trap and the fix, demonstrated on SQL
Server 2019 with three v7 values whose timestamps ascend:

```
ORDER BY <uniqueidentifier column>  ->  3, 2, 1     reverse chronological
ORDER BY <char(36) column>          ->  1, 2, 3     correct
```

`CHAR(36)` stays readable in ad-hoc queries; `BINARY(16)` is less than half the
width. Pick one and use it for every owned table in that project — never mix.
`NEWSEQUENTIALID()` is not an alternative: it's host-dependent and its ordering
does not survive a restart or a move, so it satisfies neither the native-type
default nor a real v7 need.

**Never rely on `ORDER BY` over a `uniqueidentifier` column to mean "oldest first"**,
whatever generated the value. If a query needs chronology, order by a timestamp
column.

## V. When the project does not own the whole schema

Common here: the database predates the project and another application still
writes to it. Then the schema divides in two, and the division is **code-based**.
No database schema, no separate login, is required to make it safe.

**`drizzle-kit generate` diffs your TypeScript schema files against its own stored
snapshot. It never connects to the database.** It cannot propose a change to a
table it has not been shown. So the boundary is simply which files each config
points at:

- **Introspected tables** — pulled from the existing database, used for queries.
  No config's `schema` ever points `generate` at them, so no migration can name
  them.
- **Owned tables** — everything this project adds. Its own schema entry point, its
  own config, its own `out` directory and snapshot chain.

Two rules make that boundary real:

1. **Never run `drizzle-kit push`.** It is the one command that diffs against the
   live database, and pointed at a partial schema it will propose dropping every
   table it cannot see. This is already banned outright; here it would be
   destructive to another application's data.
2. **A schema change to a table the project does not own is a cross-team change**,
   coordinated with whoever owns the other writer — never made because a migration
   would be convenient.

Prefix owned tables so they are identifiable in a shared namespace. `drizzle-kit
migrate` adds its own bookkeeping table to the database; that is unavoidable if
migrations are managed at all.

**This separation is a convention, not an enforcement.** Nothing at the database
level stops a mistake. If enforcement is wanted, that is a login-and-permissions
conversation, not a schema-layout one.

Record in the project's documentation which side of the line each table sits on,
and whether full ownership of the schema is a goal — that intent decides whether
the introspected side is a permanent fixture or a shrinking one.

## VI. Applying a migration needs the human's explicit approval

Identical to the Postgres rule and enforced by the same hook: `db:migrate` and
`drizzle-kit migrate` change a database, so they run only with the human's
explicit approval in the current conversation; an approved run is prefixed
`SKIP_DB_GUARD=1`. `db:generate` is not gated — it opens no connection.

`block-drizzle-handroll.sh` applies unchanged: only `drizzle-kit generate` writes
the coupled migration files, and hand-authoring the bookkeeping desyncs the chain.
