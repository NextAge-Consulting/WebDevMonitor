# Debugging

Ours. Failure shapes specific to this stack — the ones where the error message
points somewhere other than the cause.

**No config dumps here.** A "complete working vite.config" pinned to a version
goes stale silently and gets copied years later. Read the real config in the repo
instead.

## Hydration mismatch

Server HTML and first client render disagree. React logs a mismatch and replaces
the subtree, so the page flickers or resets state on load.

Almost always one of:

- **Reading `window`, `localStorage` or `document` during render.** The server has
  none. Read it in an effect and start from a neutral value, so both renders agree
  on the first pass. Every remembered preference — theme, collapsed nav, page size
  — hits this.
- **A time or random value computed during render.** The two runs produce
  different output by definition.
- **Locale-dependent formatting** where server and browser resolve different
  locales or timezones. Format with an explicit locale and timezone.

To find it, read the first mismatch React names and work outward — the *first* is
the cause; the rest are consequences.

## CJS/ESM resolution

Symptoms cluster: `ERR_MODULE_NOT_FOUND` in the container but not in dev,
`X is not a function` for something clearly exported, `require is not defined`.

Dev resolves through Vite's module graph; production resolves from `dist/` with
whatever `node_modules` layout npm produced. Those are different, which is why
this class only appears after deploy. See `deployment.md` for the fix.

## A change does nothing

Vite caches aggressively and generated route files can go stale. Before
debugging further: stop the dev server, delete `node_modules/.vite`, and confirm
the generated route tree matches your file names. A route that "does not exist"
after being added is nearly always this.

## Loader ran, screen did not update

The loader has no `loaderDeps` for the search params it reads, so nothing tells
the router to re-run it. Filters and paging appear inert while the URL changes
correctly. See `data-loading.md`.

## Server function fails only in production

Check in this order:

1. Is an env var missing? Dev loads env files the container may not.
2. Is auth throwing rather than the query failing? A dead session surfaces as a
   generic 500 from the client's point of view.
3. Is it a resolution failure rather than a logic failure? See CJS/ESM above.

## Testing server functions

Test the **body**, not the wrapper. Extract the logic into a plain async function
that takes its inputs and returns its result, and let the server function be a
thin `validator` + `handler` around it. Then the test needs no framework harness,
no SSR environment and no request context — and it stays valid across framework
upgrades.

If a test genuinely needs a request context, that is a signal the logic is doing
transport work that belongs in the handler instead.

## Reading errors from a slow upstream

When a third-party API is in the path, distinguish three cases before changing
code: the call was never made, the call was made and rejected, the call was made
and timed out. They look identical in the UI and have nothing in common as fixes.
Log the outbound request and its outcome at the boundary, once, so this is
answerable from the log rather than by reproducing it.
