---
paths: "{design.md,**/*.tsx,**/*.jsx,**/*.css,**/*.scss}"
---

# UI / Design System Rule

**Invoke the `design-system` skill before writing or editing any UI or styling code, or the project's `design.md`.**

```
Skill({skill: "design-system"})
```

It enforces "read the project's `design.md` first, then apply universal styling discipline", and hard-stops when `design.md` is missing from the project root. On that hard stop, ask the human — a design system is theirs to establish, so do not write one yourself and do not proceed with ad-hoc styling instead.

When the file you are editing *is* `design.md`, run `npm run lint:design` before calling the change done. The skill instructs this; the rule's job is to make sure the skill loads.

This rule is path-targeted because JSX and TSX consume tokens, CSS and SCSS hold the `@theme` definitions, and `design.md` is the spec itself. Server functions, tests, config and other prose don't touch the design system.

## Adding a component means adding it in two places

`design.md` is the authority for what the design system contains, and it is not auto-loaded — this rule is. So a component can exist, be specified, and still get hand-rolled, because nothing put its name in front of whoever wrote the screen.

The project's `rules/project/ui-inventory.md` — path-targeted to the same globs — carries the list of components that exist, one line each on what they are for. `design.md` keeps the spec; the inventory answers "does this already exist", which is the question actually being got wrong.

Add a new component to both, in the same change as the component itself.

## Authority chain

1. **The CSS `@theme` block** (typically `src/styles.css` or `apps/shared/src/styles.css`) — the runtime source of truth, what the browser actually sees.
2. **The project's `design.md`** — the documented spec, google-labs-code compliant.
3. **The `design-system` skill** — project-agnostic discipline for consuming any spec.

Where runtime and documented spec diverge, runtime wins: update `design.md` to match.

## A token names what a thing IS

**Name the role, never the size.** `field-caption`, `row-title` and `card-inset`
are tokens; `label`, `microlabel`, `sm`, `xs` and `lg` are sizes in token
clothing, and they leave the next screen with the same decision to make.

**Every family, not just type** — spacing, radius, weight, elevation and sizing.
Colour is usually the one already done right (a ramp plus semantic aliases,
components referencing only the aliases); it is the shape the others need.

A component picks a role. **A screen writes no raw value at all** — it uses a
component, and the component names the role. That is what stops the same thing
rendering at four sizes across four screens.

Adding a role happens when a thing exists that none of the current roles names —
not when an existing role looks slightly wrong on one screen. If two roles compete
for one element, the naming is wrong and that is a conversation, not a new token.

**Back it with a check that fails the build.** A raw `text-sm` or `px-[10px]` is
valid Tailwind and valid TSX, so no ordinary linter objects; without a gate this
rule is a preference.

**The two tests for a name** — can someone point at the element and name it
without hesitating, and does one name cover many values in the existing code —
are in the `design-system` skill, with why the second one is the half that
actually catches a wrong name.

## The client/server wall

The design system's UI — tokens, atoms, `cn()`, display components — lives in a home with client dependencies only (react, radix, cva) and no server or DB imports. One front-end app puts it in that app's `src/components/ui/`; more than one puts it in a dedicated client-only workspace (`packages/ui`) they all consume.

The wall is bidirectional. **The UI home holds no server code**, so a UI atom can never drag pg or drizzle into the client bundle. **The server-shared package holds no UI**, so a headless app — a REST API, a worker — can consume shared business logic with no path reaching a React import. Keep that true even with no headless app today: enforcing it from the start costs nothing and retrofitting it is a refactor.

A component needing server data is an app-level composite wiring a server function to a UI atom, not the UI home reaching into the server.

A project that cannot yet satisfy the wall — UI still living in its server-shared package — records the exception in a file under `rules/project/`, naming the migration path.

### A third tier, only when something needs it

Server-shared plus UI home covers most projects. A third appears when a project has shared code that is neither: reachable from browser code, used by more than one front-end app, and not presentational — a Stripe browser integration, a shared serverFn, a shipping-API client.

"Reachable from browser code" is the test, not "executes in the browser". A serverFn runs on the server, but the client imports its reference to call it, so it cannot live in the browser-free server-shared package. It must not go in the UI home either, which stays clean presentation. So it earns its own workspace, conventionally `packages/web`, holding integrations and shared serverFns and never touching the database.

Any front-end may import it — apps, and extension apps too.

Create it when the code that belongs in it exists, never speculatively — an empty third package is another manifest, another path alias, and a "where does this go?" decision on every future change. Most projects never need it.

### Browser extensions are all browser

A browser-extension app is client code end to end. There is no server half, so nothing in it can justify a data-tier import — a stray one ships drizzle into the extension bundle.

An extension app may consume the UI home like any other front-end. It must never import the server-shared package, and never import database code (`drizzle-orm`, `pg`, `postgres`, `@neondatabase/*`) directly.

The guard identifies an extension app by a browser-extension builder in its dependencies — `wxt`, `plasmo`, `@plasmohq/parcel-config`, or `@crxjs/vite-plugin` — so a new extension is covered the moment its `package.json` names one, with nothing to configure. It is also excluded from headless-app detection: an extension has no `react` dependency and may have no `.tsx`, which would otherwise read as a server-only service, and the two have opposite rules about reaching the database.

### The one sanctioned crossing: contract types

Row and param shapes produced by server loaders and rendered by UI components are defined once, in the UI home under `contracts/`, and `import type`d back by the server module that produces them. Types erase at compile, so nothing crosses at runtime.

This is the only way the server-shared package may reference the UI home, and it is types-only — a runtime import is a violation. Contract modules import nothing but sibling contract modules. Declaring the shape twice drifts; putting it in the server tier and importing it from UI breaches the wall.

### The guard

`scripts/check-workspace-tiers.mjs` (CI job `workspace-tiers`) enforces all of the above. It detects which tiers a repo has — server-shared, UI home, web tier, headless apps (an app workspace with no `react` dependency and no `.tsx`), and extension apps (an app workspace whose dependencies name an extension builder) — and checks only the walls that exist, so a repo with no shared workspace passes unconditionally.

Read its success line: it names what it actually enforced. Fewer tiers listed than you expect means a tier was not detected, not that it was checked and found clean.

It detects the UI home as the `packages/ui` workspace. A single-app UI home living in `apps/<app>/src/components/ui/` is a directory, not a workspace, so the guard does not see it and that wall is yours to hold by hand until the project grows a second front-end.

## The one carve-out

If the human explicitly authorizes ad-hoc styling for a single one-shot task — a debugging UI, say — you may proceed without the skill. Document the exception in the change and treat it as tech debt to reconcile.
