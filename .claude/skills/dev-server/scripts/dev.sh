#!/bin/bash
# dev-server skill: stage a dev server in a new terminal tab/window.
#
# Usage:
#   dev.sh                       List available dev* scripts at the resolved project root
#   dev.sh <app> [<app>...]      Stage dev server(s) in new tabs at the project root
#   dev.sh --status              List listening processes on :3000-:3099 (pid, port, cwd, cmd)
#
# Behavior:
#   - Walks up from cwd to find the nearest package.json (project root).
#   - For each chosen app, detects the default port from apps/<app>/vite.config.ts
#     (or root vite.config.ts for flat layouts). Falls back to 3000.
#   - lsof check: if port free, uses it; if occupied, steps +10. Caps at 3 hops.
#   - Opens a new tab/window, cd's into the target dir, runs the dev command.
#     Title = "<app> @ <project-name> (:<port>)". Which backend opens it is
#     decided in `stage_app` — see the ordering note there.
#
# Output:
#   For each staged app, prints "launched: <title>" + path + cmd.
#   On refusal, exits non-zero with a reason printed to stderr.
#
# Does NOT execute the dev command. Does NOT kill any process. --status surfaces only.

set -eo pipefail
# Note: do NOT rely on `inherit_errexit` here — bash 3.2 (macOS default) lacks
# it. Error propagation in this script uses explicit `if !` guards on the
# command substitutions whose failure actually matters
# (find_project_root, pick_port). Other `$(...)` captures either trail
# `|| true` (intentional best-effort) or invoke functions that cannot fail in
# a way that should abort. See `.claude/rules/bash-rules.md` §I, §III.

# Session used when a tmux server is reachable but we are not inside one.
TMUX_FALLBACK_SESSION="dev"

usage() {
  cat <<EOF
Usage:
  dev.sh                       List available dev scripts
  dev.sh <app> [<app>...]      Stage dev server(s) in new tabs at the project root
  dev.sh <app> --tunnel        Stage with Cloudflare tunnel (npm run dev:tunnel:<app>)
  dev.sh --status              List running dev servers (pid, port, cwd)
EOF
}

find_project_root() {
  local dir="${1:-$PWD}"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/package.json" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

detect_port() {
  local root="$1" app="$2" vite p
  # Two known patterns in consumer projects:
  #   1. Literal:  `port: 3010`
  #   2. Env-fallback: `Number(process.env.<ENV>) || 3010`
  #      (typically `const PORT = Number(process.env.<ENV>) || 3010; port: PORT`)
  #      where <ENV> is ANY env var name — commonly per-app in a monorepo
  #      (WEB_PORT, API_PORT), not the literal PORT.
  # Probe vite.config.ts at the per-app path first, then root for flat layouts.
  for vite in "$root/apps/$app/vite.config.ts" "$root/vite.config.ts"; do
    [ -f "$vite" ] || continue
    p="$(grep -oE 'port:[[:space:]]*[0-9]+' "$vite" | head -1 | grep -oE '[0-9]+' || true)"
    if [ -n "$p" ]; then
      echo "$p"
      return
    fi
    # `Number(process.env.<ENV>) || 3010` — capture the trailing default.
    p="$(grep -oE 'Number\(process\.env\.[A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*\|\|[[:space:]]*[0-9]+' "$vite" | head -1 | grep -oE '[0-9]+$' || true)"
    if [ -n "$p" ]; then
      echo "$p"
      return
    fi
  done
  echo "3000"
}

detect_port_env() {
  local root="$1" app="$2" vite name
  # The env var the app's vite.config.ts reads to override its port. In a
  # monorepo each app typically has its own (WEB_PORT, API_PORT). Falls back
  # to PORT when the config declares no env-fallback (frameworks that honor
  # PORT out of the box).
  for vite in "$root/apps/$app/vite.config.ts" "$root/vite.config.ts"; do
    [ -f "$vite" ] || continue
    name="$(grep -oE 'Number\(process\.env\.[A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*\|\|[[:space:]]*[0-9]+' "$vite" | head -1 | grep -oE 'process\.env\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/process\.env\.//' || true)"
    if [ -n "$name" ]; then
      echo "$name"
      return
    fi
  done
  echo "PORT"
}

port_free() {
  ! lsof -iTCP:"$1" -sTCP:LISTEN -P -n -t >/dev/null 2>&1
}

pick_port() {
  # NOTE: each `local` must be its own statement because bash expands `$var`
  # references using OUTER scope values when they appear on the same `local`
  # line — `local a="$1" b="$a"` would leave b empty.
  local default="$1"
  local port="$default"
  local hop=0
  while [ $hop -lt 3 ]; do
    if port_free "$port"; then
      echo "$port"
      return 0
    fi
    port=$((port + 10))
    hop=$((hop + 1))
  done
  return 1
}

port_occupant() {
  local port="$1" pid cwd cmd
  pid="$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n -t 2>/dev/null | head -1 || true)"
  [ -z "$pid" ] && return 1
  cwd="$(lsof -p "$pid" -d cwd -F n 2>/dev/null | grep '^n' | sed 's/^n//' | head -1 || true)"
  cmd="$(ps -p "$pid" -o command= 2>/dev/null | head -1 || true)"
  echo "pid=$pid cwd=${cwd:-?} cmd=${cmd:-?}"
}

list_dev_scripts() {
  local root="$1"
  if [ ! -f "$root/package.json" ]; then
    echo "no package.json at $root" >&2
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -r '.scripts // {} | to_entries[] | select(.key | startswith("dev")) | .key' "$root/package.json"
  else
    grep -oE '"dev[^"]*":[[:space:]]*"[^"]*"' "$root/package.json" \
      | grep -oE '"[^"]+":' \
      | tr -d '":'
  fi
}

cmd_status() {
  echo "Listening processes on :3000-:3099 (dev range):"
  echo ""
  local found=0 port pid cwd cmd
  for port in $(seq 3000 3099); do
    pid="$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n -t 2>/dev/null | head -1 || true)"
    if [ -n "$pid" ]; then
      cwd="$(lsof -p "$pid" -d cwd -F n 2>/dev/null | grep '^n' | sed 's/^n//' | head -1 || true)"
      cmd="$(ps -p "$pid" -o command= 2>/dev/null | head -1 || true)"
      printf "  :%-5s  pid=%-7s\n" "$port" "$pid"
      printf "           cwd=%s\n" "${cwd:-?}"
      printf "           cmd=%s\n" "${cmd:-?}"
      found=$((found + 1))
    fi
  done
  if [ $found -eq 0 ]; then
    echo "  (none)"
  fi
}

attached_tmux_session() {
  # Which tmux session is the user actually LOOKING at? `$TMUX` answers that
  # only when it survives into our environment, and it frequently does not —
  # a Claude Code session running inside tmux hands its Bash tool an
  # environment with `$TMUX` stripped, so the check below it silently fails
  # and the server lands in a detached session nobody sees.
  #
  # An attached client answers the same question directly and does not depend
  # on inherited environment. Prefer the focused client; with several attached
  # and none focused, the first is as good a guess as exists.
  command -v tmux >/dev/null 2>&1 || return 1
  local name
  name="$(tmux list-clients -F '#{client_flags}|#{client_session}' 2>/dev/null | awk -F'|' '
    {
      if (seen == 0) { first = $2; seen = 1 }
      if ($1 ~ /focused/ && fseen == 0) { focused = $2; fseen = 1 }
    }
    END { if (fseen) print focused; else if (seen) print first }')"
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

# Set by tmux_launch on failure, read by report_tmux_error.
#
# shellcheck disable=SC2034  # written in tmux_launch's failure branches below and
# read by report_tmux_error; shellcheck does not follow a write that happens inside
# a `|| { … }` group after a command substitution.
TMUX_LAUNCH_ERROR=""

# Print what tmux actually said, if anything. A function rather than an inline
# `[ -n "$X" ] && echo` at each of the three failure sites: one definition, one
# wording, and no chance of the three drifting apart.
report_tmux_error() {
  if [ -n "$TMUX_LAUNCH_ERROR" ]; then
    echo "  tmux said: $TMUX_LAUNCH_ERROR" >&2
  fi
}

tmux_launch() {
  # $1 = target session name, or "" to use the session we are already inside.
  local session="$1" dir="$2" title="$3" cmd="$4"
  local win_id
  local payload
  # `exec $SHELL` leaves a live shell behind when the dev server exits, matching
  # the iTerm tab — there `write text` runs the command in a shell that outlives
  # it. Without this the tmux window would vanish the moment vite dies, taking
  # the crash output with it.
  payload="$cmd; exec ${SHELL:-/bin/sh}"

  # `-d` creates the window WITHOUT switching to it. Without it, tmux makes the
  # new window active and the user's view is yanked off whatever they were
  # doing — which, when Claude Code is the thing they were doing, means Claude
  # vanishes mid-session and the only way back is a key they have to guess.
  # `/dev` stages a server; it does not ask to be looked at. Every report line
  # tells the user how to reach it (`Ctrl-b n`), which is the point.
  # **The trailing colon on the session target is load-bearing.** `new-window
  # -t` takes a TARGET-WINDOW, so a bare `0` is read as "window index 0 in the
  # current session", not "the session named 0" — and since window 0 always
  # exists, creating it fails with `create window failed: index 0 in use`. A
  # session named `0` is not exotic: it is what tmux calls the first session on
  # a server, so this bit anyone who had not named theirs. `0:` forces
  # session-only resolution. Reported as kit issue #3 and reproduced.
  #
  # `has-session -t` is NOT affected and deliberately left bare — its target is
  # unambiguously a session, and both spellings resolve identically.
  #
  # tmux's stderr is CAPTURED, not discarded. `2>/dev/null` here cost the
  # reporter of #3 a debugging session: the caller printed "tmux new-window
  # failed", which names no cause, and the real message had to be found by
  # running the command by hand. On success the capture is the window id, which
  # is the only thing tmux writes to stdout.
  if [ -z "$session" ]; then
    win_id="$(tmux new-window -d -c "$dir" -n "$title" -P -F '#{window_id}' "$payload" 2>&1)" || { TMUX_LAUNCH_ERROR="$win_id"; return 1; }
  elif tmux has-session -t "$session" 2>/dev/null; then
    win_id="$(tmux new-window -d -t "$session:" -c "$dir" -n "$title" -P -F '#{window_id}' "$payload" 2>&1)" || { TMUX_LAUNCH_ERROR="$win_id"; return 1; }
  else
    win_id="$(tmux new-session -d -s "$session" -c "$dir" -n "$title" -P -F '#{window_id}' "$payload" 2>&1)" || { TMUX_LAUNCH_ERROR="$win_id"; return 1; }
  fi

  if [ -z "$win_id" ]; then
    TMUX_LAUNCH_ERROR="tmux reported success but returned no window id"
    return 1
  fi
  # A long-running dev server would otherwise relabel the window from its own
  # process name, losing the "<app> @ <project> (:<port>)" title.
  tmux set-option -w -t "$win_id" automatic-rename off >/dev/null 2>&1 || true
  return 0
}

report_launched() {
  echo "launched: $1"
  echo "  path:  $2"
  echo "  cmd:   $3"
  echo "  where: $4"
}

report_intent() {
  echo "intended command: $1" >&2
  echo "intended path:    $2" >&2
}

stage_app() {
  local target_dir="$1" app="$2" port="$3" tunnel="$4" port_env="${5:-PORT}"
  local script_key="dev:$app"
  if [ "$app" = "dev" ]; then
    script_key="dev"
  fi
  if [ -n "$tunnel" ]; then
    script_key="dev:tunnel:$app"
  fi
  # An env var is the most reliable port override across the npm-script
  # nesting common in monorepos. Passing `-- --port N` through
  # `npm run dev:dealer -- --port N` → `npm run dev --prefix apps/dealer -- --port N`
  # is unreliable — npm's own flag parser consumes `--port` before it
  # reaches the inner npm and vite. An env var propagates cleanly through
  # any nesting level. `$port_env` is the var the app's vite.config.ts reads
  # (`port: Number(process.env.<ENV>) || <default>`) — per-app in a monorepo
  # (WEB_PORT, API_PORT); defaults to PORT, which TanStack Start / Nitro /
  # Next.js / Astro honor out of the box when the config adds no override.
  local cmd="$port_env=$port npm run $script_key"
  local title_suffix=""
  [ -n "$tunnel" ] && title_suffix=" [tunnel]"
  local title
  title="$app @ $(basename "$target_dir") (:$port)$title_suffix"

  # Tab title:
  # /dev tabs are spawned with the "DevServer" iTerm profile (NOT the user's
  # default profile). DevServer has `Allow Title Setting = true`, which lets
  # the inline `printf '\e]0;TITLE\a'` actually set session.name. The user's
  # default profile (e.g. CPL) keeps Allow Title Setting=false to prevent
  # Claude Code's startup OSC-0 width-probe from corrupting Claude's tab
  # title — a real concern verified empirically (Claude binary contains one
  # OSC 0 set-title for terminal width measurement, no OSC 22 push/pop).
  #
  # The DevServer profile JSON lives at:
  #   ~/Library/Application Support/iTerm2/DynamicProfiles/DevServer.json
  # See devserver-cheatsheet.md for one-time install steps.
  #
  # We use `printf` (not a `# comment` line) because zsh interactive shells
  # default INTERACTIVE_COMMENTS off — `# foo (:3010)` would parse as a
  # command and zsh's globbing would choke on `(:)`.
  local applescript
  applescript=$(cat <<APPLESCRIPT
tell application "iTerm2"
  tell current window
    create tab with profile "DevServer"
    tell current session
      write text "cd '$target_dir'"
      write text "printf '\\\\e]0;$title\\\\a'; $cmd"
    end tell
  end tell
end tell
APPLESCRIPT
)

  # --- Which backend opens the window -----------------------------------
  #
  # The ORDER is load-bearing; see devserver-cheatsheet.md "Where the window
  # lands". Reordering these silently changes which terminal a user's dev
  # server appears in.
  #
  #   1. $TMUX set   — Claude is running INSIDE tmux, so a tmux window is the
  #                    tab adjacent to the user.
  #   1b. attached   — a tmux client is attached to some session. Same class of
  #       client        signal as 1 and it belongs at the same rank: an ATTACHED
  #                    client is a person with their eyes on that session. It
  #                    exists because `$TMUX` is a proxy that leaks — Claude
  #                    Code running inside tmux passes its Bash tool an
  #                    environment without `$TMUX`, so 1 misses the very case
  #                    it was written for, and the run falls all the way to 3.
  #   2. osascript   — iTerm2 over Apple Events. It reads no environment at
  #                    all, which is exactly why it still works from an
  #                    Agents-view session, where the launchd-spawned host
  #                    drops TERM_PROGRAM / ITERM_SESSION_ID / LC_TERMINAL.
  #   3. tmux server — last resort, and it MUST stay below osascript. Reaching
  #                    here means a tmux server exists and NOBODY is attached
  #                    to it, which says nothing about where the user is
  #                    looking. Ranked above osascript, a macOS user with a
  #                    stray detached server would silently stop getting iTerm
  #                    tabs. This is the only case that creates the detached
  #                    "dev" session the user then has to attach to by hand.
  #
  # No `uname` branch: the platform is never the question. Linux simply never
  # satisfies 2, and macOS reaches 3 only once iTerm2 has already failed.

  if [ -n "${TMUX:-}" ]; then
    if tmux_launch "" "$target_dir" "$title" "$cmd"; then
      report_launched "$title" "$target_dir" "$cmd" "tmux window in this session (Ctrl-b n to switch)"
      return 0
    fi
    # Inside tmux and tmux refused: falling through to another terminal would
    # put the server somewhere the user is not looking.
    echo "tmux new-window failed inside an active tmux session" >&2
    report_tmux_error
    report_intent "$cmd" "$target_dir"
    return 1
  fi

  local attached_session
  attached_session="$(attached_tmux_session 2>/dev/null || true)"
  if [ -n "$attached_session" ]; then
    if tmux_launch "$attached_session" "$target_dir" "$title" "$cmd"; then
      report_launched "$title" "$target_dir" "$cmd" \
        "tmux window in attached session '$attached_session' (Ctrl-b n to switch)"
      return 0
    fi
    # Same reasoning as the $TMUX branch: we know where the user is sitting, so
    # opening the server anywhere else is worse than refusing.
    echo "tmux new-window failed in attached session '$attached_session'" >&2
    report_tmux_error
    report_intent "$cmd" "$target_dir"
    return 1
  fi

  if osascript -e "$applescript" >/dev/null 2>&1; then
    report_launched "$title" "$target_dir" "$cmd" "new iTerm2 tab"
    return 0
  fi

  if command -v tmux >/dev/null 2>&1; then
    if tmux_launch "$TMUX_FALLBACK_SESSION" "$target_dir" "$title" "$cmd"; then
      report_launched "$title" "$target_dir" "$cmd" \
        "tmux window in session '$TMUX_FALLBACK_SESSION' — attach with: tmux attach -t $TMUX_FALLBACK_SESSION"
      return 0
    fi
  fi

  echo "no terminal available to open a tab in." >&2
  report_tmux_error
  echo "start Claude inside tmux, or run it on macOS with iTerm2 installed." >&2
  report_intent "$cmd" "$target_dir"
  return 1
}

# === MAIN ===

status_mode=""
tunnel_mode=""
apps=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --status) status_mode=1 ;;
    --tunnel) tunnel_mode=1 ;;
    --*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) apps+=("$1") ;;
  esac
  shift
done

if [ -n "$status_mode" ]; then
  cmd_status
  exit 0
fi

cwd="$PWD"
if ! project_root="$(find_project_root "$cwd")"; then
  echo "no package.json found walking up from $cwd" >&2
  exit 3
fi
target_dir="$project_root"

if [ ${#apps[@]} -eq 0 ]; then
  echo "Available dev scripts at $project_root:"
  list_dev_scripts "$project_root" | sed 's/^/  /'
  echo ""
  echo "Invoke: dev.sh <app> [<app>...]"
  exit 0
fi

if ! available_scripts="$(list_dev_scripts "$project_root")"; then
  echo "failed to enumerate dev scripts in $project_root/package.json" >&2
  exit 4
fi
for app in "${apps[@]}"; do
  script_key="dev:$app"
  [ "$app" = "dev" ] && script_key="dev"
  [ -n "$tunnel_mode" ] && script_key="dev:tunnel:$app"
  if ! echo "$available_scripts" | grep -qx "$script_key"; then
    echo "no script '$script_key' in $project_root/package.json" >&2
    echo "available:" >&2
    echo "$available_scripts" | sed 's/^/  /' >&2
    exit 4
  fi
done

for app in "${apps[@]}"; do
  default_port="$(detect_port "$project_root" "$app")"
  port_env="$(detect_port_env "$project_root" "$app")"
  if ! port="$(pick_port "$default_port")"; then
    echo "no free port found stepping +10 from :$default_port (3 hops); refusing" >&2
    echo "occupants:" >&2
    for hop in 0 10 20; do
      occupant="$(port_occupant "$((default_port + hop))" 2>/dev/null || true)"
      echo "  :$((default_port + hop)) ${occupant:-?}" >&2
    done
    echo "stop one and retry, or run --status" >&2
    exit 5
  fi
  if [ "$port" != "$default_port" ]; then
    echo "port :$default_port occupied → using :$port (auto-bumped +$((port - default_port)))"
    occupant="$(port_occupant "$default_port" 2>/dev/null || true)"
    [ -n "$occupant" ] && echo "  :$default_port occupant: $occupant"
  fi
  stage_app "$target_dir" "$app" "$port" "$tunnel_mode" "$port_env"
done
