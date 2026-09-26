---
name: ui-patterns
description: The project's own UI patterns — how surfaces are COMPOSED and how they BEHAVE. Browse/list layouts, pagination, filtering, autosave, optimistic updates, loading/empty/error states, inline edit, multi-step flows. Use when building or changing how something is assembled or how it acts, not what it is made of. Each pattern is a reference file in references/, backed by primary-source research; read the matching one before implementing. Complements the design-system skill, which owns tokens and atoms.
user-invocable: false
---

# UI Patterns

The home for **composition and behaviour** — the layer `design-system`
explicitly disclaims. The split:

- **`design-system`** — what a thing is *made of*. Tokens, atoms, colour, type,
  spacing, `design.md` compliance.
- **`ui-patterns`** (this skill) — how things are *assembled* and how they
  *act*. Screen layouts, toolbars, pagination, autosave, optimistic UI, empty
  and error states, inline edit, wizards.

## The boundary test

There is a grey middle, and one question resolves it:

> **What lever does this change pull?** If it is a lever `design.md` or a stock
> component already owns — a colour, a radius, a button variant, a row height —
> it is `design-system`. If it goes beyond what `design.md` is scoped to, it is
> here.

Worked examples of the same screen splitting across both:

| Decision | Home | Why |
|---|---|---|
| Row height | design-system | `design.md` already carries it |
| Which button variant a toolbar action uses | design-system | Button emphasis is an atom concern |
| Adding a `popover` atom | design-system | It is an atom |
| How a page decides how many rows to show | **ui-patterns** | No `design.md` lever exists; it is behaviour |
| What a toolbar contains and in what order | **ui-patterns** | Composition |
| Showing active filters as a count vs. as chips | **ui-patterns** | A UX decision with a rationale worth not re-litigating |

## A pattern names the ROLES its parts play

When a pattern describes a composite — a row, a card, a field block, a toolbar —
it names which token role each part uses, and says nothing about sizes.

> A row carries a `row-title`, a `row-subtitle` beneath it, and a `metadata` line.

That is the second layer of the token system and this is where it lives when it
spans components: the token file defines what a role IS, the pattern defines what
a composite is MADE of, and the component wires the two together. A pattern that
says "13.5px, semibold" has hardcoded a value into prose where it cannot be
changed and will not be found.

If the composite needs a part no role names, that is a missing role — raise it
with the design system, do not invent a size here. See the `design-system`
skill's token section for how a role gets named and tested.

## Leave it at the skills root

Claude Code discovers skills at `.claude/skills/<name>/SKILL.md` only — the
directory name *is* the skill name, and there is no namespacing. Nest this under
`skills/project/` and discovery finds nothing there and skips everything beneath:
the skill silently stops existing. Project-local *rules* live in
`rules/project/`; that convention cannot extend to skills.

## First: is it even a pattern?

**A reference exists to settle a question that had more than one defensible
answer.** Its value is not that it found the correct approach — it is that it
commits the project to ONE, so the seventh screen does not quietly disagree with
the first.

So before reaching for the skill at all, ask:

> **Would another competent developer plausibly have built this differently, and
> would that difference show up to the user as inconsistency?**

Yes → it is a pattern. Write it down (after sign-off — see below).
No → it is just doing the job. Build it and move on.

| Not a pattern — build it | A pattern — worth settling |
|---|---|
| Type the name to confirm a destructive action | How a list behaves while it reloads: skeleton, spinner, blank, or hold the old rows |
| Disabling submit until a required field is filled | Whether filters show as chips or a count |
| A spinner on the button you just pressed | What a toolbar contains and in what order |
| Marking the current nav item as active | How a screen decides how many rows to show |

The right-hand column has real forks with no objectively correct answer. The
left-hand column has one obvious answer that anyone would reach independently —
documenting it adds a file to read and changes no future decision.

**These files record THIS project's choices, not general craft.** If the guidance
would be equally true in any codebase, it does not belong here.

## How to use it

1. **Look in `references/`** — one file per pattern, named for the pattern, first
   line summarising it. Read the matching one **before** implementing. It carries
   the decided approach and the sources behind it, so it is not re-derived (or
   re-guessed) each time.
2. **No reference for what you need? STOP and research primary sources first.**
   Real design systems — GitHub Primer, Nielsen Norman, GitLab Pajamas, Material,
   PatternFly, Oracle's grid guidance — not model memory. Agree the approach,
   *then* implement, *then* **wait for the human to review the built UI and call
   it good** — and only then write the `references/*.md`, once. See "Write it
   ONCE, after sign-off" below; this gate is not optional.
3. **Patterns still obey the visual layer.** Invoke the `design-system` skill for
   any styling the pattern needs; `rules/a11y-baseline.md` auto-loads on JSX and is
   authoritative for accessibility.

## Why this skill exists

Composition and interaction are where a plausible first attempt is most often
subtly wrong, and wrong in ways that survive review because the result *looks*
fine. The canonical example is autosave: debouncing the save on every keystroke
is the obvious implementation and it interrupts typing. The fix is research
before code, captured durably — the cost of researching once is paid once, the
cost of guessing is paid on every screen.

The second failure this prevents is quieter: the same question re-argued from
scratch on screen 7 because the reasoning behind screen 1 was never written
down, arriving at a different answer, and leaving the product inconsistent.

## Write it ONCE, after sign-off, describing only the approved result (Zero Tolerance)

**A pattern becomes a pattern when the human has looked at the running UI and
called it one.** Not the description of it, not your proposed reference file —
the actual interactive screen. That is the artifact under review.

Nine times in ten a newly-invented pattern gets tweaked before it is blessed.
Write the reference before that and you have documented a dream: the file
describes what you built, the product ships what survived refinement, and the two
disagree from birth.

So when you finish building and think something deserves to be a pattern: hold it.
Keep it in your head or a scratch file — anywhere but `references/`. Say so in the
report — *"new potential UI pattern, please review"* — and point at the screen to
look at. The human reviews and refines the real thing. When they bless it, you
document **that** — the actual, refined, shipped behaviour.

**This does not change between interactive and autonomous sessions.** The goal is
identical: you stop at built-and-flagged, the reference waits for the blessing.
An autonomous run reports the owed pattern like any other item; it never writes
the file to close its own loop.

The order is: research → agree the approach → build → **human reviews and
approves** → write the reference, once — **and add its line to the project's UI
inventory in the same pass.**

That last step is not bookkeeping. The inventory is `rules/project/ui-inventory.md`,
which loads automatically on every UI edit; a reference that exists but is not
indexed there is invisible at the moment it is needed, which is the same as not
existing. One line: the pattern and what it governs. Hold the research and the discarded
options in the build's own code comments meanwhile; that is where they are useful
during review anyway. **Say the reference is still owed** when you hand off for
review, so it is not forgotten once the design is blessed.

### A reference states what the rule IS, never how it was reached

Constitution §XV, applied here. No dates, no "originally", no "we changed this
because", no status of what shipped when — that lives in git. Writing once, at
the end, is what makes this possible: the iterations are not yours to record
because you were not writing during them.

| Never write | Write instead |
|---|---|
| "The first attempt was a solid fill. It failed because…" | "No background fill of any kind — a starred screen indicates in two places at once." |
| "The tabs went through two lives and lost both…" | "The top bar holds no navigation." |
| "Once the tabs were gone, sections became independent for free." | "Sections are independent." |
| "We considered X, then tried Y, and settled on Z." | "Z. Never X — <cost>." |

**A discarded option is recorded as a present-tense prohibition, not a story.**
"Never store favourites in `localStorage` — they must follow the user across
machines" carries everything the next builder needs. "We tried localStorage first
and it stranded people per-device" carries the same fact plus a chapter of
autobiography.

## A reference is GUIDANCE, never a backlog (Zero Tolerance)

**These files are rules an AI follows when building UI. Nothing belongs in one
except how to build the pattern.** A product idea parked in a reference is read
by the next session as direction, and gets built.

So a reference NEVER carries:

- **Feature ideas or "what we could add next."** Not in a "Still open" section,
  not in a "Future" note, not as an aside. Backlog lives wherever the project
  tracks work — an issue, a planning doc — never in a behavioural rule.
- **Open product questions** ("should we delete the old landing pages?"). A
  decision nobody has made is not guidance.
- **Status reporting** — what is built, what is not, what shipped when.

It DOES carry — because each of these tells the next builder what to do:

- The rule, and enough of the reason that nobody re-opens it.
- **Deliberate exclusions**, stated as a boundary: "favourites are not
  reorderable — do not add drag-to-reorder." That is scope, and it stops the next
  session re-deriving it.
- Known limitations of the pattern as specified.

The test: **would this sentence change how the next screen is built?** Yes →
keep it. No → it is backlog or a status update, and it goes somewhere else.

## Adding a reference

One file per pattern in this project's `references/`, which the kit ships empty
and a sync never overwrites. Lead with a one-line summary of the rule,
then the rules themselves — each present tense, each actionable. Record what is
excluded as a prohibition with its cost. Cite the primary sources.

Keep them short. A reference nobody finishes reading does not get followed.
