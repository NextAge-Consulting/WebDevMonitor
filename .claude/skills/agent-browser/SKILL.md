---
name: agent-browser
description: Browser automation CLI for AI agents. Use when the user needs to interact with websites, including navigating pages, filling forms, clicking buttons, taking screenshots, extracting data, testing web apps, or automating any browser task. Triggers include requests to "open a website", "fill out a form", "click a button", "take a screenshot", "scrape data from a page", "test this web app", "login to a site", "automate browser actions", or any task requiring programmatic web interaction.
allowed-tools: Bash(npx agent-browser:*), Bash(agent-browser:*)
user-invocable: false
---

# Browser Automation with agent-browser

`.claude/rules/integrations/agent-browser.md` owns the policy — viewport, headed vs headless, session naming, teardown, traces, auth, cross-origin iframes. This file is how to drive the tool.

## Core workflow

Navigate, snapshot to get refs, interact with those refs, re-snapshot.

```bash
agent-browser open https://example.com/form
agent-browser snapshot -i
# @e1 [input type="email"], @e2 [input type="password"], @e3 [button] "Submit"

agent-browser fill @e1 "user@example.com"
agent-browser fill @e2 "$PASSWORD"
agent-browser click @e3
agent-browser wait --load networkidle
agent-browser snapshot -i
```

**Refs die when the page changes.** Re-snapshot after anything that navigates, submits, or loads dynamic content — clicking a link, submitting a form, opening a dropdown or modal. Using a stale ref is the most common failure here.

Chain with `&&` when you don't need to read intermediate output (`open && wait && screenshot`). Run separately when you must parse first — snapshot to discover refs, then act on them.

## Commands

```bash
# Navigation
agent-browser open <url>              # aliases: goto, navigate
agent-browser close                   # close this session's browser

# Snapshot
agent-browser snapshot -i             # interactive elements with refs
agent-browser snapshot -i -C          # include cursor-interactive (divs with onclick)
agent-browser snapshot -s "#selector" # scope to a CSS selector
agent-browser snapshot -i --json      # machine-readable

# Interact (refs come from snapshot)
agent-browser click @e1               # --new-tab to open in a new tab
agent-browser fill @e2 "text"         # clear, then type
agent-browser type @e2 "text"         # type without clearing
agent-browser select @e1 "option"
agent-browser check @e1
agent-browser press Enter
agent-browser keyboard type "text"    # type at current focus
agent-browser keyboard inserttext "text"   # insert without key events
agent-browser scroll down 500         # --selector "div.content" to scroll a container

# Read
agent-browser get text @e1            # --json for structured output
agent-browser get url
agent-browser get title

# Set page state for the rest of the session
agent-browser set viewport 1440 900   # the standard viewport — see the rule
agent-browser set media dark          # color scheme without restarting

# Wait
agent-browser wait @e1                # element
agent-browser wait "#content"         # selector
agent-browser wait --load networkidle # network settles — best for slow pages
agent-browser wait --url "**/page"    # URL pattern, useful after redirects
agent-browser wait --fn "document.readyState === 'complete'"
agent-browser wait 2000               # fixed ms, last resort

# Capture
agent-browser screenshot              # to a temp dir with a generated name
agent-browser screenshot shot.png     # ...or an explicit path
agent-browser screenshot --full       # whole page, not just the viewport
agent-browser screenshot --annotate   # numbered labels over interactive elements
agent-browser pdf output.pdf

# Downloads
agent-browser download @e1 ./file.pdf
agent-browser wait --download ./output.zip
agent-browser --download-path ./downloads open <url>

# Diff
agent-browser diff snapshot                         # vs the last snapshot this session
agent-browser diff url <url1> <url2>                # --selector, --wait-until also apply

# Baselines are files YOU produce first — snapshot has no output flag, so redirect it:
agent-browser snapshot -i > before.txt   &&  agent-browser diff snapshot -b before.txt
agent-browser screenshot before.png      &&  agent-browser diff screenshot --baseline before.png
```

Default Playwright timeout is 25s locally; `AGENT_BROWSER_DEFAULT_TIMEOUT` (ms) overrides it. Prefer an explicit `wait` over raising the timeout.

## Sessions

Each named session gets its own browser, so parallel work never collides. Naming is required whenever another session could be running — see the rule.

```bash
agent-browser --session site1 open https://site-a.com
agent-browser --session site2 open https://site-b.com
agent-browser session list
agent-browser --session site1 close
```

**`--session` and `--session-name` are different flags and compose.** `--session <name>` (or `AGENT_BROWSER_SESSION`) gives you an isolated browser — that is the one the rule requires. `--session-name <name>` (or `AGENT_BROWSER_SESSION_NAME`) auto-saves cookies and localStorage to `~/.agent-browser/sessions/` on close and restores them next run. Use both together to get an isolated browser that remembers its login. `AGENT_BROWSER_ENCRYPTION_KEY` (64-char hex) encrypts that stored state.

```bash
# Explicit save/load. Order matters: load is REFUSED while a browser is running.
agent-browser state save auth.json     # with the browser open
agent-browser close
agent-browser state load auth.json     # with it closed
agent-browser open <url>               # ...then reopen
agent-browser state list
agent-browser state show myapp-default.json
agent-browser state clear myapp
agent-browser state clean --older-than 7
```

## Authentication

The auth vault keeps the password out of the transcript entirely — prefer it.

```bash
echo "pass" | agent-browser auth save github --url https://github.com/login \
  --username user --password-stdin
agent-browser auth login github        # the model never sees the password
agent-browser auth list                # names and URLs only
agent-browser auth show <name>         # metadata, never the password
agent-browser auth delete <name>
```

Otherwise log in through the form once and save the state:

```bash
agent-browser fill @e1 "$USERNAME" && agent-browser fill @e2 "$PASSWORD" \
  && agent-browser click @e3 && agent-browser wait --url "**/dashboard"
agent-browser state save auth.json
```

Auth vault operations bypass any action policy, but the domain allowlist still applies.

## Finding elements without refs

```bash
agent-browser find text "Sign In" click
agent-browser find label "Email" fill "user@test.com"
agent-browser find role button click --name "Submit"
agent-browser find placeholder "Search" type "query"
agent-browser find testid "submit-btn" click
```

`find` does not traverse cross-origin iframes — the rule carries the workaround.

## Annotated screenshots

`screenshot --annotate` overlays numbered labels on interactive elements and caches the refs, so `[N]` maps to `@eN` and you can click immediately without a separate snapshot. Reach for it when the page has unlabeled icon buttons, when you need to check visual layout, when canvas or chart elements are involved (invisible to text snapshots), or when you need spatial reasoning about positions.

## Running JavaScript

```bash
agent-browser eval 'document.title'                    # simple, single-line
agent-browser eval --stdin <<'EVALEOF'                 # anything complex
JSON.stringify(
  Array.from(document.querySelectorAll("img"))
    .filter(i => !i.alt)
    .map(i => ({ src: i.src.split("/").pop(), width: i.width }))
)
EVALEOF
agent-browser eval -b "$(echo -n 'document.querySelectorAll("a").length' | base64)"
```

The shell corrupts complex JavaScript before agent-browser ever sees it — inner double quotes, `!` history expansion, backticks and `$()` all bite. `--stdin` and `-b` bypass shell interpretation entirely. Use plain `eval '…'` only for a single line with no nested quotes.

## Other modes

```bash
agent-browser --headed open <url>          # only when the user is watching (see rule)
agent-browser highlight @e1
agent-browser record start demo.webm [url]   # then: record stop, or record restart <path>
agent-browser record stop
agent-browser profiler start
agent-browser profiler stop trace.json       # path optional
agent-browser --color-scheme dark open <url>   # or AGENT_BROWSER_COLOR_SCHEME=dark, or `set media dark` mid-session
agent-browser --allow-file-access open file:///path/to/document.pdf
agent-browser --auto-connect open <url>        # attach to a running Chrome
agent-browser --cdp 9222 snapshot              # ...or an explicit CDP port
```

**iOS Simulator** needs macOS with Xcode and Appium (`npm install -g appium && appium driver install xcuitest`):

```bash
agent-browser device list
agent-browser -p ios --device "iPhone 16 Pro" open https://example.com
agent-browser -p ios snapshot -i
agent-browser -p ios tap @e1           # alias for click
agent-browser -p ios swipe up
agent-browser -p ios close             # shuts down the simulator
```

A physical device works the same way with `--device "<UDID>"`, from `xcrun xctrace list devices`.

## Hardening (all opt-in, off by default)

```bash
export AGENT_BROWSER_CONTENT_BOUNDARIES=1              # wrap page output in nonce markers
export AGENT_BROWSER_ALLOWED_DOMAINS="example.com,*.example.com"
export AGENT_BROWSER_ACTION_POLICY=./policy.json       # {"default":"deny","allow":["navigate","snapshot",…]}
export AGENT_BROWSER_MAX_OUTPUT=50000                  # cap output from huge pages
```

Content boundaries help separate tool output from untrusted page content. A wildcard like `*.example.com` also matches the bare domain, and the allowlist covers sub-resources, WebSocket and EventSource too — so include any CDN the page needs.

## Configuration

`agent-browser.json` in the project root holds persistent settings; `--config <path>` or `AGENT_BROWSER_CONFIG` points at a different file, and either exits with an error if it is missing or invalid. Precedence, lowest to highest: `~/.agent-browser/config.json`, then `./agent-browser.json`, then env vars, then CLI flags. Every CLI option maps to a camelCase key (`--executable-path` → `"executablePath"`), boolean flags take `true`/`false` so `--headed false` overrides the config, and extensions from user and project configs merge rather than replace.

```json
{ "proxy": "http://localhost:8080", "profile": "./browser-data" }
```
