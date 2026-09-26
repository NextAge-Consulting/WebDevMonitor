---
paths: "{**/*.tsx,**/*.jsx}"
---

# UI Patterns Rule

**Invoke the `ui-patterns` skill before building or changing how a surface is composed or how it behaves** — screen and toolbar layout, pagination, filtering, autosave, optimistic updates, loading / empty / error states, inline edit, multi-step flows. Then read the reference for the pattern you are using, from `.claude/skills/ui-patterns/references/`, named for that pattern.

```
Skill({skill: "ui-patterns"})
```

## Sibling to the design rule

`ui-design.md` routes to the `design-system` skill and owns what a thing is made of — tokens, atoms, `design.md`. This rule owns how things are assembled and how they act.

Most interactive work trips both, and the boundary test lives in the skill: what lever does this pull — one `design.md` already owns, or something beyond it? This rule is path-targeted to `.tsx` and `.jsx`, where composition and behaviour are authored, and does not load on CSS or `design.md`.

## The project keeps an inventory, and it carries content

**A pointer is not enough, and the failure is documented:** this rule and `ui-design.md` both load automatically on every UI edit, and a screen still shipped that reinvented a list pattern and hand-rolled a submit control whose component was one import away. Following a pointer is a separate act, chosen at the moment you already feel ready to write — exactly when it gets skipped.

So every project maintains `rules/project/ui-inventory.md`, with the same `paths:` frontmatter as this file so it loads on the same edits. The kit seeds it on first sync and the project owns every line from then on. It holds content, not references:

- **The pattern index** — every pattern the project has, one line each, and what it governs. Enough to pick the right one without opening anything, and enough that "there was no pattern" is falsifiable.
- **The component inventory** — what actually exists, enumerated from the filesystem rather than remembered: atoms, composites, hooks, one line on what each is for.
- **The standing prohibitions** — the things that keep getting rebuilt, written as prohibitions rather than as advice to go and look.

Generate it from the filesystem and update it in the same change that adds a component. An inventory that lags is worse than none, because it is read as complete.

## Every UI change states what it was built from (Zero Tolerance)

**End the reply that delivers UI with a `Built from:` line naming the existing file you matched.**

```
Built from: packages/ui/src/components/record-header.tsx
Built from: src/components/ui/dialog.tsx (leveled up: added the divided regions)
Built from: none — new pattern, researched and agreed first
```

**This is written HERE, in the auto-loaded rule, and not only in the `design-system` skill — on purpose.** The skill carries the same gate. A gate inside the skill is unreachable in exactly the case that matters: when the skill is the thing that got skipped. This rule is path-targeted to `.tsx`/`.jsx`, so the requirement is in front of you whether or not any skill was invoked.

It works for the same reason the constitution's §XIV caller-scan attestation works — it is **falsifiable and cheap to check.** "Did you follow the design system?" is unanswerable and gets waved through. "Built from `record-header.tsx`" takes ten seconds to disprove: open the file and see whether the delivered thing resembles it.

**No line means the grounding step did not happen, and the work is not done** — the same standard as an unscanned signature change.

**The failure this exists to stop, observed:** a dialog shipped with ragged stat grids, hints dangling off uneven tiles, and a hand-rolled primary-variant dismiss button — where the dialog atom already exposed a prop rendering the correct outline one. Every rule that would have caught it was already loaded in context. The citation was the only missing artifact, and producing it is what surfaced all three defects within a minute.

## Name the pattern while agreeing the work

**Name a screen's pattern in the plan document, in the sentence that agrees the screen** — not while it is being built.

This is the only check that fires at the moment the decision is actually made. Edit-time enforcement cannot work: by then the shape is already decided, and the rule reads as something you should have done already.

**No pattern fits? Stop and discuss.** That is never a licence to invent one mid-build. A missing name is a visible hole; "did you follow the patterns?" is unfalsifiable and gets waved through.

### A plan that names a screen and not its pattern is not an agreed plan

**When a plan deliverable produces a screen, dialog, panel or report, the plan says which pattern it is.** A step reading "the screen, reporting what happened" has agreed that something gets built and nothing about what it is — so the shape is invented at build time by whoever types first, which is precisely what the section above forbids.

Treat it as a defect in the PLAN, caught at planning time:

- **Writing a plan** → name the pattern in the same sentence that agrees the screen.
- **Reading a plan before executing it** → a screen step with no named pattern is **raised before that step starts**, not discovered in review afterwards.

Both halves are needed. Only writing plans carefully leaves every inherited plan unchecked, and the reader is the last person who can catch it while it is still cheap.

**Autonomous runs make this the only backstop.** There is no reviewer between build and done, so a pattern left unnamed in the plan is a pattern nobody ever agrees to — and the first time anyone sees the shape is after it shipped.

## A pattern names roles, never values

A pattern describing a composite — a row, a card, a field block — names which
token role each part uses and states no sizes. "A row carries a `row-title`, a
`row-subtitle` and a `metadata` line", never "13.5px, semibold". A value written
into prose cannot be changed and will not be found.

A part no role names is a missing role: raise it with the design system rather
than inventing a size in a pattern.

## Is it even a pattern?

A reference settles a question that had more than one defensible answer. If another competent developer would plausibly have built it differently, and that difference would show as inconsistency to the user, it is a pattern. If there is one obvious way anyone would reach on their own, it is craft — build it and move on. The skill carries the test and the examples.

**If it is a pattern and has no reference yet, do not improvise from training data.** Research primary design-system sources — the published guidelines of a major system such as Material, Apple's HIG, or the docs of the library you are building on, never a blog summary of them — agree the approach with the human, then implement it *and* capture it as a new file in this project's `references/`.

**Patterns are project-owned.** The kit ships this rule and the skill; `references/` arrives empty and a sync never writes into it. A pattern one project settled does not reach another — copy it across by hand, or re-decide it there.

That prevents two things, both of which have happened here: a plausible-but-wrong first attempt surviving review because the result looks fine — autosave debounced on every keystroke is the canonical case — and the same question re-argued on a later screen, reaching a different answer, because the reasoning behind the first was never written down.

## The one carve-out

A purely presentational component — no state, no mutations, no transitions, no layout decisions of its own — does not need this. Those are rarer in `.tsx` than they sound.
