# MFing Bible of TanStack — skill README

House rules for TanStack Start, Router, Query, Table and Form, plus a curated set
of upstream reference docs.

**The index of what is here lives in `SKILL.md`, not in this file.** A second copy
of the file list is a second thing to keep in step, and it is what made the
previous version of this README wrong.

## How it is structured

Progressive disclosure, three levels:

1. **Discovery** — the `name` + `description` frontmatter, always in context.
2. **Activation** — `SKILL.md`, loaded when a task touches TanStack. House
   doctrine and the reference index.
3. **On demand** — a file under `references/`, read only when the task needs it.

## Two kinds of reference file

**Vendored (marked ⇩ in the index).** Copied verbatim from the `SKILL.md` files
TanStack ships inside its npm packages, with a provenance header naming the
source package, version and vendor date. **Never hand-edit one** — the kit's
`/review-stack` overwrites it on refresh, and your edit is lost.

**House.** Written and maintained by us, covering what upstream does not: the
Query patterns, house auth, the Hono production server, our accumulated traps.
TanStack ships no Query or Form skills at all, so that guidance has no upstream
to refresh from and is entirely ours.

## Maintenance

Which docs are vendored, from where, and which versions are blessed is recorded
in `.claude/stack-manifest.json`. `scripts/check-stack.mjs` enforces the
version pins, the banned form libraries, the per-app form decision, and that
every reference the manifest names is actually present — CI job
`stack-standard`.

Refreshing the vendored set, reviewing the house docs against upstream changes,
and deciding version bumps are all the kit maintainer's `/review-stack`. None
of it happens in a consumer project.
