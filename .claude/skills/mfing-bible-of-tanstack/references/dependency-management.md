# Dependency Management — Transitive Overrides & Security Alerts

How to handle Dependabot / `npm audit` / security alerts in a TanStack Start app **without breaking SSR.** This is the single most dangerous class of "routine" dependency change in a Start project.

## The warning

**Do NOT reflexively pin a transitive dependency via `overrides` (npm) / `resolutions` (yarn/pnpm) to silence a security alert when that transitive lives underneath the TanStack Start build/runtime chain** — i.e. under `@tanstack/react-start`, `@tanstack/start-plugin-core`, `@tanstack/start-server-core`, `@tanstack/react-router`, or the build tool itself (`vite`, and its server stack: nitro / h3 / srvx / undici / picomatch, etc.).

It often "installs fine" and then **breaks SSR silently** — the dev server returns `Cannot GET /` / blank 404s, or you hit `createStartHandler is not a function` / `createMiddleware is not a function`, frequently only on the *second* request (after HMR) or only in `vite dev` (prod build masks it). The failure looks nothing like a dependency problem, so it eats hours.

## Why Start is uniquely fragile here (the nature, not the version)

TanStack Start is not a single package — it's a tightly version-coupled chain stitched together at build time:

- **Facade re-exports.** `@tanstack/react-start` re-exports its API via `export *` from `start-client-core` / `start-server-core`. The bundler must walk that chain intact. A duplicated or mismatched copy of any link makes a top-level export resolve to `undefined` → `X is not a function`.
- **`instanceof`-based environment detection.** The dev-server plugin has historically guarded SSR-middleware registration with `instanceof` checks against Vite's `RunnableDevEnvironment`. If an override causes **two copies** of the build tool to load (a *dual-package hazard*), `instanceof` returns `false`, SSR middleware is never registered, and **every route 404s** — with no error.
- **Virtual modules.** `start-server-core` imports plugin-provided virtual specifiers (`#tanstack-start-entry`, `tanstack-start-manifest:v`, …) that only resolve when the import flows through the official package facade at the version the plugin expects. Force a mismatched version into that chain and resolution fails at bundle or runtime.
- **Compounding npm bug.** npm's own override engine mishandles transitive/shared overrides in some configs (silently ignored under `install-strategy=linked`, or `npm install` exits 1 with no message when two overrides share a transitive). So even the override you *intended* may not be the tree you got.

Net: pinning one transitive can desync the chain or duplicate a package the runtime assumed was a singleton. The breakage surfaces as SSR failure, not as a version error.

> Evidence (TanStack/router): #6982 / #6994 (vite override → dual-package → `instanceof` fails → 404), #7285 / #7459 (`export *` chain → `createStartHandler/createMiddleware` undefined), #6821 (virtual-module resolution). npm/cli: #9197, #9109 (override engine bugs). These are the failure shapes; specific versions/issue numbers will age — the *mechanism* is the durable lesson.

## What to do instead (preferred, in order)

1. **Bump `@tanstack/react-start` (and the coordinated `@tanstack/*` packages) to a release that ships the patched transitive upstream.** Start pins its own transitive set deliberately; a newer Start release pulls a coordinated, tested combination. This is the supported fix for "alert traces through react-start." Bump the whole `@tanstack/*` set together, not one in isolation.
2. **If the alert is in `vite` or its plugins**, bump the build tool through the channel that owns it (Vite release, or the wrapper that bundles a Vite copy — e.g. a cloud adapter may bundle its own module-runner and need its own bump). Do not alias/override `vite`.
3. **Assess actual exposure first.** Many flagged transitives aren't reachable in your runtime (build-only, or a code path you don't hit). A real Start bump on the next release cycle is often the right "do nothing now" answer for a low-severity build-time-only advisory.

## If you genuinely must override (last resort)

Only when there's no Start/Vite release with the fix and the severity forces action. Treat it as temporary and **test all SSR surfaces before trusting it** — a clean `npm install` and a rendering prod build are NOT sufficient (prod static-resolves the chain and masks the dev/SSR break).

After adding the override:

1. `npm ls <pkg>` — **confirm the override actually applied** and the tree isn't marked `invalid` (npm silently ignores some transitive overrides). If it didn't apply, stop — you have a different problem.
2. **Dev cold start:** kill the dev server, start fresh, load `/`. A `Cannot GET /` / blank 404 = SSR middleware didn't register (dual-package hazard). Fail.
3. **Dev HMR:** edit any route file, re-request the page. `createStartHandler is not a function` / `createMiddleware is not a function` on the *second* render = broken facade chain. Fail.
4. **Server-function round trip:** exercise a route that calls a `createServerFn` during SSR — confirms the server entry + virtual modules still resolve.
5. **Prod parity:** `npm run build && npm run start`, load SSR routes. (Passes more easily than dev — don't let it be your only check.)

If any surface fails, revert the override; the version is not safe to force. Document any override you keep as a temporary workaround with the advisory it addresses and the Start version that will obsolete it.

## Quick rule for Dependabot triage

- Alert's dependency chain runs through `@tanstack/*` or `vite` → **bump Start/Vite, never `overrides`.**
- Alert is a leaf dev/tooling dep with no react-start/vite ancestry (e.g. a standalone CLI) → a normal override/bump is fine; the fragility above doesn't apply.
- Unsure → run `npm ls <pkg>` and look at the ancestry before deciding.

## A greenfield install duplicates peers that established lockfiles pinned long ago

**Symptom, on a brand-new project only:** `tsc` rejects the QueryClient handed to
`setupRouterSsrQueryIntegration` —

```
Type 'QueryClient' is not assignable to type 'QueryClient'.
  Property '#private' in type 'QueryClient' refers to a different member that
  cannot be accessed from within type 'QueryClient'.
```

Two copies of `@tanstack/query-core` are installed. `npm ls @tanstack/query-core`
shows one nested under `@tanstack/react-query` and a different one under
`@tanstack/react-router-ssr-query`.

**Why it only happens on a new repo.** `@tanstack/query-core` is a **peer**
dependency of `react-router-ssr-query` and `router-ssr-query-core`, declared with an
open range (`>=5.90.0`). `react-query`, by contrast, pins its own copy exactly. When
a project was first installed, the newest thing satisfying the open range *was* the
version react-query pinned, so npm hoisted one copy and the lockfile has held it
there ever since — `npm ci` never re-resolves it. Install the same blessed manifest
today and npm satisfies that open range with whatever is newest now, which no longer
matches react-query's pin.

So every established project is green and the new one is red **on identical pins**.
The blessed set is not at fault, and this is not a reason to move a pin.

**The fix is to declare the peer explicitly**, as a normal direct dependency of the
app, at the version `react-query` pins:

```jsonc
"dependencies": {
  "@tanstack/query-core": "<react-query's exact pinned version>",
  "@tanstack/react-query": "<same>",
}
```

Then delete `node_modules` and the lockfile and reinstall — editing the manifest
alone will not move a version the lockfile has already resolved. `npm ls
@tanstack/query-core` must then show one copy with every other reference `deduped`.

**This is not the `overrides` hazard above.** Declaring a peer you actually consume
is the supported way to control its resolution; it forces nothing onto the Start
chain and adds no entry to `overrides`. The distinction is worth holding: the rule
above forbids forcing a version *underneath* packages that pin their own set, while
this is naming a version for a range that was left open for the consumer to close.

**Suspect this whenever a new project fails a check an old one passes on the same
manifest.** The generalisation is not specific to Query: any peer declared with an
open range drifts on a fresh resolution, and the lockfile is what hides it.
