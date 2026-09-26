# Loading states

Ours, drawn from primary design-system sources: NN/g, Primer, Siemens Element,
Octopus, Bifrost, Salesforce, Utah. The thresholds are consistent across all of
them.

## The ladder

| Expected wait | Show |
|---|---|
| under ~1s | **nothing** |
| 1–3s | indeterminate — spinner or skeleton |
| 3–10s | determinate — progress bar |
| 10s+ | run it in the background, let the user keep working, notify on completion |

**Both ends of this are rules.** Showing an indicator below a second is not
harmless caution: it appears and vanishes within a couple of frames, reads as a
glitch, and measurably makes an app feel *slower*. Showing nothing above a
second is equally wrong — the click looks like it did not register, and the user
clicks again.

Which end bites depends entirely on the backend. A screen backed by a local
database lives under the threshold and should stay silent. A screen backed by a
slow third-party API lives above it and must not.

## Which indicator

Duration picks the tier; **shape** picks the indicator.

- **A region is being rebuilt and its layout is known** — a browse reloading
  after a filter or page change. Use a **skeleton** in the shape of the content.
  It holds the layout so nothing jumps, and it says what is coming rather than
  merely that something is.
- **A control triggered slow work** — Save, Close, Post, Approve. Use a
  **spinner on that control**, where the user just clicked. Spinners belong on
  actions, not on pages.
- **The whole route is changing** — a global top-of-page bar is acceptable, but
  prefer skeletons in the content area. A full-page spinner blocks everything
  and causes a layout jump when it clears.

Do not mix the two in one region at the same time.

## Anti-flash gating is not optional

The same control can be fast or slow depending on cache state. Without gating,
half the interactions flash an indicator for two frames — which is precisely the
under-1s failure above.

Gate every indicator: do not show it until roughly 200ms have passed, and once
shown hold it for roughly 400ms minimum. Fast responses show nothing; slow ones
never blink.

This is one shared hook, not a per-screen decision.

## Busy, not disabled

A control performing work goes to a **busy** state — spinner, label unchanged,
still focusable. Do **not** set `disabled`: a disabled control is removed from
the accessibility tree, so a screen-reader user loses it mid-action.

Reserve the spinner's slot in the layout so the control does not change size when
it appears.

`disabled` remains correct for *unavailable*, which is a different thing —
nothing to save, no permission, wrong record status.

## Where this interacts with Router and Query

Router will render a route-level pending component during a loader. That is the
wrong granularity for a filter change on a browse: the whole screen blanks,
including the toolbar holding the filter the user just mistyped.

So keep the route pending component off for browse routes and put the indicator
on the region instead. The toolbar stays live throughout.

**Which signal drives it depends on who triggered the fetch**, and getting this
wrong means an indicator that never appears:

- **Loader-driven** (a filter or page change — our default for browses). The
  router holds the current page rendered while the loader runs, and the new data
  is a *different* query key, so the visible query's `isFetching` never goes
  true. Use the router's navigation state:
  `useRouterState({ select: (s) => s.isLoading })`.
- **Component-driven** (a query fired from the component, not a route change).
  That query's own `isFetching` is the signal.

Gate either one with the anti-flash hook.

`useSuspenseQuery` has no `placeholderData`, so `keepPreviousData` is not
available on the loader-driven path. It does not need to be: `ensureQueryData` in
the loader means Router holds the current page rendered until the next page's
data has arrived. Client-driven paging that does not change the route is the only
case for `useQuery` + `keepPreviousData`.

## Never claim progress you cannot measure

A determinate bar against a third-party API is a lie — nothing reports percent
complete. Stay indeterminate unless the work genuinely reports progress, such as
a chunked upload.
