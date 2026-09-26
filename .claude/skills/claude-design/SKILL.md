---
name: claude-design
description: Design work in Claude Design, from the first conversation about a screen to the built code, plus the project's design system there. Use when the user starts a redesign — hands over screenshots of a screen to redesign, or asks to redesign, design or prototype a screen — and through that conversation; when they ask to build the design or prototype, work the comments or feedback on a design, or implement a design in code; and to "publish the design system", "update the design system in Claude Design", "which designs use the design system" or "update the designs to the latest design system". Routes to /ui-design start, prototype, feedback, implement, publish-system and refresh-design. Carries the shape every design takes — one fluid, responsive page per screen, overriding the Design type's fixed-size artboards — the engine that turns a UI package into a Claude Design "Design System", and the rules for keeping a component library usable inside the design tool.
user-invocable: false
---

# claude-design

**Claude Design is a prototyping tool reached from Claude Code (any editor) or from
claude.ai (the design's creator), wired into the project through its design system.** Use it whenever a screen or a UI feature is
worth working out visually first — a redesign, a new feature, an interaction to settle.
It is not required for every screen. Because a design is built from the project's own
components and tokens, it is not throwaway: it is visual prework that Claude Code builds
the real screens from.

`/ui-design` is this skill invoked directly, one action per step of a design's life.
**Read `references/working-with-claude-design.md` before any design work** — it carries
what a design is, how it is driven and shared, what the engine does for you, and the
review and collaboration processes.

**Never propose the built-in `/design-sync` as a replacement for this skill's publish.**
Its `DesignSync` tool writes claude.ai/design design-system *projects*, addressed by
project id through the claude.ai login or `/design-login`. This skill publishes the
Design System *artifact* that the Design type installs, through the Artifact tool — a
different store, which `/design-sync` cannot reach.

## Routing

| The user says | Invoke |
|---|---|
| "let's redesign this screen", screenshots handed over for a redesign | `/ui-design start <name>` |
| "build the design", "make the prototype", once the shape is agreed | `/ui-design prototype` |
| "work the comments", "take their feedback on the design" | `/ui-design feedback [name or url]` |
| "build it", "implement the design", "turn the design into code" | `/ui-design implement [name or url]` |
| "publish the design system", "sync it to Claude Design", "update the design system there" | `/ui-design publish-system` |
| "which designs use the design system", "update the designs to the latest system" | `/ui-design refresh-design [url]` |

A design built any other way still follows "Building a design", below — read it before
writing any of the design's files.

## Where a project's design work lives

- **The design system** — the UI package, and its `design-system/design-system.config.mjs`,
  whose `artifact` field is the one Design System artifact the repo publishes to. Edited in
  code only.
- **Each design** — a Design artifact in Claude Design, plus one folder in the repo while
  it is in progress: `project-documentation/temporary/design-<name>/`, holding `README.md`
  (feature, lead, status, the design's link, the version built from), `brief.md` (the
  agreed shape and each feedback round's decisions), the source screenshots, and
  `export/` while `implement` runs. `start` creates it; `implement` records what outlives
  it in the feature's permanent doc and removes it. `/ui-design`'s "The design folder" has
  the detail.

## Building a design

**Build every design as an interactive prototype of a responsive web application: one
page per screen, each screen one fluid web page.** This overrides the Design type's own
guide wherever it lays screens out as fixed-size artboards per device on one canvas.

- **One page per screen.** Give each screen its own entry in the canvas's `pages` and
  exactly one artboard on it (the board entry's `page`). Link screens with
  `<a href="Other.dc.html">` so Play clicks through like the application.
- **Draw each screen once, as a fluid page.** Root at `width: 100%`, `"expand": "fill"` on
  its board entry, and the layout reflowing at breakpoints through container queries on
  the root at the design system's breakpoints, in a stylesheet the artboards link. Size
  the board entry and its `$preview` at the browser-testing viewport, 1440×900
  (`rules/integrations/agent-browser.md`); Play fills the window.
- **Open on the entry screen** — the one the brief names first:
  `"launch": {"view": "focused", "file": "<entry>.dc.html"}`.
- **Add a fixed-width preview only when a review asks for one:** an extra artboard on that
  screen's page that embeds the same screen with `<dc-import>`.
- **Use the system's components.** `window.<namespace>.<Name>` is the real component the
  app ships, and `<namespace>.Icon` draws any icon in the project's set by name — so the
  design uses what the build will use.

## Setting a project up

1. Copy `references/config-example.mjs` into the UI package — conventionally
   `<package>/design-system/design-system.config.mjs` — and fill it in. The example's
   header carries every field and its path base.
2. Add to the UI package's `package.json`, with `esbuild` as a dev dependency:

   ```json
   "build:design-system": "node <repo-relative path>/.claude/skills/claude-design/scripts/build.mjs design-system/design-system.config.mjs",
   "check:design-system": "node <repo-relative path>/.claude/skills/claude-design/scripts/render-check.mjs design-system/design-system.config.mjs"
   ```

3. Run both. The build fails, naming each offender, until every token is commented and
   resolvable and every previewed component has a guidelines source — the design-system
   skill's "Tokens must survive the trip to Claude Design" section is the rule. The check
   needs `agent-browser` on the machine.
4. Run `/ui-design publish-system` to create the system in Claude Design and record its
   address in the config.

## The engine

`scripts/build.mjs <config>` writes the Design System's files; `scripts/render-check.mjs
<config>` renders every preview in light, dark and canvas mounting; `scripts/resolve.mjs`
translates token CSS into the format (tests: `node --test scripts/resolve.test.mjs`).
The config holds everything project-specific; the scripts hold nothing project-specific.
A value, family or selector the engine does not know fails the build — extend the config
or the engine, never drop the token.

## Rules for a design-system component library

- **The component rules are the design-system skill's:** "Tokens must survive the trip to
  Claude Design" and "Design-system components run on React 18 inside Claude Design".
- **Every presentational component is exported from the feed barrel** the config names,
  or no design can use it.
- **Never set a design system as the default** when an account serves several projects;
  attach it per design.
