---
paths: "**/*.{tsx,jsx}"
---

# Accessibility Baseline

Apply these at composition time. `biome lint` runs in the pre-commit hook and on every PR, but the goal is code that is a11y-correct first time so the safety net stays quiet.

AI-generated JSX skips a11y by default, because the training examples omit it. This file covers every a11y rule that fires on this codebase, plus `noExplicitAny` — which disables the type information the a11y rules depend on — and `noArrayIndexKey`, which is here because it breaks reconciliation rather than accessibility.

## Buttons — set `type=`

A raw `<button>` defaults to `type="submit"`, which inside a `<form>` submits on any click. Set `type="button"` on action buttons and `type="submit"` on submit buttons. The shared shadcn `Button` already defaults to `type="button"`.

## Icon-only buttons — give them a name

A button whose only content is an icon has no accessible name: screen readers announce "button", and keyboard users get a focus ring with no idea what it does. Three valid patterns:

```tsx
// 1. aria-label — simplest, when no tooltip is needed
<Button variant="ghost" size="icon" aria-label="Close dialog">
  <X className="size-4" />
</Button>

// 2. Tooltip — best when the action benefits from a hover hint.
//    The button still needs its own aria-label: TooltipContent is the
//    tooltip's content, not the button's accessible name.
<Tooltip>
  <TooltipTrigger asChild>
    <Button variant="ghost" size="icon" aria-label="Delete row">
      <Trash2 className="size-4" />
    </Button>
  </TooltipTrigger>
  <TooltipContent>Delete row</TooltipContent>
</Tooltip>

// 3. Visually-hidden span — when the icon already reads to sighted users
<Button variant="ghost" size="icon">
  <Settings className="size-4" />
  <span className="sr-only">Open settings</span>
</Button>
```

**Name the action, not the icon.** The name is announced verbatim and shown on focus.

| Good | Bad |
|---------|--------|
| "Close dialog" | "X" |
| "Delete row" | "Trash icon" |
| "Open settings" | "Settings" — ambiguous without context |
| "View order details" | "Click here" |

When the button already has a name and the icon is an inline `<svg>`, mark the SVG `aria-hidden="true"` — naming both double-announces.

## SVG icons — `<title>` or hidden

Every inline `<svg>` carries either a `<title>` child with non-empty text (preferred — it becomes the accessible name), or `aria-hidden="true"`, valid only when the parent already has a name.

```tsx
<svg viewBox="0 0 24 24">
  <title>Close</title>
  <path d="…" />
</svg>
```

Write the SVG across lines with `<title>` as the first child, as above — Biome's `noSvgWithoutTitle` is finicky and may still fire on a single-line SVG whose `<title>` is inline. That formatting is the workaround for the linter, not an accessibility requirement.

## Labels — link them to a control

```tsx
// htmlFor + id — preferred, more layout flexibility
<label htmlFor="email">Email</label>
<input id="email" type="email" />

// or wrapping
<label>
  Email
  <input type="email" />
</label>
```

Generate the id with `useId()` in a reusable form component:

```tsx
function FormField({ label, value, onChange }: Props) {
  const id = useId()
  return (
    <>
      <label htmlFor={id}>{label}</label>
      <input id={id} value={value} onChange={(e) => onChange(e.target.value)} />
    </>
  )
}
```

In shadcn-heavy files use the `Field` + `FieldLabel` pattern from the shadcn skill's `forms.md`, which handles the association.

## `onClick` on a `<div>` or `<span>` — make it a `<button>`

Convert it to `<button type="button">`. A genuine exception — modal backdrop, table row with keyboard navigation through cell content, card-level enhancement where the primary interaction is inside — gets an inline `// biome-ignore` naming the reason.

## Groups of controls — `<fieldset>` + `<legend>`

Radio groups, checkbox groups and button-groups acting as a picker use `<fieldset>` + `<legend>`, not `<div>` + `<label>`.

```tsx
<fieldset>
  <legend className="block text-sm font-medium mb-2">Export Format</legend>
  <div className="flex gap-2">
    <button type="button" onClick={() => setFormat("pdf")}>PDF</button>
    <button type="button" onClick={() => setFormat("csv")}>CSV</button>
  </div>
</fieldset>
```

## List keys — a stable id, never the array index

`key={index}` breaks reconciliation on reorder or delete. Use an id from the data, or build a composite key from unique fields (`` `${item.type}-${item.imageId}` ``).

## Focus order is DOM order

**Decide the tab order first, write the markup in that order, and let the layout follow.** When tab order feels wrong the markup is wrong — move the element rather than renumbering it.

The recurring case is a "Forgot password?" link placed in the password label row, which puts it between the two credential fields. The order people want is `email → password → submit → recovery`: credentials and the action they feed are uninterrupted, and the uncommon path comes last.

```tsx
// ❌ Link sits in the label row, so it tabs before the input
<div className="flex items-baseline justify-between">
  <Label htmlFor="password">Password</Label>
  <Link to="/forgot-password">Forgot password?</Link>
</div>
<Input id="password" type="password" />
<Button type="submit">Sign in</Button>

// ✅ Markup in the order it should be tabbed
<Label htmlFor="password">Password</Label>
<Input id="password" type="password" />
<Button type="submit">Sign in</Button>
<Link to="/forgot-password" className="self-center">Forgot password?</Link>
```

Reach for CSS placement only when the visual position is genuinely non-negotiable — a two-column grid can hold an element in a label row while it sits later in the DOM. Prefer moving it: an absolute offset pinning an element to a row it is not in shifts the moment a conditional error message renders above it.

**`tabIndex` is for participation in the tab order, never for position within it.** Both shortcuts that reorder are worse than the problem they solve:

- **`tabIndex={-1}` used to skip an inconveniently-placed element** strips it from the keyboard path entirely — on the example above, from the one user who cannot get past the password field.
- **A positive `tabIndex`** creates a second tab sequence running ahead of everything on the page, and breaks silently the moment someone adds a field without renumbering. Treat any positive value as a defect; `a11y/noPositiveTabindex` catches it.

Used for participation rather than position, both are fine: `tabIndex={0}` puts a non-interactive element into the natural order, and `tabIndex={-1}` makes something focusable only programmatically — a heading you move focus to after navigation, say.

## Never `autoFocus`

It hijacks screen-reader focus on load with no warning. Use `ref.current?.focus()` gated on user intent.

## Types over `any`

`any` disables type checking and the a11y rules that depend on inferred element types. Use `unknown` with narrowing — `catch (error: unknown)` then `error instanceof Error ? error.message : "…"` is the standard error-handler pattern.

## Suppression of last resort

Suppress inline with a written justification, adjacent to the flagged code:

```tsx
// biome-ignore lint/a11y/useKeyWithClickEvents: <specific reason; not "FP">
```

Biome's inline suppression applies only to the immediately following line, and stacking it with another directive comment (`// nosemgrep`, etc.) between it and the code breaks it silently.

## Reference

Biome rules enforcing this file, all at `error` severity via `"recommended": true`: `a11y/useButtonType`, `a11y/noSvgWithoutTitle`, `a11y/noLabelWithoutControl`, `a11y/useKeyWithClickEvents`, `a11y/noStaticElementInteractions`, `a11y/noAutofocus`, `a11y/noPositiveTabindex`, `suspicious/noArrayIndexKey`, `suspicious/noExplicitAny`.
