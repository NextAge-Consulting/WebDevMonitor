# Forms

**TanStack ships no Form skill** — verified zero `SKILL.md` files in `form-core`
and `react-form`. This is entirely ours, drawn from the docs and our decisions.

The record form is the other spine of a back-office app. Everything here assumes
`@tanstack/react-form` plus `@tanstack/react-form-start`.

## Adopted per app, all-in within an app

An app either uses TanStack Form for **every** form or is listed in
`FORM_LIB_EXEMPT_APPS`. There is no per-screen judgment.

The reason is not that every form needs a library. It is that "use the library
when the form is complex" is a decision made once per screen by an actor with no
memory of the previous ninety-nine, and the inconsistency costs more than the
indirection ever saves. An app in neither state fails the build, because an
unasked question and a deliberate no are different things.

Ecommerce, marketing and control-plane apps with no real data entry are the
legitimate exemptions.

## Never shadcn's form atom

`npx shadcn add form` installs **react-hook-form** as a hard dependency. Build
field components from the plain atoms — `Input`, `Label`, `Select` — bound to
TanStack Form. `scripts/check-stack.mjs` fails the build if RHF appears.

Field components live in the **app**, not the shared UI package. A component
bound to form state is not presentational, and the design system has to keep
rendering standalone.

## The form owns the draft

```tsx
const form = useForm({
  defaultValues: original,
  validators: { onChange: recordSchema },
  onSubmit: async ({ value, formApi }) => {
    await save.mutateAsync(value)
    formApi.reset(value)        // re-baseline, so Save goes quiet again
  },
})
```

That gets dirty tracking, touched state, per-field subscriptions and a
submission lifecycle without hand-rolling any of it. `reset(value)` after a save
is the step people miss — without it the form stays dirty and Save stays lit
after a successful write.

Read the whole draft with `useStore(form.store, s => s.values)` for cross-field
conditionals. Inputs bind through `form.Field` so a keystroke repaints one field
rather than all sixty.

## Errors appear after the field is touched

Gate error display on `field.state.meta.isTouched`. A new record that lights up
red on twelve required fields the user has not reached yet is hostile.

That means **every input must call `field.handleBlur`**. Radix controls (Select,
Checkbox) have no blur of their own, so call it explicitly in their change
handler or their errors never surface.

## One schema, both sides

Export the Zod schema from the server-function module and pass it to the form's
`validators`. The client gives instant feedback, the server is the actual gate,
and there is one definition so they cannot disagree.

For server-side rules the client cannot know — uniqueness, cross-record
constraints — `@tanstack/react-form-start` provides `createServerValidate` inside
a normal server function, and `mergeForm` + `useTransform` merge the returned
field errors back into client state. Posting to `handleForm.url` with a native
`<form>` keeps it working without JavaScript.

## Numbers

`e.target.valueAsNumber` is `NaN` for an empty or partial input (`-`, `1e`).
Letting that reach the draft sends `NaN` to the server, where it lands as null
or throws. Coerce non-finite to 0 in the shared field component, once.

## What earns the library, beyond typing

These are the ERP cases. None of them are pleasant hand-rolled:

- **Field arrays** — line items on an invoice, components on a BOM, operations
  on a work order. Add, remove, reorder, validate each row, keep keys stable as
  rows shift. This is the single strongest argument for a form library.
- **Conditional requirements** — a field that becomes required based on another,
  or a section that appears only for a given type.
- **Async validation** — "is this part number already used" needs a debounce,
  out-of-order response handling and a per-field pending state.
- **Multi-step** — state carried across pages with back-navigation intact.

## Save is busy, not disabled

While a save is in flight the button shows a spinner and stays in the
accessibility tree. A `disabled` button is removed from that tree entirely, so a
screen-reader user loses the control mid-action. Reserve the icon slot so the
button does not change width when the spinner appears.
