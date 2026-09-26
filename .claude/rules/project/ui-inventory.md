---
paths: "{**/*.tsx,**/*.jsx}"
---

# UI Inventory: What Already Exists (Zero Tolerance)

**This file auto-loads on every UI edit, and it carries CONTENT rather than
pointers, deliberately.** `ui-patterns.md` and `ui-design.md` also load here and
both tell you to go and read a skill — which is a separate act, chosen at the
moment you already feel ready to write, and therefore skipped. This file exists
so that not knowing what already exists stops being available as an excuse.

**Nothing below is optional to know. If you are composing a screen and have not
read this list, you are about to reinvent something on it.**

---

> **This is the kit's starting point — the project owns it from here.**
> Everything between this line and "Keeping this file true" is a SHAPE to fill
> in, not content to keep. Replace the bracketed examples with what this project
> actually has, enumerated from the filesystem. Delete this blockquote when the
> first real pass is done. An inventory that still describes the kit's examples
> is worse than an empty one, because it is read as true.

## The list patterns — pick one, never a third

Most projects converge on two or three list shapes and then quietly grow a
fourth. Name them here, with the rule that decides between them, so "which kind
of list is this" is answered before anything is written.

| Pattern | For | The row is | Reference |
|---|---|---|---|
| _[e.g. **Browse**]_ | _[first-class records — the things that get their own route]_ | _[the control: clicking it opens the record; no per-row edit affordance]_ | _[`browse-layout.md`]_ |
| _[e.g. **Edit-in-place**]_ | _[short lookup tables — a handful of rows, two or three short columns]_ | _[edited in the grid, with an explicit add row and per-row confirm]_ | _[`lookup-table-editing.md`]_ |

State the boundary between them explicitly — the ambiguous case is what a third
pattern grows out of. _[e.g. "A record with more than a couple of fields opens
as its own route; an inline editor that fills the viewport is a detail screen
wearing a list's chrome."]_

Built examples: _[name a real screen for each pattern, with its route — a reader
comparing against working code beats one reasoning from a description]_.

## Every pattern reference, and what it governs

Read the matching one IN FULL before composing that kind of surface.
`.claude/skills/ui-patterns/references/`:

| File | Governs |
|---|---|
| _[`browse-layout.md`]_ | _[one line: what surface it covers and the decisions it settles]_ |
| _[`loading-states.md`]_ | _[skeleton vs spinner, when an indicator is gated, busy vs disabled]_ |
| _[…one row per reference file that exists…]_ | |

One line each is the point: enough to pick the right reference without opening
anything, and enough that "there was no pattern for this" is falsifiable.

## Components that EXIST — do not hand-roll these

Hand-rolling is not banned; reaching for it by default is the failure. Before
writing a control, check it against this list.

### _[`@ui/components/` — the project's own display vocabulary]_

| Component | Use for |
|---|---|
| _[`IconButton`]_ | _[**every** icon-only button — it carries the required label that feeds both `aria-label` and the tooltip. A raw button with an icon child is how that gets forgotten]_ |
| _[…]_ | _[one line each: what it is FOR, and where relevant the mistake it prevents]_ |

### _[`@ui/components/ui/` — vendored atoms (shadcn or equivalent)]_

_[List the installed atoms as a plain run of names — they need no per-item gloss,
only presence. e.g. `badge` `button` `card` `checkbox` `dialog` `input` `label`
`popover` `select` `skeleton` `switch` `table` `tabs` `textarea` `tooltip`]_

### _[`@/components/` — app-level composites]_

| Component | Use for |
|---|---|
| _[`form/FormActions`]_ | _[the submit control of every record form — gating, busy state and status wording in one place. Hand-rolling save + cancel is the exact thing it exists to prevent]_ |
| _[`form/fields`]_ | _[the bound field set: label, hint and error wired to the form library]_ |
| _[…]_ | |

### Hooks

_[`useFitPageSize` (paging), `useDelayedLoading` (indicator gating),
`usePermission` (what the current user may do) — one line each]_

## Standing prohibitions

The things that keep getting rebuilt, written as prohibitions rather than as
advice to go and look. Add a line here the second time something is
hand-rolled — that is the signal, not a judgement call.

- _[**Never hand-roll a save/cancel pair.** Use the form-actions composite.]_
- _[**Never a bare button with only an icon child.** Use the icon-button atom.]_
- _[**Never invent a third list pattern.** If neither fits, that is a discussion,
  not a decision to make while writing.]_

## Naming the pattern is part of agreeing the work

A screen's pattern is named while the work is being planned — in the plan
document, in the sentence that agrees the screen — not chosen silently at build
time. **If no pattern fits, that is the signal to stop and discuss**, and a
missing name is a visible hole in a way "did you follow the patterns?" never is.

## Keeping this file true

Generated from the filesystem, not from memory.

**It updates through the mechanisms that already work**, rather than on a note
asking nicely:

- **A new pattern** → the `ui-patterns` skill's write-once step. Research, agree,
  build, human approves, write the reference, **add its line here** — one pass.
- **A new component** → the `design-system` skill's reconciliation pass. Tokenize,
  document in `design.md`, **add its line here** — same pass.

Both of those already gate on a human sign-off, which is what makes them stick.
An inventory that lags is worse than none, because it is read as complete.
