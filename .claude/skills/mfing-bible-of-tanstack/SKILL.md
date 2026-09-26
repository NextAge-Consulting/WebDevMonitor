---
name: mfing-bible-of-tanstack
description: House rules for TanStack Start, Router, Query, Table and Form in business applications — which data layer a screen uses, server functions and auth, browses, record forms, loading states, and how to find upstream guidance for anything not covered here. Use when creating routes, server functions, browses or forms, wiring queries or mutations, adding or upgrading a TanStack dependency, implementing authentication, building webhooks, or debugging data fetching.
user-invocable: false
---

# The MF'ing Bible of TanStack

How we build back-office and business applications on TanStack. Read the section
you need — the detail lives in `references/`, one file per job.

## How the pieces fit

**Router** decides *when* data loads and what renders. **Query** owns caching,
refetching and mutations. **Start** puts server functions and server routes in
the same app, type-safe end to end. **Table** is a headless state machine for
browses. **Form** is the same for record entry.

The joins matter more than any one library:

- A route **loader** prefetches into the **query cache**; the component reads
  from that cache. One definition of the query, used by both.
- A **server function** is the only thing that touches the database. Loaders and
  components call server functions; they never import server code.
- **Table** and **Form** hold UI state only. Neither fetches anything.

## Versions are not listed here

`.claude/stack-manifest.json` holds the blessed version of every TanStack
package; `scripts/check-stack.mjs` enforces it.

**Lockstep is absolute.** TanStack publishes no LTS — no `lts` dist-tag, no
support window, one rolling line per library — so the kit *is* the LTS. If a
project uses a TanStack library it uses the kit's version, pinned exactly.
Adding or moving a pin is a kit decision, made by the maintainer through
`/review-stack` — a command that installs only on their machine. Never change a
pin to get a build green; raise it with them.

## The opinions

**Which data layer.** Query is the default for interactive screens. A route
loader alone is fine when the screen owns its data and nothing shares it. A
loader over a server-side cache is legitimate when a large reference set is read
by many screens and per-screen invalidation would mean an enormous query — that
one is a deliberate choice with a measured reason, recorded in a comment where
the next person will hit it.

**Fresh by default.** Business screens show current data without the user
reloading. That is configured once on the QueryClient and inherited, never added
per screen.

**Auth is a line in the handler.** Every server function calls `requireSession()`
first — a server function is an HTTP endpoint reachable without the route that
renders it, so the route guard is navigation UX, not the boundary. We do not use
`createMiddleware` for auth — see `server-functions.md` for the evidence, which is
stronger than a style preference.

**The URL is the browse's state.** Filters, page and size are search params, so a
screen can be bookmarked, pasted and refreshed.

**Forms are per app, all-in.** An app uses TanStack Form for every form or is
listed in `FORM_LIB_EXEMPT_APPS`. Never shadcn's form atom — it installs React
Hook Form.

**Types are inferred. Never cast.** If you are reaching for `as`, a generic
parameter is the fix.

**Router is client-first.** Loaders run on the client by default. It is not
Next.js; do not bring those assumptions.

## References

| Job | File |
|---|---|
| Route loaders, loaderDeps, router+query wiring, guards, selective SSR, deferred data | `data-loading.md` |
| Filters, paging and sort as URL state; the all-digits coercion trap | `search-params.md` |
| `createServerFn`, validation, auth, the session-helper factory, what runs where, why not middleware | `server-functions.md` |
| queryOptions, cache keys, scoped invalidation, optimistic updates, dead-session handling | `queries-and-mutations.md` |
| Browses on Table v9 — column defs, server paging, selection, column control | `browse-tables.md` |
| Record forms on TanStack Form — validation, field arrays, server validation | `forms.md` |
| When to show a spinner, a skeleton, or nothing; anti-flash gating | `loading-states.md` |
| Navigation guard vs data protection, roles, betterAuth pitfalls | `auth.md` |
| Public endpoints, signature verification, idempotency | `webhooks.md` |
| Build output, the Hono server, static files, runtime assets | `deployment.md` |
| Hydration mismatches, CJS/ESM, stale caches, testing server functions | `debugging.md` |
| Dependabot triage, `overrides` safety | `dependency-management.md` |

These are **distilled** — our subset in our words, not copies of upstream. They
cover what business applications need. Query and Form have no upstream skill at
all, so those two are entirely ours.

## Something not covered here

Upstream ships far more than we carry, including migration guides we
deliberately do not keep — a migration is a one-off, and a guide for it goes
stale between uses.

```bash
ls node_modules/@tanstack/*/skills/          # what this project's versions ship
```

Read the relevant `SKILL.md` there **in the session that needs it**, then let it
go. Do not copy it into `references/`; that is how a kit accumulates content
nobody refreshes. If a topic keeps recurring, that is a signal to distil it
properly, which is a kit decision.

## Before you trust a rule

Rules in this file and its references are dated by the versions in the manifest.
A claim of the shape "don't do X because it breaks Y" is only as good as its
evidence, so each one here cites what it is based on — an upstream issue, a
verified behaviour, or a decision we made and why.

If you find one that cites nothing, treat it as suspect and check before
following it. That is how the last set of rules went wrong.
