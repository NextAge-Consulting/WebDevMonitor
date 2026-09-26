# Working with Claude Design

What a design is, how it is driven and shared, what the engine does with the design
system, and the review and collaboration processes.

## What Claude Design is for

Claude Design is a tool the project reaches for — from Claude Code or from claude.ai —
whenever a screen or UI feature is worth working out visually before it is built: a
redesign, a new feature, an interaction to settle with stakeholders. It is not a step
every screen goes through.

**What makes it part of the workflow rather than a side trip is the design system.** A
design installs the project's own tokens and components, so what it shows is built from
what the app ships. Its polish — micro-interactions, layering, spacing, the small touches
— therefore carries into the build: `/ui-design implement` exports the design and Claude
Code builds the real screens from it with the same components. The design is prework for
the build, never a throwaway picture.

## What a design is: an interactive prototype

**A design is one interactive prototype that stakeholders can click through — not
mockups laid side by side on a canvas.** Each screen is its own page in the design
(the canvas's Page dropdown), opened and edited on its own; in Play the pages link
together like the real application. Screens can be added all at once or one at a time
("here is a screenshot of the next page — add it").

Each page is one fluid, responsive web page, never a frame per device size. The Design
type's own guide defaults to fixed-size artboards side by side on one canvas, so a design
built without the skill's "Building a design" rules comes out that way even when the brief
asks for pages.

## Where Claude Design lives

Claude Design is an Artifact type: a design is a "Design" artifact, a design system a
"Design System" artifact. Everything in this skill works in artifacts alone; nothing uses
the standalone claude.ai/design app or its design-system store.

A design is shared from its Share menu: by link, or by email invite with view, comment or
edit access, people outside your organization included. A viewer with the link can click
through the prototype without signing in; anything the prototype saves needs a signed-in
viewer. Every invitee needs a Claude account, on any plan including free.

## Driving a design

A design is driven from Claude Code, or from claude.ai by the person who created it. Each
side sees the other's changes; nothing is handed over between them — each reads the
design as it stands and builds on it.

- **From Claude Code — anyone with edit access.** The session that creates a design is
  attached to it. Any later session picks the design up by its link — named in the
  prompt, or attached with `/artifacts` — and publishes to it. A change it publishes
  shows on an open canvas at once.
- **From claude.ai — the design's creator.** The design's Chat button opens a chat that
  reads the canvas and revises it, using the system the design has installed; there is no
  design-system picker there and none is needed. Once the creating session has ended,
  that chat starts without its history. **An editor who did not create the design drives
  it from Claude Code:** their browser chat treats it as read-only despite edit access
  and makes a copy in their own account instead.
- **Nothing shared from another organization appears in its recipient's lists** —
  Shared with you, `/artifacts`, the design-system picker, a `list` from Claude Code. They
  name the design's link in the prompt, and the design system's link when starting a
  design of their own.
- **A Claude Code session is never told of a change made elsewhere.** A new version
  starts no turn and sends no notification, so read the design before every edit — every
  `/ui-design` action does.

## The design system: code is the source, the tool a published view

The design system is edited in one place — the project's UI package — and published to
Claude Design with `/ui-design publish-system`. It is never edited in the tool: a change
made only on the canvas is lost at the next publish, and a change made only in code is
invisible to the next design. A new pattern a design invents moves into the UI package
first, then reaches the tool on the next publish. One Design System artifact per repo,
its address the committed `artifact` field of the config.

**A design carries its own copy of the system.** Attaching a system installs its tokens
and components into the design, so a design shared with someone brings the system with
it. The copy never updates by itself: `/ui-design refresh-design` brings a design onto the
current version, and every `/ui-design` action that opens a design warns when its copy is
behind.

**What the engine handles, so a project does not have to:**

- **Token translation.** The format reads literals and references only, each family as a
  list of `{name, value, usage}`. The engine resolves `color-mix()` (exactly, as the
  browser does), `transparent`, numeric knobs and theme blocks, and fails the build on
  anything it cannot translate — the format itself would drop it silently, and a colour
  missing from the dark theme inherits the light one.
- **Usage notes.** A token's usage is the comment directly above its declaration, or
  trailing it on the same line; a blank line between comment and token breaks the link,
  and a comment containing `─` (`/* ─── name ─── */`) is a group header belonging to no
  token.
- **The bundle.** The feed barrel and the icon set, built into one script that assigns
  `window.<namespace>`; `<namespace>.Icon` draws any icon by name. The stylesheet is the
  package's CSS with the dark class rewritten to `[data-theme="dark"]`.
- **Dark mode.** The stylesheet keeps the system's `prefers-color-scheme` rule, so a
  design is dark on a dark device, overlays included; `data-theme="dark"` or `"light"` on
  the root forces one.
- **React 18.** Design pages and canvases run React 18 whatever the app runs. The bundle
  passes `ref` to function components as React 19 does, carries React 18.3.1 itself
  (hash-checked) so previews run live, and hands a canvas's list-shaped children over as
  JSX would, so Radix `asChild` triggers work. What a component must avoid is the
  design-system skill's rule.
- **The canvas editor's host element.** Every mounted component sits in a
  `display: contents` wrapper; the bundle gives it a box under a trigger, so overlays
  anchor to their trigger instead of the corner.
- **Verification.** The render check mounts every preview in light, dark and canvas mode
  and fails on errors, empty renders, overlays that do not open or open detached.
- **Provenance.** Each sync is dated in the config's `timeZone` and records the commit it
  was built from, flagged when the working tree was uncommitted.

**What stays the project's:** the token rules in the design-system skill, and the config:
which components are previewed, what each preview shows, where each one's guidelines come
from.

**The system page writes its "Consuming this system" section, component cards and
`tokens.css` only when a person edits something on the page.** A design installs a
system's components only when that section exists — so a newly published system gets one
edit on its page before designs use it.

## Process 1 — review rounds with people who do not design

For a client or colleague who reviews rather than designs. The design lives as a shared
Design artifact; they comment ("wrong colour", "use a spinner here", "can this default?").
The owner runs `/ui-design feedback`: pull the comments down, shape them into items,
settle each one together, then revise the design, republish and report what changed.
Repeat until everyone signs off.

A comment is never deleted, only resolved, and a thread stays on the design through every
later version. Resolving is what ends it: each round reads only open threads. The command
resolves only a thread a writer has sent to Claude; every other thread a round dealt with
is resolved by a person in the design view, or the next round reads it again.

## Process 2 — two people who both design

A designer and a developer both drive the design agent: the designer makes the ambitious
version, the developer grounds it in the codebase, live and reactively — "we already have
that icon", "that trigger can't exist", "drop these two concepts". A reaction relayed
through another person becomes several round trips, so each person drives their own turn.

**Share the design with edit access.** The design's copy of the system comes with it, so
one design passes back and forth with nothing exported. The collaborator who did not
create it drives it from Claude Code by its link ("Driving a design", above).
