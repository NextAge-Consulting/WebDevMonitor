# Nondeterministic (Case-Insensitive) Collations

The usual reason a project has one: the database was converted from an engine
that compared text case-insensitively by default, and the conversion preserved
that so old and new systems agree. The other is a deliberate choice for
user-facing text.

## What it is

Since PostgreSQL 12 a collation can be declared **nondeterministic**, meaning two
different byte sequences may still be equal:

```sql
CREATE COLLATION case_insensitive (
  provider = icu,
  locale = 'und-u-ks-level2',
  deterministic = false
);
```

`ks-level2` ignores case but not accents; `ks-level1` ignores both. A column
declares it, and `=`, `LIKE`, `ORDER BY`, `GROUP BY`, `DISTINCT` and unique
constraints all become case-insensitive for that column, using the index. This
replaces `citext` and the habit of wrapping every comparison in `lower()`.

## Which operators work

| Operator | On a nondeterministic collation |
|---|---|
| `=`, `<>` | Case-insensitive, uses the index |
| `LIKE` | Case-insensitive, works (PostgreSQL 18+; earlier versions threw) |
| `ILIKE` | **Throws** — `nondeterministic collations are not supported for ILIKE` |
| `~`, `~*`, `regexp_*` | **Throws** — `…not supported for regular expressions` |
| `text_pattern_ops` index | **Rejected** — same error class |

Both failures are at runtime, so an `ilike` search box type-checks, builds,
passes review, and throws the first time a user types in it.

When a regex is genuinely needed, force a deterministic comparison for that
expression only — and handle case yourself, because it is now case-sensitive:

```sql
WHERE mycolumn COLLATE "C" ~ '^[0-9a-f]{32}$'
```

## Performance

B-tree cannot use deduplication on a nondeterministic collation, and **"starts
with" (`LIKE 'value%'`) does not use a plain B-tree index** — it seq-scans.
Invisible on small tables; on large ones add a GIN trigram index:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_customer_email_trgm ON customer USING gin (email gin_trgm_ops);
```

`LIKE '%value%'` was never indexed anyway, and the same GIN index fixes it.

## Declaring a column

Drizzle has no collation option on any `pg-core` column builder (drizzle-orm
issue #638, open since 2023), and PostgreSQL will not take a nondeterministic
collation as a database default:

> There is currently no option to use a database locale with nondeterministic
> comparisons… If this is needed, then per-column collations would need to be
> used.
> — `CREATE DATABASE`, Notes. True in 18, unchanged in 19.

So it cannot be solved once, and **a new column silently lands on the database
default**. The fix is a `customType` carrying the clause — `ciVarchar` / `ciText`,
defined in `custom-types.md`:

```ts
itemname:  ciVarchar({ length: 50 }).notNull(),   // case-insensitive
tokenhash: varchar({ length: 64 }),               // byte-for-byte, deliberate
```

`drizzle-kit` then emits `COLLATE` on both `CREATE TABLE` and `ADD COLUMN`.

## Do not blanket-apply

Some columns must compare byte-for-byte, and case-insensitivity on them is a
security defect rather than a convenience:

- password digests and hashes
- TOTP secrets, API keys, session and reset tokens
- opaque ids and external-system ids
- optimistic-concurrency tokens (e.g. a QuickBooks `synctoken`)

These stay plain `varchar` / `text`, with a comment saying why — silence is
indistinguishable from having forgotten.

Values that merely *look* like they need it often do not. A hexadecimal GUID is
case-insensitive by nature: `CD9F` and `cd9f` are the same value, so folding case
cannot merge two distinct ids. Check what the value actually is before excluding
it.

Never wrap `pgTable` to rewrite `getSQLType()` for every text column (a shortcut
circulating in issue #638) — it sweeps the columns above into case-insensitivity
invisibly.

## Auditing which columns have it

```sql
select r.relname as table_name, a.attname as column_name,
       format_type(a.atttypid, a.atttypmod) as type,
       coalesce(c.collname, '(db default)') as collation
from pg_attribute a
join pg_class r on r.oid = a.attrelid and r.relkind = 'r'
join pg_namespace n on n.oid = r.relnamespace and n.nspname = 'public'
left join pg_collation c on c.oid = a.attcollation
where a.attnum > 0 and not a.attisdropped
  and a.atttypid in ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype)
order by 1, 2;
```

Drive any bulk conversion off this query, not off judgement — on a converted
database it is hundreds of columns across dozens of files, and reading names
guarantees mistakes.

## Adopting the custom type on an existing database

Converting existing declarations changes the type string in Drizzle's snapshot
(`varchar(50)` → `varchar(50) COLLATE case_insensitive`), so `generate` emits an
`ALTER COLUMN … TYPE` for every converted column even though the database already
matches. Running that rewrites tables and rebuilds indexes for nothing.

1. Convert the declarations, driven off the query above.
2. Run `generate`. It produces a large migration of no-op `ALTER`s — expect a
   few `SET DEFAULT` statements mixed in, since a type change drops defaults.
3. **Empty the generated `.sql` body** (see `migrations.md`).
4. Verify `generate` now reports no changes.

Only safe if the conversion is exact. A column declared collated that is not
collated in the database leaves the schema lying, and the next migration that
touches it behaves unexpectedly.

## A new database has no collation object at all

`CREATE TABLE … COLLATE case_insensitive` fails outright with `collation
"case_insensitive" does not exist`. That loud failure is the good case; the silent
one is a schema that never references the collation, so every text column comes
out case-sensitive and the database behaves differently from its siblings while
running identical code. See `neon.md`.
