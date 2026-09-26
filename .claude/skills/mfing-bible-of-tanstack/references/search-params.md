# Search params as screen state

Distilled from `@tanstack/router-core` skills `router-core/search-params` and its
`validation-patterns` reference, plus our decisions.

For back-office apps this is not a routing detail — it is where a browse keeps
its state. Filters, page, page size and sort live in the URL so a screen can be
bookmarked, pasted into a ticket, reopened after a refresh, and reached by the
back button. A browse whose page number lives in `useState` is a browse nobody
can share.

## Validate, don't parse

```ts
const searchSchema = z.object({
  q: z.coerce.string().optional(),
  page: z.coerce.number().int().min(1).optional(),
  size: z.coerce.number().int().optional(),
  inactive: z.boolean().optional(),
})

export const Route = createFileRoute('/…')({ validateSearch: searchSchema })
```

Then `Route.useSearch()` is fully typed and `navigate({ search })` is checked.

## `z.coerce` on anything a user can type

**TanStack parses search params by inferred type.** `?q=1234` arrives as the
number `1234`, not the string `"1234"`. A plain `z.string()` then throws and
takes the whole screen down with an error page.

In an ERP that is not an edge case — SKUs, part numbers, work-order numbers and
invoice numbers are routinely all digits. **Any text field a user can type a
number into gets `z.coerce.string()`.** The same applies in reverse to numeric
params arriving as strings from a hand-edited URL.

## Filter changes reset the page

```ts
navigate({ search: (prev) => ({ ...prev, page: undefined, ...next }) })
```

Page 7 of one result set is not page 7 of another. Always drop `page` when a
filter changes, or the user lands on an empty page and thinks the filter is
broken.

## `replace` for restorations, not for intent

Use `replace: true` when writing a param the user did not ask for — restoring a
remembered page size, refitting to the viewport. Those must not litter history.

Use a normal push for anything the user did — searching, filtering, paging — so
the back button returns to the previous result set, which is what they expect.

## Omit defaults

Leave a param out of the URL when it holds its default value. `?page=1&size=25`
on a freshly-opened screen is noise, and it makes a shared link look
deliberately configured when it isn't.

## Keep the param shape flat

Params are a query string. Flat scalars survive a copy-paste, a redirect and a
log line; nested objects encode into something unreadable and awkward to hand-
edit. If a screen's state genuinely needs structure, that is a signal it belongs
in a saved view stored server-side, keyed by a single id in the URL.
