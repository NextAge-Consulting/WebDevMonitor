# Auth

Ours, with the framework mechanics distilled from `router-core/auth-and-guards`
and `start-core/auth-server-primitives`.

## Two layers, only one of them is a boundary

**Navigation guard** — a `beforeLoad` on a pathless layout route (`_authed.tsx`)
that redirects an anonymous visitor to `/login`. Every screen lives under it, so
protection is the default and a route added outside it is public. That is almost
never what anyone intends, so treat a top-level route as a red flag in review.

**Data protection** — `requireSession()` as the first line of every server
function, independently, every time.

The guard runs on the client during navigation and can be bypassed. It exists for
user experience, not security. If only one of the two is present, it must be the
second.

## Never a shared betterAuth factory

Export the configured instance per app; do not wrap `betterAuth({...})` in a
factory and export its return type.

better-auth's instance type is enormous. Exporting it from a factory makes
TypeScript infer and propagate that type into every consumer, and the type-check
exhausts memory. The symptom is `tsc` OOMing with no useful error, which is a
miserable afternoon.

Share reusable helper *bodies* between apps. Keep `betterAuth({...})` itself
inline in each app's `lib/auth/`.

## A dead session must not leave a screen sitting there

Guards only fire on navigation, so an open screen with an expired session shows
authed UI indefinitely while its queries fail. Handle it centrally in the
QueryClient's cache error handlers — see `queries-and-mutations.md`.

## Roles

Where a role check exists, it belongs in the same call that establishes the
session, so there is one thing to forget rather than two:

```ts
const session = await requireSession(['admin', 'manager'])
```

Per `design.md`: a control the *role* cannot use is removed from the DOM; a
control blocked by *record status* stays visible, disabled, with a tooltip saying
why. Both are UI conveniences — the server re-checks regardless.

## Passwords

Where a legacy application shares the database, the password write path is
whatever keeps both applications working — typically a dual-write inside one
transaction, with the framework's own change-password endpoint disabled so there
is exactly one path. Verify the current password explicitly; there is no
framework check to lean on once that endpoint is off.

Do not impose password rules the legacy application does not enforce. A rule only
one app applies is a rule users route around by changing their password in the
other one.
