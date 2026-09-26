# Browser Testing with agent-browser

Test and iterate until the result is correct.

## Startup

```bash
agent-browser open http://localhost:3001          # add --headed when the user is watching
agent-browser set viewport 1440 900
agent-browser wait --load networkidle
agent-browser snapshot -i
```

Take a fresh `snapshot -i` after every navigation or DOM change, or the refs are stale.

**Viewport is 1440×900.** It fits every mainstream laptop screen (MacBook 14" ≈ 1512×982, MBA 13" = 1440×900) and every external monitor, and stays above the 768/1024 breakpoints so desktop UI renders as designed. 1920×1080 is desktop-ideal but excludes laptop-developer workflows, and Playwright defaults to 1280×720 with no explicit call.

Resizing the window through the OS does not move Playwright's virtual viewport — an upstream gap in both agent-browser (#592) and Playwright (#14091). Re-run `set viewport 1440 900` to resync, or don't resize manually.

The dev server is typically `http://localhost:3001`; its lifecycle is governed by `dev-server.md`.

## Headed or headless is decided by who asked

| Situation | Mode |
|---|---|
| The user asked you to open or drive the browser, or is watching this run | `--headed` |
| You are verifying your own work, or the session is a background job | **headless** |

The reason is focus. On macOS a headed launch makes the browser frontmost — it takes the keystroke the user was mid-way through and covers what they were reading. That is welcome when they asked for it and are watching. When they have moved on and you are self-verifying it is an interruption, and worse: a user who clicks into the window to dismiss it changes the page state under the run. Playwright exposes no launch-minimized flag.

Headless costs nothing that matters. Snapshots, DOM evaluation and screenshots behave identically; the only loss is watching in real time, which is worth nothing when nobody is watching.

## Name your session

`agent-browser` keeps one background daemon per machine, and any session that does not name one lands in `default`. Two agents then drive the same window: one navigates away mid-flow, refs go stale, reads come back describing the other agent's app, and teardown closes the other agent's browser out from under it.

So whenever another session could be running — on a multi-project machine, most of the time — work in a named one:

```bash
export AGENT_BROWSER_SESSION=<project>     # or --session <project> per command
```

Use the repository directory name as `<project>`.

Named sessions coexist with `default` and with each other, `agent-browser session list` shows them, and closing one leaves the others running. Each gets its own browser, so it also starts logged out.

**Never close a session you did not open.** Closing `default` when you did not put anything there is the same mistake as killing a dev server you did not start.

The tell that you are in someone else's window is a snapshot describing a page you never navigated to. Don't adapt to it — check `location.href` and move to a named session.

## Teardown — always `agent-browser close`

The daemon holds the browser open over CDP so commands stay fast, and it does not close on its own: the Chrome-for-Testing process lingers, visible when headed, and can only be force-quit — which makes macOS auto-updates fail.

So the moment a browser task finishes — one flow, a whole suite, or an ad-hoc check, pass or fail — close **your own** session: `agent-browser close --session <project>`. Chain it so it fires even mid-routine: `<last command> && agent-browser close --session <project>`.

Name the session on the close as well as the open. A bare `agent-browser close` acts on whatever session is current, which is how you close someone else's window while believing you tidied up after yourself.

If the daemon is wedged and `close` won't take: `pkill -f agent-browser`, then `find ~/.agent-browser -maxdepth 1 -type s -delete` to clear sockets left by an interrupted run.

This is the one lifecycle exception to "leave things running" — the browser is your tool, not a shared resource. Dev servers still stay up.

## Traces — only when asked

Tracing costs time and disk on every run to produce an artifact almost nobody opens, and it is least useful on the runs it would fire on most: your own routine self-verification.

When the user does ask — a bug that only reproduces in the browser, or a run they want to inspect afterwards:

```bash
agent-browser trace start
# … the run …
agent-browser trace stop trace.zip
```

`npx playwright show-trace trace.zip` gives a DOM snapshot at every action plus network and console, steppable both ways. Hand the file over with the result.

## Auth

Log in through email/password form fields, and check `.env` for test credentials before asking the user. Google OAuth is blocked by Playwright's bot detection — don't attempt it. Within a live session, cookies and `localStorage` persist across commands on their own — no `state` call needed. A `close` discards them, so to reuse a login across the teardown, `state save <file>` before closing, then `state load <file>` **while the browser is closed** and open afterwards. Loading with a browser running is refused.

## Cross-origin iframes (Stripe, reCAPTCHA)

`agent-browser find` does not traverse cross-origin iframes ([agent-browser#279](https://github.com/vercel-labs/agent-browser/issues/279)); Playwright's `frameLocator` would solve it but agent-browser does not expose it. For the Stripe PaymentElement:

1. Find the iframe's bounding rect with `agent-browser eval` at runtime — position depends on page layout.
2. Click at `(rect.x + iframe_relative_x, rect.y + iframe_relative_y)` via `mouse move` + `mouse down` + `mouse up`. Internal offsets are viewport-independent because Stripe uses fixed-pixel row heights, so the same `+50, +105` works at any size.
3. Send keystrokes with `keyboard type` — Stripe auto-advances between card, expiry, CVC and ZIP.
4. Never adjust the X offset for viewport; X is iframe-relative. Only Y may need tuning if Stripe redesigns row heights.

## Debugging

Check the console after interactions, take screenshots when visual verification is needed, and check network failures with `eval` when API calls look broken.
