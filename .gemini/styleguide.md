# Gemini Code Assist — repo style guide

This file augments Gemini's default review behavior with project-specific rules. Gemini reads it on every PR review.

## Hard rules (ALWAYS flag if violated)

### Constitution §XIV — signature changes: compiler first, evidence for the blind spots

When a PR changes an exported / cross-module signature, its callers must be reconciled in the same PR. How that is verified — and what you flag — depends on whether the type system can SEE the change:

- **Type-visible changes** (TS/TSX function signatures, exported types/interfaces/enums, a Zod schema used as a TS type): the compiler IS the caller scan — a caller left on the old shape fails `check-types`. The passing type-check is the attestation. Do **NOT** demand a per-symbol `N references across M files` line for these, and do **NOT** flag its absence. That count is unfalsifiable and redundant with the compiler.
- **Compiler-blind seams** (DB / Zod / schema FIELD renames referenced by string key, raw-SQL column/table names, string-keyed dispatch, cross-process / RPC / serverFn / webhook payload shapes, cross-language boundaries): here a rename can compile green and break at runtime. The PR body MUST enumerate the reconciled call sites as `file:line` (e.g. `Callers scanned: <symbol> → apps/x/foo.ts:42, apps/y/bar.ts:88 (compiler-blind: raw-SQL column rename)`).

Flag a §XIV violation at **high severity ONLY** when a PR makes a **compiler-blind** seam change and the body lacks the `file:line` enumeration for it. A missing count on a type-visible change is NOT a violation. Prefer enumerated evidence you can cross-check against the diff over prose. The full rule lives in `.claude/rules/constitution.md` §XIV.
### Constitution §X — fail fast, fail loud

Flag any new error handler, `.catch()`, `try/catch`, or `onError` that silently swallows the error (logs only, returns default, sets state nobody reads). Trace the path from error occurrence to user visibility. Surface failures, never hide them.

### Constitution §VI — timezone-aware code

Every line that touches time MUST consider timezone. Flag:
- `new Date()` without explicit timezone in user-facing code
- "Today" / "now" without timezone qualification
- API queries with implicit "today"
- UTC query boundaries on local-time data

### Constitution §XIII — suppression discipline

Flag any new linter suppression (`// biome-ignore`, `// @ts-ignore`, `// @ts-expect-error`, etc.) that doesn't include a specific reason. "False positive" / "legacy code" / "safe" without specifics is forbidden. Suggest the cheap real fix first.

## Severity guidance

- `Critical` — runtime crash, data loss, security vulnerability, constitution violation
- `High` — bug likely to fire in production, broken contract
- `Medium` — code-quality issue, maintainability concern
- `Low` — style, naming, minor refactor opportunity

## What NOT to flag

- Test files in `**/test/**` — different conventions apply
- Migration files in `**/db/migrations/**` — auto-generated
- `*.gen.ts` files (already in `ignore_patterns`)
- **Missing `"use client"`** on shadcn atoms or components that use React hooks/state. The kit stack is TanStack Start with `rsc: false` — React Server Components are NOT in use, so `"use client"` is neither required nor conventional. The SSR build compiles and renders client-hook components without it. Do not flag its absence.
- **`calc()` without underscores in Tailwind arbitrary values** (e.g. `max-w-[calc(100%-2rem)]`, `translate-x-[calc(100%-2px)]`). The kit uses Tailwind v4, whose engine auto-normalizes these to valid CSS (`calc(100% - 2rem)`, verified in compiled output). The underscore form (`calc(100%_-_2rem)`) is a Tailwind v3 requirement that no longer applies. Do not flag missing underscores in v4.

- **Zod v4 top-level validators** (`z.email()`, `z.uuid()`, `z.url()`, `z.iso.datetime()`).
  The kit stack is Zod v4, where these are the CURRENT API and the v3 form
  (`z.string().email()`) is deprecated. Do not flag them as invalid or claim they
  throw at runtime — they type-check and parse correctly. Suggesting
  `z.string().email()` moves the code onto the deprecated API.

- **TanStack Table v9 `<table.FlexRender>`** and **`useSelector` imported from
  `@tanstack/react-form`**. Both are current API on the kit-pinned versions
  (`.claude/stack-manifest.json`), and both are routinely mis-flagged by
  reasoning from the previous major:
  - react-table **v9** binds `FlexRender` to the table instance —
    `dist/createTableHook.d.ts` declares `FlexRender: () => ReactNode`, documented
    as "a context-bound `FlexRender`". Do not claim it does not exist or that it
    fails at runtime. Suggesting `flexRender(...)` imported from the package is
    the **v8** API.
  - react-form re-exports `useSelector` at the top level
    (`dist/index.d.ts`: `export { useSelector, useStore } from '@tanstack/react-store'`).
    Do not claim the import is non-existent. `form.useSelector` is an alternative,
    not a correction.

  The pinned versions are the authority here, not the more common older API. If a
  bump is ever taken, `/review-stack` updates this entry with it.

The full rule set is in `.claude/rules/`.
