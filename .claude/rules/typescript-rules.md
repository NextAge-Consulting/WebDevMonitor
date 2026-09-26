---
paths: "**/*.{ts,tsx,mts,cts}"
---

# TypeScript Rules

Loaded when editing TypeScript. Universal rules live in `constitution.md`. Frontend rules live here, because the stack is TanStack + Astro and frontend means TS.

## I. TypeScript Quality (Zero Tolerance)

**Commit no TypeScript errors.** The pre-commit hook enforces it, LSP diagnostics are authoritative (constitution §IX), and a TS error is a compilation failure rather than a suggestion.

Delete dead code rather than renaming it `_unusedVar`. Give values real types rather than `: any` or `as any`, and fix the underlying issue rather than writing `// @ts-ignore`.

TS6133 and TS6192 mean an unused declaration — delete it, after checking for indirect usage. TS7006 needs a type. TS2339 needs the type definition fixed. TS2322 needs fixing at the source of the mismatch.

## II. Logging

**Use Pino.** A PreToolUse hook blocks `console.log`, `.error`, `.warn`, `.info` and `.debug` everywhere.

```typescript
import { logger } from '~/lib/logger';
logger.info('message');
logger.error({ err }, 'error message');
logger.debug({ data }, 'debug context');
```

Watch it with `tail -f logs/server.log`. Server lifecycle is governed by `dev-server.md`.

**The logger detects its own environment, once, so one import works on both tiers.** The hook blocks `console.*` in React components and browser hooks too, so a server-only logger strands the first client-side error handler — and every way out from there is wrong. Pino has a browser build.

```typescript
import pino from 'pino';

const isServer = typeof (globalThis as Record<string, unknown>).window === 'undefined';

function buildTransport() {
  if (!isServer) return undefined;   // browser: no transport, falls back to console
  // …server transports (pino-pretty in dev, file/stdout in prod)…
}

export const logger = pino({ level: process.env.LOG_LEVEL ?? 'info', transport: buildTransport() });
```

A bare `pino({ level })` inside an app is not enough — imported from a component it tries to build a server transport in the browser. Put the environment check in the logger.

Client-side logging is not optional. A browser `catch` that neither surfaces to the user nor logs is a swallowed error (constitution §X). A logger that client code cannot reach is a defect in the logger.

Where the logger lives is a project choice — usually a shared workspace, since both tiers import it.

## III. Naming

`camelCase` for variables, `PascalCase` for types and classes. Underscores never separate words.

## IV. Timezone-Aware Code — TS Patterns

Constitution §VI carries the principle. In TypeScript:

Use a timezone-aware library (date-fns-tz, Luxon, Temporal once stable) rather than a bare `new Date()` in user-facing logic. Format display through a timezone-aware formatter with the user's timezone rather than `.toISOString()` or `.toLocaleDateString()`. Normalize to one timezone before comparing dates via `getTime()`.

The carve-out mirrors §VI: `new Date()` is right for columns capturing the absolute instant a row was written — `createdat`, `updatedat`, session bookkeeping — that are never displayed and never filtered by local-timezone ranges. If a change starts displaying such a column or filtering it by a local date range, that change migrates the column onto a timezone-aware path.

## V. Server-Side Static Assets

**Resolve runtime file reads through `process.cwd()`**, e.g. `resolve(process.cwd(), 'server-assets/email/template.html')`. Bundlers rewrite `import.meta.url` and do not copy the referenced files into the build, so it fails silently in production.

Runtime-loaded assets — templates, images, PDFs — go in `server-assets/` at the app root, never inside `src/`. Add a `COPY` for `server-assets/` to the Dockerfile if one is not already there, or the files are absent from the production image.

## VI. Boolean Assignment

Wrap a chained `&&` assignment in `!!()` so it stores `true` or `false` rather than the last truthy value:

```typescript
const isValid = !!(user && user.email && user.verified);
```

## VII. Contextual Feedback, Not Toasts

Replace a success toast with an inline state change or optimistic UI; an error toast with an inline message, form-level error, or modal; a warning toast with an inline indicator; a loading toast with a spinner in the component. Clipboard-copy confirmation is the one exception.

When you edit a file that still has toasts, migrate them.

## VIII. Web Standards

Give every icon-only button a hover tooltip.

Consider responsive impact across mobile, tablet and desktop on any UI change: horizontal space on mobile, text overflow and wrapping, touch targets of at least 44px, how grid and flex layouts shift, and the `sm:` / `md:` / `lg:` / `xl:` breakpoints.

Style with Tailwind, build from `shadcn/ui` primitives, and follow the `shadcn` skill for component patterns. Name semantically (`ButtonActive`, not `ButtonRed`), prefer semantic classes like `text-foreground` over hand-written dark mode, and join conditional classes with `cn()`.

## IX. Code Standards

Write TypeScript, and write components as functions with hooks rather than classes.

## X. Setup and Commands

TypeScript LSP needs both Claude Code's official plugin and the language server binary (constitution §IX). One-time per machine:

```bash
/plugin install typescript-lsp@claude-plugins-official
npm install -g typescript typescript-language-server
```

Verify with `which typescript-language-server` returning a path and `/plugin list` showing `typescript-lsp`. With either missing, LSP for TS is dead — fall back to `tsc`.

The CLI always works: `npm run check-types` (typecheck via local `tsc`), `tsc --noEmit` directly, and `npm run dev` for the development server.
