---
name: dev-server
description: This skill should be used when the user asks to "start dev", "run dev", "start dev server", "run the server", "start shop", "start dealer", "spin up <app>", "start with tunnel", "tunnel <app>", "expose to a teammate", "run on cloudflare", "what's running", "show dev servers", or any natural-language request to launch a dev server. The canonical and ONLY authorized path for starting dev servers in a kit-enabled project. Routes to the `/dev` slash command, which opens a new terminal tab at the project root and runs the dev command, with the port auto-overridden on collision via `lsof` pre-check. `--tunnel` flag wraps the dev command with a Cloudflare named tunnel.
user-invocable: false
---

# dev-server

Natural-language routing layer for launching dev servers in their own terminal tab. Companion to `gitflow` — same shape, different domain.

## Why this skill exists

Two problems the Agents-view workflow created that the old "cmd-t + cd + npm run dev" flow can't solve:

1. **iTerm `cmd-t` lands in the wrong directory.** Agents view spawns the host shell in `~/projects` with no project context, so cmd-t inherits `~/projects` and every new tab needs manual `cd`.
2. **Silent vite port-bump.** When `:3001` is occupied (most projects default to it), vite silently bumps to `:3002`. You browser-test `localhost:3001` thinking it's your project and it's actually a different project's server. The "100% via skill" model exists to make this footgun structurally impossible.

`/dev` is the sole, universal entry point. Mirrors gitflow's role for git operations.

## When dev-server applies

| User intent | Command to invoke |
|-------------|-------------------|
| "start dev", "run dev", "run the server" | `/dev` (lists available scripts, prompts choice) |
| "start shop", "spin up shop" | `/dev shop` |
| "start shop and dealer", "run both" | `/dev shop dealer` |
| "start shop with tunnel", "tunnel shop", "expose shop to a teammate", "run shop on cloudflare" | `/dev shop --tunnel` |
| "what's running", "show dev servers", "any dev servers up" | `/dev --status` |

## What dev-server does

1. **Detects project root** from cwd — walks up to the nearest `package.json` with `dev*` scripts.
2. **Detects each app's default port** from `apps/<app>/vite.config.ts` (or root `vite.config.ts` for flat layouts). Falls back to `:3000` if not found.
3. **`lsof` pre-check.** If port is free, use it. If occupied, step `+10` (3001 → 3011 → 3021). Cap at 3 hops; refuse beyond.
4. **Opens a new tab**, `cd`'s into the project root, titles it `<app> @ <project-name> (:<port>)`, and runs `<PORT_ENV>=<N> npm run dev:<app>`.

Four backends are tried in a fixed order — a tmux window in the current session when `$TMUX` is set, then a window in whichever session a tmux client is attached to, then an iTerm2 tab via `osascript`, then a window in a detached `dev` tmux session. `commands/dev.md` has the ordering and why it must not be rearranged.

The port arrives as an env var rather than `-- --port <N>`, because npm's flag parser consumes `--port` before it reaches the inner npm and vite through monorepo script nesting. `<PORT_ENV>` is the variable the app's `vite.config.ts` reads, defaulting to `PORT`.

## What dev-server does NOT do

- **Does not start servers without user invocation.** The user must explicitly invoke `/dev <app>` — Claude never starts a server on its own initiative.
- **Does not kill servers.** Ever. `--status` surfaces only (pid, port, cwd). `dev-server.md` rule 4.
- **Does not auto-restart on file changes.** That's the running vite server's job, untouched.
- **Does not work without a terminal backend.** It needs tmux, or macOS with iTerm2. A tmux session the user is attached to gets the window directly; an unattended one works via the detached `dev` session; with neither, it refuses and prints the command to run by hand.
- **Does not interfere with vitest.** `vitest` / `npm run test` aren't dev servers; no port binding; no overlap.
- **Cloudflare tunnel**: `--tunnel` swaps the staged command to `npm run dev:tunnel:<app>` (cloudflared + vite in the same tab). Each `--tunnel` invocation spawns a cloudflared replica — acceptable, cheap. The tunnel ingress map (`~/.cloudflared/config.yml`) is shared across replicas.

## Usage procedure

When a user request matches a dev-server trigger:

1. Identify which app(s) to start from the request (default: prompt via `/dev` with no args if ambiguous).
2. Invoke `/dev <args>` via the slash command.
3. If the script reports "no free port found in 3 hops", surface to the user — do NOT retry. They have to decide which server to stop.
4. If the script reports "no `dev:<app>` script", surface the available scripts and ask which the user meant.

## E2E interaction

`/e2e` (per `.claude/skills/e2e/SKILL.md`) auto-starts dev servers when no port is occupied — required so a verification run can proceed unattended. This is **the one legitimate path** that starts a server outside `/dev`.

- E2E checks the port, uses it if occupied (rule 2), starts if free (logged to `logs/server.log`).
- E2E does NOT kill servers it didn't start (rule 4).
- No hook blocks raw `npm run dev` — `/dev` is canonical-by-convention (same model as `agent-browser`), not enforced by a guard. Every bypass token weakens the structural claim; the easy-path argument carries it.

## Cross-references

- `.claude/rules/dev-server.md` — the rules of server lifecycle (check first, use occupied, never kill, leave running) that still govern any running server regardless of how it was started.
- `.claude/commands/dev.md` — slash command specification.
- `.claude/skills/dev-server/scripts/dev.sh` — implementation.
- `project-documentation/devserver-cheatsheet.md` — one-page reference.
- `.claude/skills/e2e/SKILL.md` — the one path that legitimately auto-starts servers outside this skill.
- `.claude/skills/gitflow/SKILL.md` — same shape, same model, for git ops.
