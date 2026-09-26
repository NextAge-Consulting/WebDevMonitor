# Accessibility in Primitives

Primitives in `components/ui/*` must be a11y-correct by default so
downstream callers inherit correctness. Fix the primitive once; don't
re-implement a11y at each call site.

## Contents

- Button defaults to `type="button"`
- Label requires consumer-wired association
- Icon-only buttons need `aria-label`
- Radix-backed primitives are a11y-correct
- Post-install audit for new primitives

---

## Button defaults to `type="button"`

Native `<button>` without `type=` defaults to `submit`. Inside a form
that auto-submits on any click. The shadcn `Button` primitive MUST
supply a default so downstream callers aren't responsible for remembering:

```tsx
function Button({
  className,
  variant = "default",
  size = "default",
  type,
  asChild = false,
  ...props
}: React.ComponentProps<"button"> &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean
  }) {
  const Comp = asChild ? Slot.Root : "button"
  return (
    <Comp
      data-slot="button"
      type={type ?? "button"}
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  )
}
```

Consumers still override with `<Button type="submit">` for real form
submissions.

**Incorrect** (primitive doesn't default type):

```tsx
function Button({ ...props }: React.ComponentProps<"button">) {
  return <button {...props} />
}
// Every downstream <Button onClick={...}> silently defaults to submit.
```

**Correct**:

```tsx
function Button({ type, ...props }: React.ComponentProps<"button">) {
  return <button type={type ?? "button"} {...props} />
}
```

---

## Label requires consumer-wired association

Shadcn's `Label` wraps Radix's `Label.Root`. Radix handles association
when `htmlFor` is set OR the Label wraps the control. The primitive
can't enforce this — it's the consumer's job.

In AI-generated forms, prefer the `Field` + `FieldLabel` + `useId()`
pattern from `forms.md`. That pattern wires association for you.

If you're using raw `<Label>` without `Field`, always pair with an id:

```tsx
const id = useId()
<Label htmlFor={id}>Email</Label>
<Input id={id} type="email" />
```

---

## Icon-only buttons need `aria-label`

Any `<Button size="icon">` without visible text requires an explicit
`aria-label`:

```tsx
<Button size="icon" aria-label="Close">
  <XIcon />
</Button>
```

Without the label, screen readers announce "button" with no purpose.

---

## Radix-backed primitives are a11y-correct

These are correct by default through Radix — use them instead of rolling
custom clickable/toggleable markup:

- `Checkbox`, `Switch`, `RadioGroup` — correct roles and keyboard handling
- `Dialog`, `Sheet`, `Drawer` — focus trap, Escape handling, `aria-modal`
- `Tooltip`, `HoverCard`, `Popover` — correct roles and dismissal
- `DropdownMenu`, `ContextMenu`, `Menubar` — keyboard nav, roles

---

## Post-install audit for new primitives

After running `npx shadcn@latest add <name>`, audit the generated file:

1. Search the new file for raw `<button>` without `type=`. If found,
   add `type={type ?? "button"}` to the props destructure and
   `type={type}` on the render. (Applies to `Button` and any wrapper
   that renders a `<button>` directly, e.g., `ButtonGroup` items.)
2. Search for `<input>`, `<textarea>`, `<select>` — make sure there's
   a way for the consumer to pass an `id` through (Radix primitives
   and shadcn wrappers generally forward `...props`, but verify).
3. Run `npx --no-install @biomejs/biome lint <path>` on the new file.
4. If the generated code has a11y gaps that can't be fixed at the
   primitive level, document them in a file-top comment so future
   edits know.

This audit is a required step once per project when adopting the CI
pipeline (kit `pipeline.md`).
