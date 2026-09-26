# Dev Server Protocol

## The user starts dev servers, via `/dev`

`/dev` opens a new terminal tab in the project root and runs the dev command. It detects port collisions with `lsof` and bumps by `+10` (3001 → 3011 → 3021, capped at 3 hops), titling the tab `<app> @ <project-name> (:<port>)`. The tab is a tmux window when a tmux session is in play, an iTerm2 tab otherwise; `.claude/commands/dev.md` has the full ordering.

Do not start a dev server without the user invoking it. `.claude/skills/dev-server/SKILL.md` carries the natural-language routing, `.claude/commands/dev.md` the slash command, and the kit's `project-documentation/devserver-cheatsheet.md` the one-page reference.

`/e2e` is the one exception — it auto-starts a server when no port is occupied, so a verification run can proceed unattended. When a port is occupied it uses the occupant, like everything else. The rules below still apply to it.

## The rules

1. **Check first.** Run `lsof -iTCP:<port> -sTCP:LISTEN` before any server action, so you know what is actually there. The port is the one the app you are targeting is configured for — read it from the project's dev script or config rather than assuming.

2. **An occupied port gets used.** The occupant is the user or another session, and either is fine. Never kill it, never question it, and never start an alternate port to sidestep it. The server that is running is the server under test.

3. **A free port may be started on** when the task genuinely needs a server. Announce it — `starting <service> on :<port> for <reason>` — send stdout and stderr to `logs/server.log` or the project-conventional path, and use the project's standard start command. Never double-background: one mechanism only, so no `&` inside a `run_in_background` command, which orphans the process and hides it from the status bar.

   Don't start a server for something that doesn't need one. A one-shot curl or a port-ping is usually a file read or a unit test.

4. **Never kill a process you did not start.** This is the most important rule here. A running dev server almost always means the user is mid-test, and killing it destroys their flow. It covers `kill`, `kill -9`, `pkill`, `lsof … | xargs kill`, `fuser -k`, and `docker stop` on a running container. Surface a misbehaving server to the user instead.

5. **Leave the user's servers running; kill your own at handoff.** A server the user started via `/dev`, or another session's, is a shared resource — leaving it is rule 4. But a server you or a subagent started is invisible to the user: no tab, no way to see or stop it. So when you hand back, zero background servers you spawned are still running. A leftover silently occupies a port the user's next `/dev` bumps around, and they cannot see why. Start it once and kill it once at the end rather than thrashing it mid-task.

## Monitoring

`tail -f logs/server.log`. Projects with several servers may use per-service paths such as `logs/server-dealer.log`.

## Hook enforcement

`.claude/hooks/dev-server-guard.sh` enforces rule 4 at the tool-call layer by blocking `pkill` and `kill` patterns aimed at dev servers. Rules 1, 2, 3 and 5 are behavioural — enforced by you reading this.

`SKIP_SERVER_GUARD=1 <command>` overrides the hook, and has exactly two authorized uses: the user explicitly authorized killing a specific process, or you are cleaning up a server you started, at handoff. Killing your own server needs no permission; killing anyone else's always does.
