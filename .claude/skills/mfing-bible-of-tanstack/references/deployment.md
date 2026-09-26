# Deployment

Ours. The build output and the server that runs it — the parts that only show up
in production, where getting them wrong means a container that starts and then
404s everything.

## The build does not produce a server

`dist/server/server.js` is a **fetch handler**, not a runnable HTTP server.
`node dist/server/server.js` starts nothing. Something has to import it and serve
it.

We use a small Hono entry (`apps/<app>/server-start.mjs`) that:

- serves static files from `dist/client` with cache headers,
- answers `/health` before reaching SSR, so a load-balancer probe never depends
  on the app rendering,
- forwards everything else to the fetch handler,
- handles graceful shutdown.

That file is **ours, not build output**. It is not bundled, it is not generated,
and it must be copied into the image.

## Static files are not served for you

Nothing serves `dist/client` unless you write it. The failure looks like the app
working in dev and returning 404s for every CSS and JS asset in production — the
HTML renders, the page is unstyled, the console is full of missing chunks.

## Pin Tailwind's scan root, or production ships unstyled

**The Tailwind entry must name its own scan root:**

```css
@import "tailwindcss" source("./");
```

A bare `@import "tailwindcss"` leaves Tailwind v4 to find the root by walking the
filesystem. The generated CSS then depends on what surrounds the source tree
rather than on the source tree alone — so the same commit yields different CSS in
a container than on a developer machine.

**The damage is that the client and SSR passes each generate and hash their own
stylesheet.** The client emits `styles-<a>.css`; the server bundle inlines
`const styles = "/assets/styles-<b>.css"` from the `?url` import. Two hashes, one
file on disk.

Nothing fails. The build is green, both passes report success, SSR renders, every
JS chunk loads with a 200. The page arrives **unstyled**, with a single 404 on the
stylesheet.

**It cannot be caught locally.** A local build resolves the root the same way
twice, so the hashes agree and everything looks correct — including a container
run on the developer's own machine if the image is built from that same tree. It
appears the first time the image is built somewhere else, which is the deploy.

The check that actually proves it, run against the built image rather than the
working tree:

```bash
docker run --rm --entrypoint sh <image> -c \
  'ls  dist/client/assets/ | grep css
   grep -rhoE "styles-[A-Za-z0-9_-]+\.css" dist/server/ | sort -u'
```

Two different names is the bug. They must be one.

Diagnosing this from the symptom is expensive, because the misleading answers are
all plausible: a stale build cache, a `dist` leaking into the build context via a
missing `.dockerignore` entry, plugin order, a missing `.git` changing what
Tailwind ignores. Each can be disproved in turn and none is the cause. Check the
CSS entry file first — it is one line.

## Bundle what npm layout would otherwise decide

Vite inlines a dependency's own code into the SSR output but leaves its
dependencies as bare imports resolved at runtime. When npm nests a package under
`some-dep/node_modules` — because a different major is hoisted to the root — Node
resolving from `dist/` cannot see it.

Dev never shows this, because Vite resolves through the real module graph. The
container fails on the first request with `ERR_MODULE_NOT_FOUND`.

Fix it by bundling those into the server build via `ssr.noExternal`, which makes
the output self-contained and immune to hoisting changes. Add packages there when
this bites, not preemptively — and comment *why* each entry is listed, because
the reason is invisible from the package name.

## A resolvable WRONG major is worse than a missing one

The section above is about a dependency Node cannot find. The nastier version is
one it finds easily and which is the wrong major, because there is no import
error at all — the process starts, then dies somewhere inside a call with
`X is not a function`.

The shape, every time: an app depends on a package that needs `dep@4`, npm nests
`dep@4` under it because something unrelated pulled `dep@3` to the root, Vite
inlines the package's code into `dist/server/server.js`, and that inlined code's
bare `import 'dep'` now resolves from the APP's directory rather than the
package's. It gets the root's `dep@3`.

Dev never shows it. Dev resolves through the real module graph, where the nested
copy is still the nearest one.

**The concrete case: `better-auth` needs `zod@4`.** `drizzle-orm` and `shadcn`
both depend on `zod@3`, so `zod@3` hoists to the root and `zod@4` lands under
`better-auth/node_modules`. The bundled auth code then calls a Zod 4 method that
does not exist on Zod 3 and the container dies at startup:

```
TypeError: sessionSchema.loose is not a function
```

**The fix is a one-line dependency, not a bundler setting:** declare the major
the app's bundled code actually needs, in the app's own `package.json`.

```json
"dependencies": { "zod": "^4.4.3" }
```

npm then places `zod@4` in `apps/<app>/node_modules`, which is the first place
resolution looks from `apps/<app>/dist/server/`, while whatever wanted `zod@3`
keeps the root copy. Two majors coexist because they are used by different code
paths — which was already true in dev.

**Do both — the dependency AND `ssr.noExternal`.** They fix different halves and
the fleet carries both. The dependency puts the right major where resolution
looks; `ssr.noExternal` removes the runtime resolution entirely by bundling the
package in. Either alone works today and neither alone is robust to the next
hoist change, which is exactly the class of change nobody notices making.

```ts
ssr: { noExternal: [/better-auth/, "@noble/ciphers", "@noble/hashes", "zod"] }
```

The `@noble/*` entries belong to the same family of failure and are listed for
the same reason — `managedNonce is not exported` (better-auth#7494) and a bare
`ERR_MODULE_NOT_FOUND`, both from a hoisted major winning over a nested one.

**`scripts/check-stack.mjs` checks this, and the two halves are NOT equally
load-bearing.** Measured across the fleet:

- **The app declaring the major itself is what protects it — REQUIRED.** The
  inlined bundle resolves from the app's directory, so an app with its own
  nested v4 is immune to whatever won the root hoist. All 7 Vite apps across the
  3 projects declare `zod ^4.4.3`; the root hoist differs between them (two v3,
  one v4) and none has failed in production.
- **`ssr.noExternal` is hardening — ADVISORY.** 6 of those 7 apps do not carry
  it and run in production. Failing them would be wrong, not strict.

The list lives in `.claude/stack-manifest.json` under `ssr_no_external`, which
is what the check reads. Adding an entry means updating it there so every
project gets it — never a local fix in one app's config.

**This paragraph used to assert that every app already carried both, and nothing
checked it.** Six of seven did not, and the assertion had gone stale unnoticed.
That is the argument for checking rather than documenting: a green
`npm run build`, a green typecheck and a working dev server all pass with the
weaker configuration, so a convention with no gate decays quietly and the
documentation is the first thing to go.

## Version has to be read at runtime, from the right file

Reading the version from a workspace `package.json` gives you the workspace's
version, not the release's. Read it at runtime from a known absolute path in the
image, and have the Dockerfile put the right one there.

## Runtime assets live outside `src/`

Anything read from disk at runtime — email templates, PDFs, certificates — goes
in `server-assets/` and is resolved via `process.cwd()`, never `import.meta.url`.
Bundlers rewrite `import.meta.url` and do not copy the referenced file, so it
resolves to a path that does not exist in the image. The Dockerfile must copy
`server-assets/` explicitly.

## Where the framework's own deployment guidance applies

Start builds through Vite and Nitro/h3, and upstream documents targets for
Cloudflare Workers, Vercel, Netlify, Bun and plain Node. We deploy the Node/
Docker path with our own Hono entry, so most of that is not our concern — read
it from `node_modules/@tanstack/start-client-core/skills/start-core/deployment/`
in the session that needs a different target.
