---
name: e2e-author
description: Author and maintain the plain-English E2E flow files that the `/e2e` skill runs. Use when creating a new flow for an app/route, or updating a stale flow after a UI change. Carries the flow-file format, the frontmatter spec, and the agent-browser recipes that keep biting during runs (off-screen click won't fire, env values with spaces truncate, mouse-move arg split, viewport, OTP retrieval). This is the WRITING companion to the RUNNING skill (`e2e`). Triggers: "write an e2e flow", "add e2e coverage for <app>", "the <flow> is stale, update it", "/e2e-author".
allowed-tools: Bash(agent-browser:*), Bash(npx agent-browser:*), Bash(lsof:*), Bash(grep:*), Bash(cut:*), Read, Glob, Grep, Write, Edit
---

# /e2e-author — write & maintain E2E flow files

## What this is

The **writing** half of the E2E model. `/e2e` *runs* flows; this skill *authors and maintains* them. A "flow" is a plain-English markdown file with YAML frontmatter — no Playwright spec, no assertions. When you build a new flow or a UI change makes an existing flow stale, do it through here so the flow lands in the right shape and doesn't re-hit the agent-browser potholes that bit the last run.

The model is locked (kit `pipeline.md` §1.5): **no Playwright, no Stagehand, no scripted suite.** Flows are read and driven by Claude. So a good flow file is one a fresh Claude can execute without guessing.

## When to use

- **New coverage** — an app or route has no flow (e.g. a portal that shipped without one).
- **Drift repair** — the UI changed and an existing flow's steps/selectors/creds are stale. This is the most common case and the reason the skill exists: flows only run occasionally, so drift accumulates silently until the next run.
- **Recipe rot** — a run kept failing on an automation gotcha (not a product bug); fix the flow's recipe and, if it's a new class, add it to the Recipe library below.

## Flow-file anatomy

Files live in `apps/shared/test/e2e/*.md` (monorepo-with-shared, the default) or `test/e2e/*.md` (flat). One flow per file.

```markdown
---
name: my-happy-path-login          # stable slug — how /e2e <name> targets it
app: my                            # short label for logs / report
port: 3020                         # localhost port the flow expects
requires-auth: true                # loads TEST_<APP>_* creds before running
triggers:                          # globs — if the PR diff hits one, flow is in-scope
  - "apps/my/src/routes/login.tsx"
  - "apps/my/src/lib/auth/**"
  - "apps/shared/src/auth/**"
---
# <App> <flow> — one-line intent

## Preconditions
- <app> dev server on :<port> (see `.claude/rules/dev-server.md`)
- Which TEST_<APP>_* env vars this flow reads (list them — the runner checks)
- Any DB state assumed (seeded account, password NULL for OTP, etc.)

## Steps
### Setup
1. `agent-browser --headed open http://localhost:<port>/...`
2. `agent-browser set viewport 1440 900`
3. `agent-browser wait --load networkidle`
4. clear storage/cookies if the flow needs a clean session
5. `agent-browser snapshot -i`

### <Section — Render / Auth / Checkout / …>
6. <plain-English step + what proves it passed>
...

## Failure indicators
- Blank page, console errors, missing header/footer, element the runner can't find,
  visible form error, unexpected 404, mangled layout
```

**Frontmatter rules (all required):**
- `name` — stable slug; never rename casually (it's how `/e2e <name>` and `triggers` scoping key in).
- `app` — short label.
- `port` — the port the flow drives.
- `requires-auth` — bool. `true` → the runner loads `TEST_<APP>_EMAIL` / `_PASSWORD` (or the flow's named vars) from `.env` and aborts loud if missing.
- `triggers` — glob list. Keep them tight to what the flow actually exercises PLUS the shared seams it depends on (`apps/shared/src/auth/**`, `package.json`, `package-lock.json`). Too-broad triggers run the flow on every diff; too-narrow skips it when it should run.

## Recipe library — the agent-browser potholes (bake these into flows)

These are automation gotchas, not project facts. They recur across flows and projects, so they live here once. When a flow touches one of these situations, write the recipe form — not the naive form.

### R1. Off-screen buttons — click silently no-ops
`agent-browser click <ref>` (Playwright underneath) does **not** auto-scroll a button below the fold at 1440×900. It reports `✓ Done` but dispatches nothing. Add-to-Cart, Proceed-to-Checkout, Continue-to-Shipping all sit below the fold. Canonical pattern that actually fires:

```bash
agent-browser eval '(() => { const b = Array.from(document.querySelectorAll("button")).find(x => x.textContent.trim() === "Add to Cart"); b.scrollIntoView({block:"center"}); b.click(); return "clicked"; })()'
```

Use this for any full-page / below-the-fold button. (This is also the #1 debug move when a click "succeeds" but nothing happens.)

### R2. Env values with spaces — truncate under the naive loader
`eval "$(grep ... .env | sed 's/^/export /')"` chops values at the first space: `"Sunrise Beach"` → `Sunrise`, `"Test User"` → `Test`. Always load with `cut -d= -f2-`:

```bash
TEST_SHOP_CUSTOMER_CITY=$(grep '^TEST_SHOP_CUSTOMER_CITY=' .env | cut -d= -f2-)
```

Put a "Loading env vars" block in Preconditions using this form for every var the flow reads.

### R3. `mouse move` — pass x and y as two args, not one string
An eval returning `"<x> <y>"` reaches `agent-browser mouse move "$XY"` as a single arg and errors `Usage: mouse move <x> <y>`. Split into two evals:

```bash
CARD_X=$(agent-browser eval '(() => { ...; return Math.round(r.x + 50); })()' | tail -1 | tr -d '"')
CARD_Y=$(agent-browser eval '(() => { ...; return Math.round(r.y + 105); })()' | tail -1 | tr -d '"')
agent-browser mouse move $CARD_X $CARD_Y
```

### R4. Viewport is 1440×900 (not 1920×1080)
Per `.claude/rules/integrations/agent-browser.md` (the canonical source): fits an MBA 13" builtin, stays above responsive breakpoints. Every flow's Setup sets `agent-browser set viewport 1440 900`.

### R5. Cross-origin iframes (Stripe, reCAPTCHA) — `find` can't traverse them
`agent-browser find` doesn't enter cross-origin iframes. For Stripe PaymentElement: get the iframe rect via `eval`, then click at `(rect.x + fixed_offset, rect.y + fixed_offset)` with `mouse move`/`down`/`up`, then `keyboard type` (Stripe auto-advances fields). Internal offsets are viewport-independent — do not scale X by viewport. See the agent-browser rule for the full recipe.

### R6. OTP retrieval — from the DB/logs, never an inbox
OTP flows read the code from the `authverification` table (or server logs), not IMAP. A my-app OTP signup creates a customer with `password = NULL` (passwordless) — that row is what a shop-OTP flow needs. Document the retrieval query in the flow's Preconditions.

### R7. Clearing the session — `document.cookie` does NOT sign you out
The session cookie is `httpOnly`, so JavaScript cannot see or delete it. The familiar
loop is a no-op against auth:

```bash
# WRONG — clears nothing that matters; you stay signed in
agent-browser eval 'document.cookie.split(";").forEach(c => { document.cookie = c.replace(/^ +/, "").replace(/=.*/, "=;expires=" + new Date().toUTCString() + ";path=/"); })'
```

Use the browser-level clear, then PROVE it before relying on it — a flow that silently
runs signed-in tests the wrong variant of the page (an anonymous `/register` renders the
in-app form instead, and every "logged out" assertion after it is meaningless):

```bash
agent-browser eval 'localStorage.clear(); sessionStorage.clear()'
agent-browser cookies clear
agent-browser eval 'fetch("/api/auth/get-session",{credentials:"include"}).then(r=>r.json()).then(d=>JSON.stringify({hasUser:!!d?.user}))'
# expect hasUser:false
```

The app's own sign-out (account menu → Log Off) works too and is closer to what a user does.

**Localhost caveat — sessions bleed across ports.** Cookies are host-scoped, not
port-scoped, so apps on `localhost:3001` and `localhost:3020` sharing an auth secret
share a session: signing into one silently authenticates the other. A cross-app login
flow MUST clear at the browser level between the two halves or it is not testing a login
at all. (Production uses separate subdomains, so the bleed is dev-only.)

### R8. `fill` by ref fails on re-rendering forms — use the React-safe setter
`snapshot -i` hands out refs (`e12`), but a controlled React form that re-renders between
the snapshot and the fill invalidates them. `fill` then reports `✓ Done` against a stale
node and the field stays empty — a silent no-op that looks like a wrong password.

Set the value through the native setter and dispatch the event React listens for:

```bash
agent-browser eval '(() => {
  const set = (el, v) => {
    const s = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
    s.call(el, v);                                    // bypasses React value tracking
    el.dispatchEvent(new Event("input", { bubbles: true }));
  };
  set(document.querySelector("input[type=email]"), "user@example.com");
  set(document.querySelector("input[type=password]"), "…");
  return "filled";
})()'
```

**Always prove the fill landed** before submitting — the whole failure mode is that it
looks like it worked:

```bash
agent-browser eval '(() => document.querySelector("input[type=password]").value.length)()'
```

Submit the same way (`btn.click()` inside `eval`) rather than by ref, for the same reason.

### R9. Assert the RENDERED style or attribute, not just that an element exists
"The field is there" passes while the field renders in the wrong component, misses an
attribute, or loses a marker. Read what the browser actually computed:

```bash
# computed style — catches a screen that regressed onto a different component
agent-browser eval '(() => Array.from(document.querySelectorAll("input"))
  .map(i => i.type + ":" + getComputedStyle(i).borderRadius).join(", "))()'

# attribute presence — catches autofill hints that vanished
agent-browser eval '(() => Array.from(document.querySelectorAll("input[type=password]"))
  .map(i => i.autocomplete || "MISSING").join(", "))()'

# label text — catches required markers that stopped rendering
agent-browser eval '(() => Array.from(document.querySelectorAll("label"))
  .map(l => l.textContent.trim()).join(" | "))()'
```

These are the regressions that type-check and lint clean, so nothing else catches them.
Prefer one of these over a prose "confirm it looks right" step.

### R10. Screenshot with `--full`, always
`agent-browser screenshot` captures the **viewport only** — at 1440×900 that is roughly
the top third of a long form, and everything below is silently absent from the evidence.
A reviewer then approves a screenshot that never contained the thing that broke.

```bash
agent-browser screenshot --full logs/e2e/<flow>/NN-<label>.png
```

The only reason to omit `--full` is when you deliberately want the above-the-fold framing
(a hero, a nav bar). For form and list screens it is always wrong.

## Authoring procedure

1. **Scope the flow.** Which app, port, route(s)? Auth or not? What's the single happy path a user walks? One flow = one coherent journey; split login vs dashboard vs checkout into separate files.
2. **Set frontmatter.** `name`/`app`/`port`/`requires-auth`/`triggers`. Triggers = the routes/lib the flow exercises + shared seams it rides on.
3. **Write Preconditions.** Server, the exact `TEST_<APP>_*` vars (loaded via R2), any DB state.
4. **Write Steps** in Setup → journey sections. Every step names *what proves it passed* (the runner marks ✅/❌ on that). Use the recipes below wherever they apply — write the recipe form, not the naive form.
5. **List Failure indicators** — the concrete "this is broken" signals for this flow.
6. **Dry-run it once** (see below). A flow you never executed is drift waiting to happen — the exact failure this skill exists to prevent.

## Dry-run before declaring done

Author, then actually run the flow through `agent-browser` end to end at least once:
- Start the dev server (`.claude/rules/dev-server.md` — check the port first, never kill).
- Walk the steps. Every step should resolve ✅ against real UI.
- If a step needs the naive form to be swapped for a recipe, fix it in the file now.
- A flow that has never been executed is NOT done — hand-off it and it rots.

## Maintenance / drift repair

When a UI change lands:
- Update the flow in the **same PR** as the UI change (the running skill's rule: legitimate UI change → update the stale flow, don't bypass a red run).
- Re-point selectors/steps, refresh any changed copy the flow asserts on, reconcile creds.
- Keep `triggers` honest — if the flow now exercises a new route, add it so the diff-scoped run picks it up.

## Relationship to the running skill

- **`e2e-author` (this)** — writes/maintains the files.
- **`e2e`** — runs them, judges ✅/❌ behaviorally, and produces the HTML+screenshot report.

A flow authored here should be runnable by `e2e` with zero extra guessing. If the runner had to improvise a recipe mid-run, that recipe belongs back here (in the flow, and if it's a new class, in the Recipe library).

## References

- `.claude/skills/e2e/SKILL.md` — the running skill (scope question, execution, report)
- `.claude/rules/integrations/agent-browser.md` — canonical agent-browser conventions (viewport, iframe recipe, auth)
- `.claude/rules/dev-server.md` — server lifecycle (check port, never kill, leave running)
- kit `pipeline.md` §1.5 — why this model (no Playwright / no scripted suite)
