#!/usr/bin/env bash
# Regression suite for dev-server-guard.sh — rule 4 of rules/dev-server.md,
# "never kill processes you didn't start".
#
# The allow half carries the weight. An earlier version of this guard also blocked
# `npm run dev` outright, which forced a permission round-trip on every legitimate
# E2E run; that over-correction is the thing these allow-cases exist to keep out.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dev-server-guard.sh"
fail=0

decision(){
  printf '{"tool_name":"%s","tool_input":{"command":%s}}' "${2:-Bash}" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | "$H" 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("allow")
'
}
t(){ d=$(decision "$2" "${4:-Bash}"); d=${d:-allow}
     if [ "$d" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL ($d, want $1) — $3"; fail=1; fi; }

echo "MUST DENY — killing a server you did not start:"
t deny 'pkill -f vite'                          'pkill vite'
t deny 'pkill -f "npm run dev"'                 'pkill npm dev'
t deny 'pkill -f node.*dev'                     'pkill node dev'
t deny 'fuser -k 3001/tcp'                      'fuser -k'
t deny 'kill -9 $(pgrep -f vite)'               'kill -9 vite'
t deny 'kill $(lsof -t -i:3001)'                'kill $(lsof ...)'
t deny 'lsof -ti:3001 | xargs kill'             'lsof | xargs kill'

echo "MUST ALLOW — heredoc bodies are data being written, not commands being run:"
t allow 'cat > doc.md <<EOF
never run pkill -f vite
EOF' 'heredoc quoting pkill -f vite'
t allow 'cat > rules.md <<EOF
Applies to kill, kill -9, pkill, fuser -k, and docker stop.
EOF' 'heredoc quoting the whole pattern list'

echo "MUST STILL DENY — a real kill outside the heredoc:"
t deny 'cat > doc.md <<EOF
harmless text
EOF
pkill -f vite' 'pkill after a heredoc'

echo "MUST ALLOW — starting and inspecting:"
t allow 'npm run dev'                           'starting a dev server'
t allow 'npm run dev:shop'                      'starting a named app'
t allow 'lsof -iTCP:3001 -sTCP:LISTEN'          'checking the port (rule 1)'
t allow 'tail -f logs/server.log'               'reading logs'
t allow 'curl http://localhost:3001'            'hitting the server'
t allow 'agent-browser close'                   'browser teardown'
t allow 'npm test'                              'running tests'

echo "MUST ALLOW — kills unrelated to dev servers:"
t allow 'pkill -f agent-browser'                'agent-browser daemon is Claude-owned'
t allow 'kill -9 12345'                         'a bare pid'

echo "OVERRIDE AND SCOPE:"
t allow 'SKIP_SERVER_GUARD=1 pkill -f vite'     'documented command-prefix override'
t allow 'pkill -f vite' 'non-Bash tool is out of scope' Read

echo "DEGENERATE INPUT (never wedge the session):"
for p in 'not json' '' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}'; do
  printf '%s' "$p" | "$H" >/dev/null 2>&1
  if [ $? -le 1 ]; then echo "  ✓ survives: ${p:-（empty）}"; else echo "  ✗ FAIL — crashed on: $p"; fail=1; fi
done


echo "DENY PAYLOAD MUST BE VALID JSON (a malformed deny is silently discarded):"
jsonok(){
  printf '{"tool_name":"Bash","tool_input":{"command":%s}%s}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" "$CWDARG" \
  | "$H" 2>/dev/null > "$tmpout"
  if [ ! -s "$tmpout" ]; then echo "  ✗ FAIL — expected a deny, got allow: $1"; fail=1; return; fi
  if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmpout" 2>/dev/null; then
    echo "  ✓ parses: $1"
  else echo "  ✗ FAIL — MALFORMED deny payload: $1"; fail=1; fi; }
tmpout=$(mktemp)
CWDARG=""
jsonok 'pkill -f "npm run dev"'
jsonok 'fuser -k 3001/tcp'

rm -f "$tmpout"
exit "$fail"
