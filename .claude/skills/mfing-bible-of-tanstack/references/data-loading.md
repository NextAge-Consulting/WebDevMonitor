# Route data loading

Distilled from `@tanstack/router-core` skills `router-core/data-loading` and
`router-core/ssr`, plus our decisions. Router coordinates *when* data loads;
Query owns caching. This file is the seam between them.

## The standard route

```tsx
export const Route = createFileRoute('/_authed/accounting/products/')({
  validateSearch: searchSchema,
  loaderDeps: ({ search }) => search,
  loader: ({ context, deps }) =>
    context.queryClient.ensureQueryData(itemBrowseQuery(toParams(deps))),
  component: ProductBrowse,
})

function ProductBrowse() {
  const search = Route.useSearch()
  const { data } = useSuspenseQuery(itemBrowseQuery(toParams(search)))
}
```

Three things are load-bearing:

- **`loaderDeps`** — without it the loader does not re-run when a search param
  changes, so filtering and paging silently do nothing. Path params are already
  dependencies; **search params are not**, and that asymmetry is the single most
  common data-loading bug.
- **`ensureQueryData`** — prefetch into the same cache the component reads. No
  flash of loading, no request waterfall, and the data is in the SSR payload.
- **One params function** — the loader and the component must produce an
  identical key. Derive it once, use it twice.

## Router settings that make Query the cache

```ts
createRouter({ routeTree, context: { queryClient }, defaultPreloadStaleTime: 0 })
setupRouterSsrQueryIntegration({ router, queryClient })
```

Router keeps its own preload cache, 30 seconds by default, which sits in front
of Query and overrides its freshness rules. `defaultPreloadStaleTime: 0` hands
caching to Query entirely, which is the point of pairing them.

`setupRouterSsrQueryIntegration` (from `@tanstack/react-router-ssr-query`) is the
whole SSR story — it wraps the app in `QueryClientProvider` and handles
dehydrate, hydrate and streaming. Do not hand-roll those options.

## Loaders are isomorphic

A loader runs on the server during SSR and on the client during navigation. It
must be safe in both. In practice: a loader calls server functions and the query
client, and touches nothing else. A database import in a loader is a client
bundle error waiting to happen.

## Route context

`createRootRouteWithContext<{ queryClient: QueryClient }>()` types the context so
every loader gets `context.queryClient` with inference. `beforeLoad` can add to
context — a resolved session, a tenant — and children receive it typed.

Note the double-call form `createRootRouteWithContext<T>()({ ... })`. It is a
factory, not a typo.

## Guards

```ts
beforeLoad: async ({ location }) => {
  const session = await getSessionFn()
  if (!session) throw redirect({ to: '/login', search: { redirect: location.href } })
  return { session }
}
```

Put this on a **pathless layout route** (`_authed.tsx`) so protection is the
default and every screen inherits it. A route added outside that layout is
public — which is almost never intended.

This guards navigation only. Data protection is `requireSession()` inside every
server function, independently.

## Selective SSR

Per route: `ssr: true` (default — render on the server), `ssr: 'data-only'`
(loaders run on the server, the component renders on the client), `ssr: false`
(client only).

For back-office screens behind a login there is no SEO to win, so `'data-only'`
is often the better trade: the data is server-fetched and in the payload, but
you skip server-rendering a heavy interactive grid. Decide per screen; do not
set it globally.

## Deferring slow data

Return a promise from the loader without awaiting it and the route renders
immediately, streaming that piece in when it resolves. Read it with `<Await>`.

Worth it when one panel on a record screen is markedly slower than the rest — an
attachment list, an audit trail. Not worth it for the record's own fields; a
record that renders in pieces reads as broken.

## Errors

`errorComponent` per route, `notFoundComponent` for missing records. When using
Query with suspense, reset the error boundary with `useQueryErrorResetBoundary`
in the error component, or a retry will re-throw the cached error instead of
refetching.
