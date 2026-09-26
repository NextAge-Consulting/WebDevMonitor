#!/usr/bin/env bash
# Regression suite for block-kit-edit.sh.
#
# TWO behaviours are load-bearing and pull in opposite directions, so both are pinned:
#
#   1. `mode` decides, never the presence of the manifest key. An `owned` file is the
#      kit's and is blocked; a `template` file was merely seeded by the kit and the
#      PROJECT owns it from there — blocking those would stop a project editing its
#      own ui-inventory or ci.yml.
#   2. The maintainer marker (~/.claude/kitmaster) makes the whole hook inert.
#
# HOME is redirected at a temp dir throughout so the suite tests real logic rather
# than whatever the machine running it happens to be. On the maintainer's own machine
# the marker exists, and without this the guarded cases would all vacuously "pass".
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-kit-edit.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/proj/.claude" "$tmp/consumer-home/.claude" "$tmp/maintainer-home/.claude"
touch "$tmp/maintainer-home/.claude/kitmaster"
cat > "$tmp/proj/.claude/.kit-sync.json" <<'JSON'
{"files":{
  ".claude/rules/constitution.md":      {"mode":"owned"},
  ".claude/hooks/git-guard.sh":         {"mode":"owned"},
  ".claude/rules/project/ui-inventory.md": {"mode":"template"},
  ".github/workflows/ci.yml":           {"mode":"template"},
  ".claude/legacy-bare-string.md":      "some-hash"
}}
JSON

decision(){  # $1 path  $2 tool  $3 home
  printf '{"tool_name":"%s","tool_input":{"file_path":%s}}' "$2" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | HOME="$3" CLAUDE_PROJECT_DIR="$tmp/proj" "$H" 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("malformed")
'
}
t(){ d=$(decision "$2" "${5:-Edit}" "${6:-$tmp/consumer-home}"); d=${d:-allow}
     if [ "$d" = "$1" ]; then echo "  ✓ $4"; else echo "  ✗ FAIL ($d, want $1) — $4"; fail=1; fi; }

echo "CONSUMER MACHINE — mode:owned is the kit's, must be denied:"
t deny "$tmp/proj/.claude/rules/constitution.md" x 'owned rule, absolute path'
t deny ".claude/rules/constitution.md"           x 'owned rule, relative path'
t deny "$tmp/proj/.claude/hooks/git-guard.sh"    x 'owned hook'
t deny "$tmp/proj/.claude/legacy-bare-string.md" x 'legacy bare-string entry means owned'
t deny "$tmp/proj/.claude/rules/constitution.md" x 'owned rule via Write' Write

echo "CONSUMER MACHINE — MultiEdit is a write path too:"
t deny "$tmp/proj/.claude/rules/constitution.md" x 'owned rule via MultiEdit' MultiEdit
t deny "$tmp/proj/.claude/hooks/git-guard.sh"    x 'owned hook via MultiEdit' MultiEdit

echo "CONSUMER MACHINE — mode:template is the PROJECT'S, must be allowed:"
t allow "$tmp/proj/.claude/rules/project/ui-inventory.md" x 'template: ui-inventory'
t allow "$tmp/proj/.github/workflows/ci.yml"              x 'template: ci.yml'

echo "CONSUMER MACHINE — files the kit does not manage:"
t allow "$tmp/proj/apps/shared/src/index.ts"   x 'ordinary source file'
t allow "$tmp/proj/.claude/settings.local.json" x 'project-local settings'
t allow "/etc/hosts"                            x 'absolute path outside the project'
t allow "$tmp/proj/.claude/rules/constitution.md" x 'non-Edit/Write tool is out of scope' Bash

echo "MAINTAINER MACHINE — the kitmaster marker makes the hook inert:"
t allow "$tmp/proj/.claude/rules/constitution.md" x 'owned rule passes for the maintainer' Edit "$tmp/maintainer-home"
t allow "$tmp/proj/.claude/hooks/git-guard.sh"    x 'owned hook passes for the maintainer' Edit "$tmp/maintainer-home"

echo "NO MANIFEST — a non-kit project must be untouched:"
mkdir -p "$tmp/bare/.claude"
nm=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$tmp/bare/.claude/rules/x.md" \
     | HOME="$tmp/consumer-home" CLAUDE_PROJECT_DIR="$tmp/bare" "$H" 2>/dev/null)
if [ -z "$nm" ]; then echo "  ✓ no .kit-sync.json → nothing guarded"; else echo "  ✗ FAIL — blocked in a non-kit project"; fail=1; fi

echo "DEGENERATE INPUT (never wedge the session):"
for p in 'not json' '' '{"tool_name":"Edit"}' '{"tool_name":"Edit","tool_input":{}}'; do
  printf '%s' "$p" | HOME="$tmp/consumer-home" CLAUDE_PROJECT_DIR="$tmp/proj" "$H" >/dev/null 2>&1
  if [ $? -le 1 ]; then echo "  ✓ survives: ${p:-（empty）}"; else echo "  ✗ FAIL — crashed on: $p"; fail=1; fi
done

exit "$fail"
