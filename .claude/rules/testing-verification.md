# Testing & Verification

Who runs tests depends on whether a human is available to hand off to — not how the session was launched. A background job with a human watching is still interactive.

## Interactive sessions

The human drives testing. Run agent-browser, e2e flows, or any manual verification pass only when they explicitly ask ("test this", "verify it"). Announcing that you are about to verify is not permission, and the human starting a dev server is not an invitation to test against it.

Your job ends at build and static verification — typecheck, lint, build. Then hand off: state what is ready and exactly what a verification would need.

## Autonomous sessions

`autonomous-sessions.md` defines the mode. It is asserted by the human or by an unattended launch, never inferred.

In an autonomous session, verify your own work — drive agent-browser and the relevant e2e flows to completion. There is no one to defer to.

## Which tier a test belongs in

**The test is written in the same change as the code it covers**, unit and integration
alike. Not afterwards, not in a follow-up.

**A tier with no tests in it yet is not a reason to skip.** The first test in a project
establishes the pattern; writing it is ordinary work, not a decision needing sign-off.
"There is no precedent, so I won't invent one" is avoidance wearing the clothes of
prudence — see `working-discipline.md`.

### The bar

**Would a mock have to invent the answer?**

- **No — the answer is in the code.** Unit test. Formatting, parsing, validation, a
  branch, a calculation, which of two paths a value takes.
- **Yes — the answer comes from the database.** Integration test. Collation, column
  types and widths, `NULL` against empty string, defaults, unique and foreign-key
  constraints, generated ids, what a real join returns over real data shapes, what a
  stored timezone does.

**"It saved the row" and "it read back what I wrote" are the ORM working.** Neither is a
test of your code, and asserting them costs a database round trip to learn nothing. If you
cannot name what would be WRONG without the test, delete it.

Worked examples of a test that earns its place, each a real defect it would have caught:

- A lookup by one spelling finds a row the other application stored in another case —
  because the column collates case-insensitively.
- A missing setting returns its fallback **without writing a row** — because the system it
  replaced wrote one, and that is how the table filled with rows nobody configured.
- An empty date reaches the column as `NULL` rather than an epoch.
- A value written into a legacy fixed-width column comes back trimmed.
- A timestamp is stored in the zone every other row uses, not the server's.

### It changes how the code is shaped

**A data function takes its connection as a parameter.** The harness runs each test inside
a transaction it always rolls back and hands that transaction in; a function that resolves
its own connection cannot ride it, so it cannot be tested at all and nothing will say so
until someone tries.

```ts
// Testable: the caller supplies the connection.
export function readThing(db: Db, id: number) { … }

// The request-bound wrapper. The auth boundary lives HERE, never in the query —
// a boundary is about the request, and a query has no request.
export async function getThing(id: number) {
  await requireSession();
  return readThing(connectionForRequest(), id);
}
```

Discovering this at test-writing time means a refactor. Write it this way first.

## Running the suite

These apply whenever you DO run tests, on either path above. They do not authorize a run.

**Run `npm test` from the repository root.** The standard shape is a root `test` script delegating to the shared vitest config, with `npm test -- --project unit` when you want unit only. Config, fixtures and tooling paths resolve relative to the root — notably the Drizzle config file, which the integration `globalSetup` shells out to. Run `npx vitest` from inside a workspace and it dies in setup hunting a config that is not at that path, which looks like a broken suite when it is only mis-invoked.

A project on a different stack runs whatever its own `package.json` or Makefile declares. The root-invocation rule never changes.

**Before calling a suite blocked, run it the canonical way, read the actual error, quote it to the human, and name the specific cause.** A failure in global or session setup is a mis-invocation until proven otherwise. An inferred blocker is a fabricated one.

### The integration tier is Postgres/Neon-specific

Everything from here to the end of this section assumes `DB_ENGINE` is
`PostgreSQL`. Check before applying any of it:

```bash
jq -r '.DB_ENGINE // ""' .claude/sync-substitutions.json
```

On any other engine the branch-per-run model does not exist — nothing else
branches a database in one API call — so the project defines its own integration
strategy (a disposable container per run, a transaction-rollback harness against a
dev instance, or no integration tier) and records it in `rules/project/`. The
root-invocation rule above, and the "read the actual error before calling it
blocked" rule, hold on every engine.

**Confirm the integration project actually ran.** The vitest config drops it silently when `NEON_API_KEY` or `NEON_PROJECT_ID` is missing from `.env`, and `npm test` still exits green. Read the summary for `|integration|` labels in the per-file output, and for a duration in tens of seconds rather than about one. A short run with no labels means integration did not run — say so and name the missing credential rather than reporting a pass.

**Run the integration suite. It cannot touch production.** Each run provisions its own throwaway Neon branch, migrates it, points `DATABASE_URL` at that branch before any worker spawns, and deletes it in teardown. Every test runs inside a rolled-back transaction. It costs about a cent a run.

The branch is forked from production, which is why the data is real — but every write lands on the disposable copy, and the fork is a read. The DB guard covers migration commands invoked from the shell, not the migrate inside the harness, so it is not a reason to skip either.

**Never skip or stall a test run over doubt about which database you are on.** That doubt has cost whole sessions. Tests provision their own branch, so the question does not arise; and where you genuinely need the answer, `node scripts/db-branch.mjs` gives it in one API call rather than an assumption.
