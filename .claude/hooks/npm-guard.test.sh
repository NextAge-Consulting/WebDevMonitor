#!/usr/bin/env bash
# Regression suite for npm-guard.sh.
#
# The guard only engages when a package-lock.json EXISTS in the payload cwd — with
# no lockfile, a bare `npm install` is the correct command (it creates one, and
# `npm ci` cannot). Both worlds are exercised here against real temp dirs rather
# than against whatever happens to be in the repo.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/npm-guard.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/locked" "$tmp/fresh"
printf '{}' > "$tmp/locked/package-lock.json"

decision(){
  printf '{"tool_name":"%s","tool_input":{"command":%s},"cwd":"%s"}' "${3:-Bash}" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" "$2" \
  | "$H" 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("allow")
'
}
t(){ d=$(decision "$2" "$3" "${5:-Bash}"); d=${d:-allow}
     if [ "$d" = "$1" ]; then echo "  ✓ $4"; else echo "  ✗ FAIL ($d, want $1) — $4"; fail=1; fi; }

echo "LOCKFILE PRESENT — bare install must be denied:"
t deny  'npm install'                  "$tmp/locked" 'bare npm install'
t deny  'npm i'                        "$tmp/locked" 'bare npm i'
t deny  'npm install --force'          "$tmp/locked" 'bare install with only flags'
t deny  'npm run build && npm install' "$tmp/locked" 'bare install later in a chain'

echo "LOCKFILE PRESENT — deliberate and disciplined commands allowed:"
t allow 'npm ci'                       "$tmp/locked" 'npm ci'
t allow 'npm install zod'              "$tmp/locked" 'install a named package'
t allow 'npm install -D vitest'        "$tmp/locked" 'install -D a named package'
t allow 'npm run test'                 "$tmp/locked" 'npm run'
t allow 'npm test'                     "$tmp/locked" 'npm test'
t allow 'npx vitest'                   "$tmp/locked" 'npx'

echo "NO LOCKFILE — bare install is the RIGHT command, must be allowed:"
t allow 'npm install'                  "$tmp/fresh"  'first install creates the lockfile'
t allow 'npm i'                        "$tmp/fresh"  'bare npm i, no lockfile'

echo "OVERRIDE AND SCOPE:"
t allow 'SKIP_NPM_GUARD=1 npm install' "$tmp/locked" 'documented command-prefix override'
t allow 'npm install'                  "$tmp/locked" 'non-Bash tool is out of scope' Read

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
CWDARG=",\"cwd\":\"$tmp/locked\""
jsonok 'npm install && echo "hi"'
jsonok 'npm install'

rm -f "$tmpout"
exit "$fail"
