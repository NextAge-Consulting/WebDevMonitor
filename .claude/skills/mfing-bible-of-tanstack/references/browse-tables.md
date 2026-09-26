# Browse tables

Distilled from `@tanstack/react-table` v9 skills `getting-started`, `table-state`
and `with-tanstack-query`, plus our decisions. The browse is the spine of a
back-office app; this is how we build one.

## Table renders nothing

It is a state machine that tells you which rows and cells exist. All markup
stays ours — the project's `Table` atoms, toolbar and footer are untouched by
adopting it. Anyone expecting a grid component will be surprised; there is no
styling, no filter UI, no export.

What you get is columns as **data** instead of duplicated markup. Before, an
11-column browse listed its columns twice — once as headers, once as cells —
kept in the same order by hand, with a hardcoded `colSpan` in the empty state.
One array replaces all of that, and `colSpan` becomes `columns.length`.

## Features are opt-in

```ts
const features = tableFeatures({ rowSelectionFeature, columnVisibilityFeature })
const helper = createColumnHelper<typeof features, Row>()
const table = useTable({ features, columns, data })
```

v9 registers only what you name, so a plain browse stays small. Register a
feature when the screen uses it, not preemptively.

**Never `legacyCreateColumnHelper`.** It is the v8 compatibility shim and carries
an open upstream TypeScript defect (`aggregationFn` rejects built-in string
identifiers). New code has no reason to touch it.

## Tell Table which stages it is not running

Paging, sorting and filtering are separate stages, each opt-in. When the rows
handed to Table are already processed — by the server, or by the screen slicing
an array it holds — Table must be told, or it will page the page:

```ts
useTable({ features, columns, data: rows, rowCount, manualPagination: true })
```

`manualPagination` means the rows you were given ARE the page. `rowCount`
supplies the total, which Table cannot derive from rows it never received.
`manualSorting` and `manualFiltering` are the same bargain for those stages.

The bargain does not care WHERE the work happened. A screen holding every row
and slicing it itself is still manual paging, because the slice reached Table
from outside.

Anything upstream that the query owns must be in the **query key**, or changing
a sort will not refetch.

Which lists are paged upstream at all, and by what, is a UI-architecture
decision rather than a Table one — see the project's browse pattern.

## Where paging state lives

Two valid designs, and mixing them is the bug:

- **URL-owned** (our default) — page and size are search params, the footer
  drives them, and Table's pagination feature is *not* registered. One source of
  truth, and the browse stays shareable.
- **Table-owned** — Table holds pagination state in an atom and the query reads
  from it. Correct only for a grid embedded in a larger screen where the page
  number genuinely should not be in the URL.

Never register Table's pagination feature *and* keep page in the URL. They will
disagree, and the symptom is a pager that skips or repeats a page.

## Row identity

Give Table a stable `getRowId` from the record's real id. The default is the
array index, which breaks selection and React reconciliation the moment rows
reorder or one is removed — exactly what happens when a filter changes.

## What each feature is actually for

- **Column visibility / order** — an ERP browse has more columns than fit. This
  plus persistence is the "saved views" feature; the state object Table exposes
  *is* the saved view, which is most of why adopting Table pays.
- **Row selection** — bulk actions. Selection changes what the toolbar contains,
  so plan the toolbar for it rather than bolting it on.
- **Sorting** — Table owns the header state and the toggle cycle. It does not
  write your `ORDER BY`, and it cannot help when a sort column exists on one
  data source and not the other.
- **Virtualization** — only when a screen genuinely cannot page. Paging is the
  better answer for record lists; virtualization is for logs and telemetry.

## Loading

A filter or page change rebuilds the whole grid, so the region gets a skeleton,
not a spinner — see `loading-states.md`. Do not let the toolbar disappear while
the rows reload; the user needs to be able to correct the filter they just
mistyped.
