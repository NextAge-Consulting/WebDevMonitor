# /dev

Stage a dev server in a new terminal tab. Part of the dev-server subsystem. The canonical and ONLY authorized path for starting dev servers in this project.

## The model

Two problems the Agents-view flow created that the old "cmd-t + `cd` + `npm run dev`" flow can't solve:

1. **iTerm cmd-t lands in `~/projects`, not the project.** Agents view spawns the host shell from `~/projects` with no project context, so every new tab needs a manual `cd`.
2. **Silent vite port-bump.** Vite's default on port collision is to bump to the next free port (`:3002`, `:3003`) without erroring. Browser-testing `localhost:3001` then tests the wrong project's server.

`/dev` solves both by spawning a tab with an explicit `cd`, plus an `lsof` pre-check and a structured port-step-by-10 on collision. Which terminal opens that tab is decided by the ladder below.

## Supported invocations

| Input | What happens |
|-------|--------------|
| `/dev` | List all `dev*` scripts from the resolved project's `package.json`. Await user choice. |
| `/dev <app>` | Stage `npm run dev:<app>` in the project root, on the detected port (auto-bumped +10 on collision). |
| `/dev <app1> <app2>` | One tab per app. |
| `/dev <app> --tunnel` | Stage `npm run dev:tunnel:<app>` (cloudflared + vite together). Requires a `dev:tunnel:<app>` script. |
| `/dev --status` | List listening processes on `:3000-:3099` (pid, port, cwd, cmd). Never kills. |

## Procedure

### Step 1: Parse arguments

- App names (positional, zero or more).
- `--tunnel` flag → swap script to `dev:tunnel:<app>` (cloudflared + vite).
- `--status` flag → exit after surfacing the listener list.

### Step 2: Invoke the script

```bash
.claude/skills/dev-server/scripts/dev.sh [args...]
```

The script handles project-root detection, port probing, and opening the tab. Surface the script's stdout to the user — it reports where each tab landed.

### Step 3: Report

Report each launched tab: app, path, port, command. If the script refused (no free port within 3 hops, no matching `dev:<app>` script, no `package.json`), surface the refusal reason verbatim. Do NOT retry without explicit user direction.

## Port-override mechanic

For each chosen app:

1. **Default port detection.** Reads `port:` from `apps/<app>/vite.config.ts` (monorepo) or `vite.config.ts` (flat). Falls back to `3000` if neither found.
2. **`lsof` probe.** `lsof -iTCP:<port> -sTCP:LISTEN`. If free, use it.
3. **Auto-bump on collision.** Step `+10` each hop. Cap at 3 hops:
   - shop: `3001 → 3011 → 3021`
   - dealer: `3010 → 3020 → 3030`
4. **Refuse beyond 3 hops** — "too many dev servers on this app's slots, stop one first" with the occupant list (pid + cwd) of each occupied slot.
5. **Env-var override on launch.** Stages `<PORT_ENV>=<N> npm run dev:<app>`, where `<PORT_ENV>` is the variable that app's `vite.config.ts` reads (`port: Number(process.env.WEB_PORT) || 3010`), defaulting to `PORT`. An env var is used rather than `-- --port <N>` because npm's own flag parser consumes `--port` before it reaches the inner npm and vite through the script nesting common in monorepos.

## Where the tab opens

Four backends, tried in this order. **The order is load-bearing** — it decides which terminal a user's dev server appears in.

1. **Inside tmux** (`$TMUX` is set) → `tmux new-window` in the current session. Switch to it with `Ctrl-b n`.
2. **A tmux client is attached** → `tmux new-window` in that client's session, preferring the focused client. Same rank of signal as 1: an attached client is a person with their eyes on that session.
3. **iTerm2 via `osascript`** → a tab in the current iTerm window. This reads no environment at all, which is why it still works from an Agents-view session, where the launchd-spawned host drops `TERM_PROGRAM`, `ITERM_SESSION_ID` and `LC_TERMINAL`.
4. **A reachable tmux server with nobody attached** → a window in a `dev` session, created if absent, and the script prints `tmux attach -t dev`. Last resort: a detached server says nothing about which window the user is looking at. Ranked above iTerm, a macOS user with a stray detached server would silently stop getting iTerm tabs.

**Why 2 exists, and why it is not redundant with 1.** `$TMUX` is a proxy for "the user is in tmux", and it leaks: a Claude Code session running inside tmux hands its Bash tool an environment with `$TMUX` stripped, so 1 misses the exact case it was written for and the run falls all the way to 4 — a detached `dev` session the user never sees. Asking tmux which client is attached answers the same question without depending on inherited environment.

There is no `uname` branch — the platform is never the question. Linux never satisfies 3, and macOS reaches 4 only once iTerm2 has already failed.

Whichever backend wins, the tab:

- Runs `cd '<target_dir>'`, the detected project root.
- Is titled `<app> @ <project-name> (:<port>)`. iTerm gets it via an OSC 0 escape (`printf '\e]0;<title>\a'`) set AFTER the `cd`, so zsh's chpwd-hook title update doesn't overwrite it; tmux gets it as the window name, with `automatic-rename` pinned off so a long-running server can't relabel it.
- Runs `<PORT_ENV>=<N> npm run dev:<app>`. The server starts immediately; ctrl-C when done. The shell outlives the command, so a crash leaves its output on screen rather than closing the tab.

## Blocking conditions

- **No `package.json`** found walking up from cwd → exit 3.
- **No `dev:<app>` script** matching a requested app → exit 4, lists available scripts.
- **No free port within 3 hops** of the default → exit 5, lists occupants of each occupied slot.
- **No backend available** (not inside tmux, iTerm2 unreachable, no tmux installed) → surface the error; the intended command and path are printed so the user can run them manually.
- **`tmux new-window` failed while inside tmux** → refuses rather than falling back, since another terminal would put the server where the user is not looking.

## What this command does NOT do

- **Does not start servers without user invocation.** User explicitly types `/dev <app>`; Claude never starts servers on its own.
- **Does not kill servers.** Ever. `--status` is surface-only.
- **Does not start servers where no backend exists.** It needs tmux, or macOS with iTerm2. A headless session with tmux installed works, via the `dev` session; one with neither is refused, with the command printed to run by hand.
- **Does not auto-restart on file changes.** The running vite server's job, untouched.

## Edge cases

- **Two Claude sessions, same project, both `/dev shop`.** First wins `:3001`, second auto-bumps to `:3011`. Independent tabs.
- **`/merge` lands the checkout back on `main` while the dev tab is still running.** Vite picks up the branch switch as a file change and rebuilds; the tab keeps serving, now from `main`. Restart it if you want the old branch back.
- **Non-vite dev servers (Next.js, Astro, …).** Work as long as the `dev:<app>` script exists in `package.json` and the framework honors the port env var — `PORT` is respected out of the box by TanStack Start, Nitro, Next.js and Astro. Port detection won't find anything in `vite.config.ts` and falls back to `3000`; user can override or add `apps/<app>/vite.config.ts` with the port to make detection work. Future enhancement: project-level `.claude/dev-server.json` map.

## Related

- `.claude/rules/dev-server.md` — the rules of server lifecycle (check first, use occupied, never kill, leave running) that still apply once a server is running.
- `.claude/skills/dev-server/SKILL.md` — natural-language routing layer.
- `.claude/skills/e2e/SKILL.md` — the one path that legitimately auto-starts servers outside `/dev` (unattended verification runs).
- `project-documentation/devserver-cheatsheet.md` — one-page reference.
