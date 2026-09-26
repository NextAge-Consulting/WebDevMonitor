# Constitution

Global, language-agnostic rules. Language-specific rules — TypeScript and frontend quality, Python quality, framework patterns — live in `typescript-rules.md` and `python-rules.md`, loaded by path targeting.

## II. Questions Before Code

When asked a question, answer it first. Investigating the codebase, researching, and reading files are all fine; writing or changing code in response to a question is not. Until the question is answered and the human gives direction, any code is guesswork.

Exception: they said "do it", "implement this", or "fix that bug".

## III. Security

Secrets live in environment variables — never hardcoded, and never overwritten without explicit consent. Schema changes (`DROP`, `ALTER`, `CREATE`) need approval. Error messages stay free of internal detail.

## IV. Early Development Philosophy

No backward compatibility — prefer a breaking change to technical debt. Complete replacement over gradual migration, deprecated code dropped entirely after migrating, no compatibility layers, one source of truth.

## V. Database & Naming

Tables are singular (`user`, not `users`). Primary keys are `{table}id`. Foreign keys match the parent primary key's name. Database fields are lowercase. Use the real database names in code — `contact`, not `prospect`. Language-specific variable casing lives in the language rule files. The id's storage type and generation strategy are engine-specific — see the engine rule file.

## VI. Timezone-Aware Code (Zero Tolerance)

Before writing any code that touches time, ask what timezone it is stored in and what timezone the consumer expects.

Match your query boundaries to your storage format. Data stored in local time is queried in that same local time; data stored in UTC is converted to local before any user-facing display or filtering. Mixing the two creates silent mid-day cutoffs that show users the wrong data.

Specify a timezone explicitly every time. Derive "today" from a timezone-aware now, and pass explicit dates in the correct timezone to APIs. This covers database queries, API calls, date filtering, log display, scheduling, status lines, summaries and check-ins.

The carve-out is absolute-instant audit fields: `new Date()` is right for session bookkeeping and columns like `createdat` / `updatedat` that are never shown to a user and never filtered by a local-timezone boundary.

## VII. Debugging Protocol

New code is guilty until proven innocent. Check code from the last session or PR first; production code that has run for weeks is probably correct.

Reproduce it minimally, isolate the failing component, trace to the root cause rather than the symptom, fix with verification, then add a test that catches the regression.

## VIII. Code Standards

Production code never imports from `docs/`, `specs/`, or `project-documentation/`. Validation lives inline in production code, never imported from spec files. Test against real APIs, not mocks.

## IX. LSP Tool Usage

LSP activates for a language only when both the official code-intelligence plugin is installed (`typescript-lsp`, `pyright-lsp`, `swift-lsp` from the official marketplace) and the language server binary is on PATH (`typescript-language-server`, `pyright-langserver`). Verify both before relying on it; otherwise use the language CLI diagnostics.

Use LSP for type-aware queries — `goToDefinition`, `findReferences`, `hover`, `documentSymbol`, `workspaceSymbol`, `goToImplementation`, `incomingCalls`, `outgoingCalls`. Use Grep for text patterns. Use the language CLI (`tsc`, `pyright`, `ruff`) for diagnostics: it is the guaranteed path and what pre-commit and CI run.

Every diagnostic, LSP or CLI, is authoritative. Resolve all of them before claiming work done — every one you saw, not only those in files you edited (§XII).

## X. Fail Fast, Fail Loud (Zero Tolerance)

When writing anything that can fail, the first question is how the user will know it failed. If the answer is that they won't, the code is wrong.

Trace the full path from error to user visibility. Each of these is a swallowed error: a handler that sets state nobody renders, a `catch` that only logs, an error variable with no UI, a `try` that returns a default value, a mutation error handler whose condition never matches the display. Let it throw or show an error state.

**Log the full detail and show the user a general statement — both.** Log-only is correct only when the failure genuinely does not affect what the user is doing or seeing.

What the user sees names the system and the impact, never the cause: no error text, status codes, credential state, stack traces, or internal identifiers. "Couldn't reach QuickBooks, so the file list can't be shown," not the 401. "Trouble saving — your changes weren't applied," not the constraint violation. "That upload didn't go through," not the bucket name.

An empty state is not an error state. A failed lookup rendered as an empty list tells the user the thing does not exist — and a missing certificate and an unreachable server look identical that way.

When reviewing, check every `onError`, `catch`, `.catch()` and `except` for a path to the user.

**The same rule governs ORDINARY screen copy, not just failures.** A label, hint,
description or empty-state is read by whoever opens the screen, so it never names
a table, column, class, environment variable, internal system or product the user
does not otherwise see. "Making someone inactive removes their access to every
application" — not the column that stores it, and not the names of the other
applications.

This is the one that slips through, because a helpful hint feels like
documentation rather than output. It is output. A field hint reading
`This is the legacy UserInfo.Status` hands a reader the schema, the fact that
another system reads it, and that system's name — from a screen, permanently, to
everyone who can open it. Explaining the mechanism is what the code comment and
the project docs are for; the screen gets the effect.

Say what the control DOES and what changes when you use it. If a sentence would
only make sense to someone who has read the codebase, it belongs in the codebase.

**And the test for a LABEL: could this drift as the system grows?** If yes, it is
the wrong label. "Security" survives; "What this person may do in backoffice"
names one application out of the many that will exist, and nobody ever comes back
to correct a label that still technically renders. The same goes for anything
describing how much is built yet — "applies as screens are converted" is a
sentence with an expiry date on a screen that has no release process for prose.

Name the thing, not the moment. A label that would need editing after the next
piece of work lands is a maintenance task you just created and will not do.


## XI. Best Solution, Not Quick Solution (Zero Tolerance)

Implement the canonical, officially-documented, future-proof approach. Research it against the official docs before choosing — the `research` skill carries the ladder — and pick a pattern for correctness rather than for how fast it is to type.

Eliminate workarounds rather than documenting them — an undocumented workaround gets read as the intended design by the next reader. When a rewrite is the correct end state, lead with it and its real cost; verify any blocker you would use to argue for something smaller against the actual code.

This shop is 100% AI-dev, so a hacky choice compounds across thousands of future AI-driven changes.

## XII. Own All Errors (Zero Tolerance)

Own every defect you find — an error, broken test, LSP diagnostic, or lint warning — whether or not your changes caused it, and fix it inside this body of work.

Naming a defect precisely enough to write it down means you already have what you need to fix it. There is no "surface it instead", no "propose a fix", no "raise it for a separate PR". Relatedness is not a scope test: "unrelated to this change" is a statement about lineage, and lineage was never the question.

Fix the failing test rather than skipping it. Resolve every diagnostic in a file you touched. Finish a half-done state rather than leaving it for the next session. Leave a `TODO` only at the human's express direction, or as the `// TODO(signature-mismatch)` §XIV calls for.

The codebase is never worse after your session than before it.

## XIII. Suppression Discipline (Zero Tolerance)

A linter suppression is the last resort. Before writing `biome-ignore`, `nosemgrep`, `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, or a per-file disable:

1. **Look for the cheap refactor that makes the rule pass** — often 2–10 lines. `<style dangerouslySetInnerHTML>` becomes `<style>{css}</style>`. A `<div onClick>` backdrop becomes a full-screen `<button>`. `key={i}` becomes the real database id surfaced through the query. `process.env.FOO!` becomes an explicit throw.
2. **Look for the primitive-level fix.** A rule firing across many call sites usually means one primitive is wrong — a `Button` defaulting to `type="button"` eliminates every downstream hit.
3. **Only then** consider whether the rule genuinely does not apply at this site.

A suppression comment names the specific mechanism that makes the rule's concern irrelevant there — "input passed through sanitizeHtml", never "false positive" or "safe". Each suppression is per-site: copy the code, re-prove the reason.

Fix the primitive or fix the sites rather than downgrading a rule project-wide, which loses the signal for new code.

## XIV. Signature Changes (Zero Tolerance)

When you change the shape of an exported or cross-module symbol, reconcile every caller in the same change.

**Where the type system can see it** — a TS/TSX signature, an exported type, interface or enum, a Zod schema consumed as a type — the compiler is the caller scan. Run the project type-check and attest it once in the PR body:

> `Signature changes: type-checked clean — the compiler reconciles every type-visible caller.`

Write no per-symbol reference counts for these. A count is unfalsifiable, adds nothing the compiler already guaranteed, and treating its presence as satisfaction turns the rule into theatre.

**Where the compiler is blind**, a change compiles green and breaks at runtime. These seams are the real bug surface:

- Database, schema or Zod field renames referenced by string key.
- Raw-SQL column and table names, including field names carried inside JSON/JSONB blobs.
- String-keyed dispatch — event names, action-type strings, `obj[key]`, route paths, query-key arrays.
- Cross-process, RPC, serverFn or webhook payload shapes where producer and consumer type-check independently.
- Cross-language boundaries, such as a Python worker reading a renamed column.

For these, ripgrep the string across the whole repository including non-TS consumers (`.sql`, `.py`, config, other apps), reconcile each site, and enumerate them `file:line` in the PR body:

> `Callers scanned: <symbol> → apps/x/foo.ts:42, apps/y/bar.ts:88 (compiler-blind: raw-SQL column rename).`

Zero external callers still gets a line, naming the file. List only sites you actually opened — the list is auditable against the diff. A caller that genuinely cannot be reconciled in this PR gets a `// TODO(signature-mismatch): <why>, PR #N` and a line in the PR body, never a silent break.

## XV. Documentation Is Present-Tense (Zero Tolerance)

Reference and operational docs describe only what is true right now. Before writing any sentence naming a workflow, script, field, flag or pattern, ask whether it exists and behaves that way today.

When you remove or change something, scrub every reference to zero. Never leave a note about what the thing was, what replaced it, or that it was deleted — naming a dead thing to say it is dead resurrects it, because a skimmer reads the name as live and acts on it. Silence is strictly safer.

Cut a removed feature's section rather than keeping it for reference; git history is the archive. Mark planned work explicitly as not-yet-built rather than describing it as live behaviour.

The carve-out is a doc whose purpose is to explain a decision's evolution — an ADR, a `changelog.md`, a deferred-work spec. There the history is the current content. Everywhere else, present tense only.
