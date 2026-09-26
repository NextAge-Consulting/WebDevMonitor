---
name: research
description: The ladder for looking something up — library and API documentation, product behaviour, standards, or a conceptual question. Use before composing or explaining a technical solution, when verifying an API signature or field name, when a search came back thin, or when the question is conceptual or non-English. Covers WebSearch, WebFetch, Exa and the ctx7 CLI.
user-invocable: false
---

# Research

Retrieve before composing or explaining a technical solution, and defer to what you
retrieve over prior training. With several libraries in play, retrieve for each.

Climb the tiers in order and stop at the first one that answers the question.

## 0 — this machine

Use the skill that covers the library if one exists; `mfing-bible-of-tanstack` covers
TanStack. Otherwise check what the installed package ships:

```bash
ls node_modules/<pkg>/skills/ node_modules/<pkg>/docs/ 2>/dev/null
```

Read it in the session that needs it and let it go; do not copy it into a reference
file. A topic that keeps recurring gets distilled properly, which is a kit decision.

## 1 — WebSearch

The default for library docs, API semantics, product behaviour and current state. Pin
it to the vendor:

```
WebSearch(query: "...", allowed_domains: ["tanstack.com"])
```

Unpinned, a thinly-documented library returns its issue tracker instead of its docs.

## 2 — WebFetch

Read the page tier 1 found. When a signature, field name, config key or column name
matters, ask for it verbatim:

> "Quote the X section verbatim, including the code example. If it is not present, say so."

## 3 — Exa

**Use this tier only when the `mcp__exa__*` tools are available.** They are absent
unless `EXA_API_KEY` is set. When they are absent, skip to tier 4 and name the case you
could not cover.

Reach for `mcp__exa__web_search_exa` for non-English sources, primary and institutional
documents including PDFs, and conceptual questions with no single doc page to find.

Prefer WebFetch over `crawling_exa` for reading a known URL, and a pinned tier 1 over
`get_code_context_exa` for library documentation.

Set `type: "deep"` only when the human says "deep dive" or "research this".

## 4 — ctx7 CLI

Last resort. Needs no key and no install:

```bash
npx ctx7@latest library "<name>" "<query>"
npx ctx7@latest docs "<libraryId>" "<query>"
```

## Always

When a symbol, table or plugin name will not resolve against the live docs, suspect a
rename and check the project's changelog, releases or upgrade guide.

When a documentation site returns a loading placeholder, ask the question at tier 1
rather than reaching for another fetcher — no fetcher gets past it.

Carry the source URL alongside anything you act on.

Stop when you hold the specific fact you came for. When the tiers run out, say what is
still unknown instead of substituting a guess.
