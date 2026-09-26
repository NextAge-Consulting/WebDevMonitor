# Server functions

Distilled from `@tanstack/start-client-core` skills `start-core/server-functions`
and `start-core/execution-model`, plus our own decisions. Scoped to what
business apps need — RPC from a component to the server, guarded and validated.

## The shape

```ts
export const getItemBrowse = createServerFn({ method: 'GET' })
  .validator((raw: unknown) => browseSchema.parse(raw))
  .handler(async ({ data }) => {
    await requireSession()          // auth FIRST, always
    return browseItems(data)
  })
```

Call it as `getItemBrowse({ data: params })`. The `{ data }` wrapper is required
on both sides — the argument is `{ data }`, the handler destructures `{ data }`.

`GET` for reads, `POST` for writes. A `GET` server function can be cached and
prefetched by the router; a `POST` never is.

## Auth is a line in the handler, not middleware

**Every server function calls `requireSession()` (or the role-checking variant)
as its first statement.** No exceptions, including functions that "only read"
— a reader is still a data leak.

**We do not use `createMiddleware` for auth.** This is a settled position, not an
oversight:

- Middleware's only real capability over a plain call is that it can run code
  *after* the handler, including on error. We have nothing that needs wrapping.
  Everything else it offers is saved typing.
- It has cost real time. TanStack/router **#2783** — server-function middleware
  pulled server code into the client bundle — was open from Nov 2024 to Feb 2026.
- Still open as of Aug 2026: **#7213** (a middleware calling a server function
  from another file throws `Server function info not found`) and **#7459**
  (`createMiddleware is not a function` on cold-start SSR in vite dev).

Upstream's own docs use `authMiddleware` as their headline example. That is not
a reason to adopt it — docs showing a pattern says nothing about whether it
breaks in a given setup.

If we ever genuinely need something wrapped around every server function, the
answer is a plain higher-order function in our own code (`withAuth(handler)`),
which runs before and after, composes fine, and cannot be broken by a framework
release.

## The route guard is not the security boundary

**A server function is an HTTP endpoint that exists whether or not any route
renders it.** The client call compiles to a `fetch` addressed by a generated
function id embedded in the client bundle, so the handler is reachable directly —
by anything that can read that id out of the shipped JS — with no route involved
and no `beforeLoad` in the path. This is the fact the rest of this section rests
on, and it is the part that gets missed: "the guard is weak" and "the endpoint is
exposed" are different claims, and only the second explains why an app whose
guard could never be bypassed still needs the check.

Upstream says it in its own guide: *"Server functions are API endpoints reachable
independently of whichever route renders the calling UI … `beforeLoad` is useful
route UX, but it is not the data boundary."*

A `beforeLoad` redirect protects *navigation*. It runs on the client during a
client-side navigation and can be bypassed. **Data protection is `requireSession()`
inside each server function, independently, every time.** Both exist; only one
is a boundary.

### The CSRF middleware is not authentication

Start installs `createCsrfMiddleware()` for server functions by default (an app
that defines `src/start.ts` must add it explicitly). It rejects a request
carrying none of `Sec-Fetch-Site`, `Origin`, or `Referer`, so a bare `curl` gets
a 403 — which reads, wrongly, as the endpoint being protected.

It compares those headers against the request origin and does nothing else. A
caller sets its own headers, so any scripted client passes. It stops a browser
sitting on another site from spending a victim's cookies; it establishes no
identity. Never let its presence stand in for the in-handler check.

## One session implementation, shared; one resolver per app

**The helpers are named `getSession` and `requireSession`, in every app, in
`lib/auth/session.ts`.** `getSession` returns the context or null and never
throws; `requireSession` returns it or refuses. A per-app name
(`requireCustomer`, `getServerAuth`, `requireDealerUser`) buys nothing and costs
a reader having to learn which of five near-identical functions this app calls.

**They are built from one shared factory, never hand-copied per app.** Copying
is how five apps end up with five subtly different session reads, and how a fix
to one of them silently fails to reach the other four.

What belongs in the shared factory is the *security semantics* — read the
session, refresh the role, refuse. What each app supplies is only its identity
mapping:

```ts
export const { getSession, requireSession } = createSessionHelpers<AppContext>({
  auth,                                  // this app's auth instance
  getHeaders: () => getRequestHeaders(), // see the note below
  resolve: ({ user, sessionId, role }) => {
    if (!permittedInThisApp(user)) return null   // null === refused
    return { userId: user.id, /* app's own entity fields */ }
  },
  onDenied: () => { throw redirect({ to: '/login' }) },
})
```

Three things that are load-bearing:

**A resolver returns null to refuse.** "Authenticated, but has no business in
this app" and "not signed in" land on the same `onDenied`, so a signed-in
stranger cannot tell the two apart by probing.

**`onDenied` is typed `() => never`.** A policy that forgets to throw is then a
compile error rather than a silent auth bypass. (TS only applies never-returning
narrowing when the call target has an explicit type annotation — if the factory
destructures the config, annotate the local: `const onDenied: () => never =
config.onDenied`.)

**The factory takes `getHeaders`, it does not import `getRequestHeaders`.** The
shared module is usually consumed by non-TanStack workspaces too (a queue worker,
an ingest service). Reaching for `@tanstack/react-start/server` inside it drags a
dependency into builds that have no business carrying one.

### Re-read the role from the database, not the session cookie

Better Auth caches the user row in the session cookie (`cookieCache`, commonly 5
minutes). A role read off the cached session is stale by up to that long, so a
capability **revoked** still works for five minutes. Read the role column from
the user table on each resolve instead. Authorization is the one thing not worth
serving stale.

The extra query is a single indexed primary-key lookup. An app whose context
exposes no role at all can skip it — and only that app.

### The denial policy is per-app, deliberately

A browser SPA usually wants `throw redirect({ to: '/login' })`, so a session that
dies while the app is mounted bounces to login instead of leaving stale authed UI
on screen. That only works where the app also carries the client-side plumbing to
re-issue a redirect thrown from a server function reached via the query client
rather than a route lifecycle — without it, the redirect surfaces as an error
anyway.

Anything non-browser throws `Response` with a real status instead. Use **401**
for "not signed in" and **403** for "signed in, not allowed" — sending an
authenticated-but-unauthorized caller to sign in again loops them through a fix
that cannot work.

## Validation

`.validator()` receives the raw input and must return the parsed value. Use the
same Zod schema the client form validates with — export it so there is one
definition, not two that drift.

Validating the *shape* of a client-sent id is not authorization. A well-formed
`clientid` is still not one this user may read. Re-check ownership against the
session before using any client-supplied identifier as a query filter.

## What runs where

Server functions are **server-only**. Their body is stripped from the client
bundle; only a fetch stub remains. That is why database imports inside them are
safe and the same import in a component is not.

Route **loaders are isomorphic** — they run on the server during SSR and on the
client during navigation. Anything a loader touches directly must be safe in
both. In practice a loader should only call server functions and the query
client, never a database module.

## Where they live

`apps/<app>/src/lib/serverFunctions/<domain>Fn.ts`, one module per domain. Routes
import from there; nothing else does. Keeping them out of route files means a
route file can be read for what it renders.
