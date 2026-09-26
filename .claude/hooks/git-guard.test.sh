#!/usr/bin/env bash
# Regression suite for git-guard.sh.
#
# This guard signals a block with PreToolUse JSON on STDOUT (permissionDecision:
# deny) and always exits 0 — so exit status proves nothing here and the assertions
# read the decision out of the payload.
#
# The allow-list half is the delicate part. Branch operations (`git checkout -b`,
# bare branch switch) MUST stay allowed: gitflow's own scripts run them, and a
# false block there breaks /work and /commit rather than merely annoying someone.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-guard.sh"
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

echo "MUST DENY — destructive:"
t deny 'git reset --hard origin/main'      'reset --hard'
t deny 'git reset'                         'bare reset'
t deny 'git restore src/app.ts'            'restore'
t deny 'git revert HEAD'                   'revert'
t deny 'git clean -fd'                     'clean'
t deny 'git checkout .'                    'checkout . (whole tree)'
t deny 'git checkout -- src/app.ts'        'checkout -- file'
t deny 'git checkout main src/app.ts'      'checkout branch + path'

echo "MUST DENY — workflow routing:"
t deny 'git commit -m "wip"'               'raw commit'
t deny 'git commit'                        'bare commit'
t deny 'npm test && git reset --hard'      'destructive in a compound command'
t deny 'cd /tmp; git clean -fd'            'destructive after a semicolon'

echo "MUST ALLOW — branch ops gitflow depends on:"
t allow 'git checkout -b feat/thing'       'checkout -b'
t allow 'git checkout -B feat/thing'       'checkout -B'
t allow 'git checkout main'                'bare branch switch'
t allow 'git checkout --track origin/x'    'checkout --track'
t allow 'git checkout --detach'            'checkout --detach'

echo "MUST ALLOW — heredoc bodies are data being written, not commands being run:"
t allow 'cat > doc.md <<EOF
git reset --hard is forbidden
EOF' 'heredoc quoting git reset'
t allow 'cat > rules.md <<EOF
never run git clean -fd or git checkout -- file
EOF' 'heredoc quoting clean and checkout'
t allow 'echo "never run git clean -fd" > notes.txt' 'prose in an echo'

echo "MUST STILL DENY — a real command outside the heredoc:"
t deny 'cat > doc.md <<EOF
harmless text
EOF
git reset --hard' 'reset after a heredoc'

echo "MUST ALLOW — read-only:"
t allow 'git status'                       'status'
t allow 'git log --oneline -5'             'log'
t allow 'git diff HEAD'                    'diff'
t allow 'git commit-tree abc123'           'commit-tree is NOT commit'
t allow 'echo "git reset is blocked"'      'the words inside a non-git command'

echo "MUST ALLOW — override and scope:"
t allow 'SKIP_GIT_GUARD=1 git reset --hard'  'documented override'
t allow 'git reset --hard' 'non-Bash tool is out of scope' Read

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
jsonok 'git commit -m "wip"'
jsonok 'git reset --hard'
jsonok 'git clean -fd'

rm -f "$tmpout"
exit "$fail"
