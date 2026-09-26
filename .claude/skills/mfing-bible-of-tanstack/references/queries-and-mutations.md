# Queries and mutations

**TanStack ships no Query skill** — verified zero `SKILL.md` files across
`query-core`, `react-query` and the whole `TanStack/query` repo. A draft PR
(#10879) would add 29 of them in a new `@tanstack/query-intent` package; until
it lands this file is entirely ours.

## One definition per resource

The loader prefetches and the component reads. They share **one** object, so the
cache key cannot drift:

```ts
export const itemBrowseQuery = (params: ItemBrowseParams) =>
  queryOptions({
    queryKey: ['item', 'browse', params] as const,
    queryFn: () => getItemBrowse({ data: params }),
  })
```

Writing the key in both places is how you get a permanent loading flash nobody
can reproduce: the loader warms `{page: 1}` and the component subscribes to
`{page: '1'}`.

**Every server-owned slice belongs in the key.** Page, size, search, filters,
sort. If it changes what the server returns, it is part of the key. Anything
that only affects rendering — a column's visibility, an expanded row — does not.

## Freshness is configured once

Business screens must show current data without the user reloading, so the
QueryClient carries the posture and every screen inherits it:

```ts
defaultOptions: { queries: { staleTime: 30_000, refetchOnWindowFocus: true, retry: 1 } }
```

Override per-query only where the requirement genuinely differs. Money and stock
read at the point of an action want `staleTime: 0`. Reference data that changes
monthly wants minutes. Most screens want neither.

## Invalidate by key, never by router

After a mutation, invalidate the keys the mutation actually affected:

```ts
onSuccess: () => queryClient.invalidateQueries({ queryKey: ['item', 'browse'] })
```

`router.invalidate()` refetches **every active loader on the page** to fix one
list. On a screen with a browse, a nav tree and a shell query that is four round
trips to repair one — and against a slow upstream like QuickBooks the user sees
all four.

Keep the key prefixes in one exported object so a mutation cannot invent a
prefix that no query uses. A typo'd invalidation is silent: nothing refetches
and the screen is stale.

When the server returns the updated record, `setQueryData` it instead of
invalidating — one fewer round trip and no window where the cache is knowingly
wrong.

## Optimistic updates

**`invalidateQueries` is the LAST answer, not the first.** Ask what the mutation
does on success in this order: the server returned the saved row, so write it into
the cache; the change is predictable, so apply it optimistically; only then, the
server computes a value you cannot, so invalidate — and say in a comment which value
that is.

The framing matters. Written the other way round — "reach for optimism when
something should feel instant" — it reads as a special case, and the default that
fills in behind it is a refetch. On one project 17 of 24 mutations shipped that way,
including five deletes, before anyone measured what it cost.

For anything the client can predict — a removal, a star, a toggle, a reorder — write
the cache immediately and roll back on failure:

```ts
onMutate: async (key) => {
  await queryClient.cancelQueries({ queryKey })      // stop an in-flight refetch
  const previous = queryClient.getQueryData(queryKey)  //   landing on top of us
  queryClient.setQueryData(queryKey, optimistic(previous, key))
  return { previous }
},
onError: (_e, _v, ctx) => queryClient.setQueryData(queryKey, ctx?.previous),
onSuccess: (server) => queryClient.setQueryData(queryKey, server),
```

The `cancelQueries` line is the one people drop, and its absence is a race that
only shows up under load: a refetch started before the mutation resolves after
it, and silently restores the old value.

**Rolling back is not enough.** The user must be told it failed, or they will
believe the optimistic value (constitution §X). Surface `mutation.error` in the
UI, not just the log.

## Not against a write the client cannot predict the outcome of

Optimistic updates assume the server will almost certainly agree. That holds for
a star or a reorder. It does not hold for a write to a third-party system of
record, and there the pattern inverts: **busy state, then the real result.**

The test is whether the client can know the write will succeed. It cannot when:

- **A concurrency token is owned elsewhere.** The upstream rejects a write
  carrying a stale version/sync token, and the token goes stale from edits made
  in the other system — which this app never sees.
- **Validation lives upstream and is not mirrored.** Rules the client has no
  copy of, and cannot evaluate.
- **Another party may have changed the record**, in a UI this app does not own.

Rolling a failure back is not free. A value that appears saved and silently
reverts a second later is worse than a spinner that never lied — and against a
slow upstream the revert lands long after the user has moved on.

Whether a given integration falls in this bucket is a project fact, so the
project's own rules name it. The generic guidance stops here.

## Suspense vs plain queries

`useSuspenseQuery` for anything the route loader prefetched — data is guaranteed
present, `data` is non-nullable, no loading branch in the component.

`useQuery` for anything fetched *after* render on user action — a type-ahead
lookup, a panel opened on demand. Those need `enabled` so an empty term never
fetches, and they are the only place `placeholderData: keepPreviousData` applies
(`useSuspenseQuery` omits that option from its type entirely).

## A dead session must bounce, even with no navigation

A route guard only re-checks on navigation. An already-open screen with an
expired session keeps showing authed UI while every query quietly fails — the
user sits looking at stale data that will not refresh, and nothing tells them
why.

Worse, when a server function throws a router `redirect()` from inside a
`queryFn`, the redirect does not navigate. Query treats it as a result and caches
it, so the query is now poisoned with a redirect where its data should be.

Handle it centrally on the QueryClient, not per query:

```ts
new QueryClient({
  queryCache: new QueryCache({ onError: (err) => reissueRedirect(err) }),
  mutationCache: new MutationCache({ onError: (err) => reissueRedirect(err) }),
})
```

`reissueRedirect` detects a serialized router redirect and re-issues it
client-side. One place, every query and mutation covered.

## Per-request QueryClient

Create it inside the router factory, never at module scope. A module-level
client is shared across SSR requests and leaks one user's cached data into
another's render. In a multi-tenant app that is a cross-tenant leak.
