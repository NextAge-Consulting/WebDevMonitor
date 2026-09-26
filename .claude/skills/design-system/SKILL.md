---
name: design-system
description: Project-agnostic UI/design-system discipline backed by a per-project `design.md` (google-labs-code spec). Use when creating or styling UI components, pages, forms, or any frontend work in any kit-enabled project. The skill enforces "read the project's design.md for tokens, ground the work in the project's real components for look-and-feel, then apply universal styling discipline" and refuses to proceed if `design.md` is missing at the project root.
user-invocable: false
---

# Design System

This skill is the universal layer of the design-system discipline shared across all kit-enabled projects. It is paired with a **per-project `design.md`** at the project root that defines the actual tokens, atom styling, and brand voice. The skill itself contains zero project-specific tokens — every concrete value comes from the project's `design.md`.

## The spec this skill depends on

The project's `design.md` MUST conform to the **google-labs-code `design.md` spec** (https://github.com/google-labs-code/design.md). The spec defines:

- An optional YAML frontmatter block of machine-readable design tokens: `colors`, `typography`, `rounded`, `spacing`, `components`
- A markdown body with required-order sections: Overview, Colors, Typography, Layout, Elevation & Depth, Shapes, Components, Do's and Don'ts
- Component definitions scoped to **atoms only** (buttons, chips, lists, tooltips, checkboxes, radios, input fields) with property tokens: `backgroundColor`, `textColor`, `typography`, `rounded`, `padding`, `size`, `height`, `width`
- Token reference syntax: `{colors.primary}`, `{rounded.md}`, etc.

**This skill does not define those things.** It defines the workflow and discipline that uses them.

## Procedure — apply on every UI task

### Step 1: Read the project's `design.md`

Before writing or editing ANY UI / styling code, **read `design.md` at the project root**:

```
<project-root>/design.md
```

If `design.md` is absent, **HARD STOP**:

- Do not proceed with the UI task
- Surface to the user verbatim: *"This project has no `design.md` at the project root. Per the kit-canonical design-system discipline, UI work cannot proceed without a project-level design system spec. Either (a) generate one from the codebase first, or (b) explicitly authorize ad-hoc styling for this task (rare; treat as tech debt)."*
- Wait for direction

Why hard-stop: ad-hoc styling without a design system spec is how token drift starts. The skill exists to prevent that.

### Step 2: Ground in the existing implementation (MANDATORY — this is where look-and-feel comes from)

`design.md` gives you tokens and atom specs. It does **NOT** give you the project's *look and feel* — elevation, shadows, motion, hover behavior, border treatments, density, polish level. That lives **only in the real components.** A prose description of "the vibe" cannot be executed reliably; a real component can. So before writing ANY composite UI (a card, a row, a panel, a form, a dashboard, a whole screen), **find the closest existing analog in THIS repo and build from it.** Not a fallback — the primary source of fidelity.

This is a search you run every time. No hardcoded paths, no per-project list — it works in any repo because it keys off the project's own structure:

1. **Name the role** of what you're building — card / table / list-row / form field / dashboard / modal / nav / status chip / empty-state, etc.
2. **Find the nearest existing instance in the repo.** Glob the component and route trees; grep for the role and for the distinctive utilities it would use — e.g. `Grep "rounded-2xl" --glob "**/components/**/*.tsx"` for the card treatment, `Grep "border-l-" ...` / `Grep "hover:scale" ...` / `Grep "shadow-" ...` to see how the project *actually* does elevation and motion, `Glob "**/routes/**"` for the closest whole screen. **Do not ask the user for the path — find it yourself.**
3. **Read the top 1–3 matches in full.** Extract the *real* patterns: every class they use for elevation, hover, transition/animation, borders, and spacing — not just the color tokens. This is the step that carries the feel.
4. **Build from those patterns for _vocabulary_** — the tokens, the construction (how a card/row/chip is assembled), the status language, the motion idioms. Pick the **most-polished** existing exemplar as your baseline, never the average or the oldest. Then **level the execution UP toward the polish bar in `design.md`'s guideline** (the target feel — layered depth, real motion, hover / micro-interaction). The components are concrete *examples of the vocabulary, not a ceiling on quality.*

If **no analog exists**, say so explicitly — it's a genuinely new pattern. Research primary-source design systems, propose the approach, and get sign-off (the same bar the `ui-patterns` skill sets for new interaction patterns). **Never** fill the gap by inventing from `design.md` prose alone — that is exactly what produces on-spec-but-off-brand, ho-hum output.

**Strive up, never average down (critical).** `design.md` is the *guideline* — the intended bar, deliberately ahead of the current code. The components are *examples* of the vocabulary, and they will often be less polished than the bar. That is expected and fine. Match their vocabulary (tokens, structure, brand language) but **raise the execution toward the guideline** — depth, motion, hover, tactile feedback. **NEVER downgrade a new, more-polished component to match a plainer existing one, or to match sparse prose.** Grounding in components exists to carry brand *fidelity*, not to clamp *quality* to the least-common-denominator. When in doubt, build richer, not plainer. If you deliberately raised the bar above your exemplar, say so in the build-from citation.

Why this step is mandatory and first-class (not a footnote): `design.md`'s "feel" prose is unenforceable on its own — every generator interprets it differently. Grounding in real components carries the *vocabulary* faithfully; striving toward the guideline carries the *quality*. Skipping the grounding produces off-brand output; averaging down to the components produces on-brand-but-mediocre output. You need both halves.

### Step 3: Identify the right tokens for the task

`design.md`'s YAML frontmatter is the normative source. From it:

- **Colors**: identify the semantic color tokens the task needs (e.g. for a primary CTA, `colors.primary` + `colors.primary-foreground`; for a form error, the error-feedback group)
- **Typography**: identify the typography level (e.g. `typography.body-md` for default body, `typography.h2` for a section header)
- **Rounded**: identify the radius (`rounded.lg` is the most common; pill-shaped only when the design.md prose calls it out as a distinct shape token)
- **Spacing**: use the project's spacing scale; never reach for raw px values when a scale token fits
- **Component atoms**: if the task is adding/editing a button, card, input, alert, etc., copy the property tokens from the relevant `components.<name>` entry as your starting point

**Never invent token values.** Every color, radius, padding number must trace back to a token in `design.md` or a Tailwind utility that maps to one of those tokens. If a needed value doesn't exist, surface that as a design-system gap (add a Known Gaps entry; don't ad-hoc it).

### Step 4: Apply universal styling discipline

These rules are project-agnostic and apply on top of the project's tokens:

- **Semantic over primitive.** When a semantic token exists for the role (`primary`, `card-title`, `action-primary-bg`), use it. Reach for primitive tokens (raw brand colors like `lg-navy`) only for one-off accents that have no semantic mapping. The token architecture is typically: primitive → semantic → shadcn → Tailwind utility — always grab the highest-level abstraction that fits the role.
- **No inline `style={{}}` for colors.** All color comes from Tailwind utility classes mapped to the `@theme` tokens. Inline styles bypass the design system and are forbidden. The only common exception is SVG `fill="var(--color-...)"` because Tailwind cannot target SVG attributes.
- **No raw hex values in components.** Every color reference in component code must resolve to a token. If a hex appears in a JSX/CSS file, it's a smell — either map it to a semantic token or add the token to `design.md`.
- **Tailwind mechanics live in the `shadcn` skill's `rules/styling.md`** — `gap-*` over `space-y-*`, `size-N` over `w-N h-N`, `hover:` variants over JS handlers, `cn()` for conditional joins, `truncate`, no manual `dark:`, no manual `z-index`. That file carries them with Incorrect/Correct pairs; do not restate them here.
- **Accessibility lives in `a11y-baseline.md`.** Icon-only buttons need accessible names; SVGs need `<title>` or `aria-hidden`; labels need `htmlFor` + `id`. That rule auto-loads on JSX/TSX edits and is the authoritative source for a11y patterns — don't duplicate its content here.

### Step 5: Validate the result

After making changes that affect tokens (added a color, added an atom variant, etc.), validate `design.md` is still spec-compliant:

```bash
npm run lint:design
```

This runs the `@google/design.md` spec linter. It must be wired as a project dev tool — `@google/design.md` in `devDependencies` plus a `"lint:design": "design.md lint design.md"` script (see kit handbook §12a.4). Use the declared script, **not** an ad-hoc `npx @google/design.md …`: declaring it keeps the lint reproducible and avoids agent sandboxes blocking an undeclared external download. If the script is missing, add the devDependency + script first, then run it.

If `design.md` was not modified, skip this step. If it was, the lint MUST pass before changes are committed. Fix lint findings before declaring the task done.

If the lint fails for a reason that isn't your edit (pre-existing issue), surface it explicitly — per the project constitution's "Own All Errors" rule, you fix it or document it; you don't step over it.

**Stateful atoms and computed tokens go in prose, not the YAML.** The `components:` YAML accepts only the spec's fixed property set (`backgroundColor`, `textColor`, `typography`, `rounded`, `padding`, `size`, `height`, `width`). Stateful atoms (tone maps, rings, variant escalation) and computed tokens don't fit those and will fail `lint:design` — describe them in `design.md` prose instead.

**Don't run checks during pre-approval UI iteration.** While iterating on layout, don't run tsc / biome / screenshots / `lint:design` after each tweak — the human inspects live via HMR. Do the reconciliation pass and run the checks once, after the design is approved. The reconciliation pass is: tokenize raw values, document new patterns in `design.md`, **and if the work produced a reusable component, add it to `design.md`'s component section AND to the project's UI inventory rule — in that same pass.** A component that exists but is listed nowhere that auto-loads is invisible at the moment someone needs it, which is how it gets hand-rolled a second time.

## The build-from gate (non-negotiable)

Before delivering any composite UI, state — in your response to the user — the reference you built from:

```
Built from: <path(s) to the existing component(s)/screen(s) you matched in Step 2>
```

- Matched an analog → cite the exact path(s).
- Raised the execution above the exemplar (strove up toward the guideline per Step 2) → note it: `Built from: <path> (leveled up: <what you added — depth, motion, etc.>)`. This is encouraged, not an exception.
- Genuinely new pattern → write `Built from: none — new pattern` and confirm you researched primary sources + got sign-off per Step 2.

No citation means Step 2 didn't happen and the work is **incomplete** — the same standard as shipping a signature change without the caller scan. This gate exists because "ground in the real components" only sticks when it's *cited*, not merely encouraged: the constitution's caller-scan attestation (§XIV) works for exactly this reason. An uncited UI change is presumed to have been invented from prose, and prose produces off-brand output.

## Semantic tokens, or it is a design system in name only

**A token names WHAT A THING IS, never how big it is.** `field-caption`,
`row-title`, `card-inset`, `state-message` are tokens. `label`, `microlabel`,
`sm`, `xs`, `lg` are sizes wearing token syntax, and they buy nothing: whoever
builds the next screen still has to decide which one, and deciding per screen is
the definition of drift.

**This applies to every family, not just type** — spacing, radius, weight,
elevation and sizing each need the same treatment. A project that fixed its type
scale and left `px-[10px]`, `py-[9px]` and `rounded-[6px]` scattered through its
components has fixed a fifth of the problem.

### Two tests for whether a name is right

**Can someone point at the element and name it without hesitating?** That decides
whether a name earns its place. Two names competing for one element means the
naming is wrong. Convergent VALUES are irrelevant — two roles resolving to the
same number today are still two roles if they answer different questions, because
a component saying which one it is, is what lets them diverge later without
hunting for every site.

**Does one name cover many values?** Collect every instance of a name in the
existing code and look at the spread. A flat spread across many values means the
name is too coarse and several things are hiding in it — split it and re-test. A
tight cluster with one or two outliers means the name is right and the outliers
are drift — pick the cluster. This is the falsifiable half; the first test alone
produces plausible names that do not survive contact with the code.

### Two layers, and collapsing them is the common failure

- **The ramp** — a short set of role names with variations, in `design.md` and the
  token file. Every established system has one: Material's display / headline /
  title / body / label, Carbon's productive set, Fluent's ramp.
- **Component contracts** — "a column heading is `column-heading`". These live in
  the COMPONENT, never in a document. No system's ramp names a column heading; the
  component declares which ramp entry it uses.

Naming a ramp entry after one component's use of it — a `label` token because a
label used it first — is how the two layers collapse and the ramp stops meaning
anything.

**A screen never names a raw value.** It uses a component; the component names the
role. That is the difference between a design system and a naming convention, and
it is the only version that survives contact with the twentieth screen.

### Components carry variants; a call site only places them

Tokens stop drift in VALUES. They do nothing about drift in COMBINATIONS.
`<Button variant="ghost" className="size-7 p-0">` uses only real tokens and is
still a close button nobody named — and the next surface builds its own a
different way. A shared component that takes style overrides at the call site
turns every use into a one-off styling decision, which is the size-named-token
failure one level up.

- **A variant is complete.** It carries every visual property — padding, size,
  colour, type, radius, border — and every state: hover, disabled, selected,
  read-only. It never expects a caller to finish it.
- **A call site's `className` places the component and nothing else**: margin,
  width and height, its share of a flex or grid row, position, text alignment.
  Padding, a fixed size, colour, type, border or radius at a call site is a variant
  that does not exist yet. Add it to the component, named for what the thing is.
- **Several overrides at one site is the signal.** Check the inventory first — as
  often as not the right component or variant already exists and the wrong one was
  picked. Otherwise it is a new variant.
- **State belongs to the variant.** A selected cell, a filled filter box, a
  read-only field: key it off an attribute or pseudo-class inside the variant
  (`data-selected:`, `read-only:`, `not-placeholder-shown:`), so no caller can paint
  it differently.
- **A look shared by an atom and a composite is exported once.** When a composite
  draws the same look around something else — a field shell holding an input and a
  picker trigger — export the variant function (`fieldVariants()`, alongside
  shadcn's own `buttonVariants()`) and build from it. Hand-copies of a look each
  pick up their own focus and disabled treatment, and nothing notices.
- **Restyle a vendored primitive once, at the source.** A shadcn atom left on its
  registry defaults gets repainted by every caller. Restyle the vendored file to
  `design.md` so callers never have to.
- **A prop names meaning, never style.** `cols={2}`, `size="detail"`,
  `inset="list"` — a small closed set the component interprets. Never
  `radius="xl"` or `padding="…"`: an override prop does not track the variant, so
  the day the variant changes, every call site using it silently falls out of step.
- **Glyphs are the exception.** An icon paints in `currentColor`; its caller naming
  the colour IS the design.
- **A rule about a KIND of region is one named utility.** "Scroll areas hide their
  bar" written as three classes per site is applied where someone remembered and
  missing everywhere else — the first modal body to scroll shows it. Define it once
  (a Tailwind `@utility` named for what the region is), use it in place of the
  bare `overflow-y-auto`, and fail the bare one in the check.

### Colour is usually the family that is already right — copy it

Most projects already have a colour ramp plus semantic aliases over it, with
components referencing only the aliases. That is why dark mode works by redefining
one layer and no component CSS changes. **It is the worked example of the shape
every other family needs**, and pointing at it is the fastest way to explain what
"done" looks like.

### Dark mode follows the OS; a class only overrides it

**The stylesheet applies the dark values under `prefers-color-scheme: dark` unless
`<html>` carries `light`, and a `dark` or `light` class on `<html>` forces a theme
either way.** Following the OS is the design system's job, never a script an app has
to run — shadcn's `.dark`-class-only default is not enough on its own.

- **Write the dark values once.** On Tailwind v4, define the variant and put the dark
  tokens in `:root { @variant dark { … } }` — the `claude-design` producer reads that
  form:

  ```css
  @custom-variant dark {
    &:where(.dark, .dark *) { @slot; }
    @media (prefers-color-scheme: dark) {
      &:where(:root:not(.light), :root:not(.light) *) { @slot; }
    }
  }
  ```

- **A theme toggle is optional.** It sets the class and saves the choice; toggling
  back to the OS's theme clears both. An inline script in `<head>` applies a saved
  choice before first paint — in React, with `suppressHydrationWarning` on `<html>`.

### Converting a legacy app: do not derive values from it

Measuring what the old app did most often canonises its drift with extra steps.
Take the NAMES from what things are, take the VALUES from a scale with deliberate
steps, and anchor that scale on one known-good value. Whole pixels — no shipped
system uses half-pixels, and a 13.5 in a legacy stylesheet is a symptom, not a
specification.

### Enforce it or it decays

A raw `text-sm` or `px-[10px]` is valid CSS and valid TSX, so no ordinary linter
objects. A check that fails the build on any raw value outside the token layer is
what makes the rule real; without one it is a preference. Vendored third-party
components are a legitimate exemption — name them explicitly rather than leaving
the check silent about them. The exemption covers the vendored file's insides,
never a call site passing it a `className`.

The same check enforces the variant rule: read the `className` on every element
imported from the project's component tree and fail anything outside the placement
allowlist, and fail a raw `<input>` or `<textarea>` that paints the field look
itself instead of rendering the atom.

**Exempt headless primitives and glyphs by name.** A Radix trigger, anchor or
collapsible part renders an unstyled element with no look of its own, so the
composite styling it is BUILDING a look, not repainting one — flagging it makes
every composite a false positive and teaches people to ignore the check. A
spinner or icon paints in `currentColor`, so its caller naming the colour is the
design. List both sets explicitly in the check, the same way the vendored-atom
exemption is named.

### Tokens must survive the trip to Claude Design

The token file is also the source a design system is published from, and the
design tool reads a narrower language than a browser. Write every token so a
producer can translate it without losing anything.

**Every value resolves to a plain colour or length.** Use a literal (`oklch()`,
`oklab()`, `rgb()`, hex, a length), a `var()` reference to another token, or
`color-mix(in oklab, …)` of `oklch()` / `oklab()` colours, token references or
`transparent` —
`color-mix(in oklab, var(--input) 30%, transparent)` is exactly `input` at 30%
opacity, and a producer writes it that way. Keep the reference in the source:
it is what makes a change to a light token carry into dark without anyone
remembering which tokens were derived from it. Anything else needs the producer
taught first. The producer must fail the sync on a construct it does not know,
because the design tool never does: it drops what it cannot read, and a colour
missing from the dark theme silently inherits the light one.

**Every token carries a comment saying what it is for.** One line, directly
above the declaration or trailing it on the same line: "the border of a field",
"a hover fill inside a card". No blank line between comment and token. Group
headers use the `/* ─── name ─── */` form, which belongs to no token.
The sync copies it as the token's usage note, so it is what the design agent
reads when it picks a colour. It is also the context any reader gets at the
point of use, where a separate design doc is one file too far away. A token with
no comment reaches the design tool with no meaning attached.

**Say in words what the format has no field for.** A type role that changes size
at a breakpoint carries one size, so its comment names the other. Tabular
figures, or any font feature, go in the role's comment the same way.

### Design-system components run on React 18 inside Claude Design

Design pages and canvases run React 18, whatever the app runs. A component in the
design system's feed stays inside what React 18 and 19 share: no `use()`, no
`<Context>` rendered as a provider, no `useActionState`, `useOptimistic` or
`useFormStatus`, no form actions, no ref cleanup functions — each breaks inside a
design, and the render check fails on it when the component has a preview. Ref as
a prop is handled by the bundle.
An app's own composites never enter the design system and may use anything. The
`claude-design` skill carries the bundle and the check.

## What `design.md` covers vs what it doesn't

`design.md` is scoped to **atoms and tokens**, per the google spec. It does NOT cover:

- Composite layout patterns (modal scaffold, dashboard widget composition)
- Interaction patterns (loading states, optimistic UI, error recovery)
- User flow patterns (auth flows, multi-step wizards)
- Code organization (shared constants, file structure)

Everything on that list is exactly what **Step 2 (Ground in the existing implementation)** handles: the project's own codebase is the authoritative cookbook for composites, interaction, flows, and look-and-feel. That is not an optional fallback for "harder" tasks — it is the mandatory, cited step for *every* composite UI task (see the build-from gate above). `design.md` owns tokens and atoms; the real components own everything else. Do not invent compositions that don't already exist in the project; find the analog and build from it, or raise a genuinely-new pattern with the user first.

## Brand voice and tone

`design.md`'s **Overview** section captures the brand voice (e.g. "trade-focused, utility-first" vs "playful and approachable"). Use it for **copy/wording tone** — the words in the UI — and as high-level interpretive context. Do **not** use it to resolve *visual* feel (density, elevation, emphasis, polish): prose cannot faithfully specify those, and reading them out of prose is what produces off-brand output. Visual feel comes from Step 2 (the real components), never from the Overview paragraph. The Overview is also the human-facing brand summary (marketing, onboarding) — so keep its prose accurate to the shipped product, but treat the components as the source of truth for how anything actually looks.

## Common file locations

These vary per project; check `design.md`'s prose for the actual paths. Typical layout:

- `<project-root>/design.md` — the design system spec (this skill's authority)
- `<project-root>/<ui-home>/src/styles.css` — Tailwind v4 `@theme` block where tokens are declared as CSS variables
- `<project-root>/<ui-home>/src/components/ui/` — shadcn atoms (button, input, label, dialog, etc.)
- `<project-root>/<ui-home>/src/lib/utils.ts` — `cn()` utility

`<ui-home>` is where the project keeps its **client-clean** UI — either **per-app** (`apps/<app>/`) or a **dedicated client-only UI workspace** (`packages/ui/`) consumed by every front-end app. Which one is a project choice; check `design.md` / the project's rules. Either way the client/server wall in `ui-design.md` is a hard rule: the UI home holds no server/DB code.

The CSS `@theme` block is the **runtime source of truth for tokens** — what the browser actually sees. `design.md` documents intent; the CSS implements it. If they diverge, the CSS wins (and `design.md` should be updated to match).

For **look-and-feel** (elevation, motion, composition, density) there is a second source of truth: the **real components** under `src/components/**` and the route tree. `design.md`'s prose about feel is descriptive only — if it disagrees with the components, the components win, and the prose should be corrected. This is why Step 2 reads components, not paragraphs.

## When this skill applies

- Creating any new UI component
- Editing styling on an existing component
- Adding a new page or route with visible UI
- Refactoring to use the design system (replacing ad-hoc styles with semantic tokens)
- Reviewing UI work for token compliance

## When this skill does NOT apply

- Backend / server function work
- Build / config / CI changes
- Documentation edits outside of `design.md` itself
- Code with no user-visible surface

## Adjacent skills and rules

This skill cooperates with — and never duplicates — the following:

- **`a11y-baseline.md` rule** — auto-loaded on every JSX/TSX edit; authoritative for accessibility patterns
- **`typescript-rules.md` rule** — auto-loaded on TS/TSX; authoritative for TS quality discipline, frontend conventions, no-toast policy
- **`shadcn` skill** — invoked when adding new shadcn components or working with the registry
