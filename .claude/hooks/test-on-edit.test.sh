#!/usr/bin/env bash
# Regression suite for test-on-edit.sh — the hook that runs a file's tests on edit.
#
# Testing the tester is not ceremony. This hook is the thing that makes every OTHER
# suite in the kit load-bearing; if it silently stops firing, all of them quietly
# stop mattering and nothing anywhere goes red to say so.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-on-edit.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A subject file with a PASSING suite, and one with a FAILING suite.
printf 'ok\n'                          > "$tmp/good.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/good.test.sh"
printf 'bad\n'                         > "$tmp/bad.sh"
printf '#!/usr/bin/env bash\necho "  x case-42 blew up" >&2\nexit 1\n' > "$tmp/bad.test.sh"
printf 'lonely\n'                      > "$tmp/untested.sh"
chmod +x "$tmp"/*.test.sh

run(){ printf '{"tool_input":{"file_path":"%s"}}' "$1" | "$H" >/dev/null 2>&1; }
t(){ run "$2"; r=$?; if [ "$r" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (exit $r, want $1) — $3"; fail=1; fi; }

echo "MUST PASS (exit 0 — nothing to report):"
t 0 "$tmp/good.sh"       'subject whose suite passes'
t 0 "$tmp/good.test.sh"  'the passing suite itself'
t 0 "$tmp/untested.sh"   'subject with no suite — silent, not an error'
t 0 "$tmp/missing.sh"    'file that does not exist'

echo "MUST BLOCK (exit 2 — edit broke a suite):"
t 2 "$tmp/bad.sh"        'subject whose suite fails'
t 2 "$tmp/bad.test.sh"   'the failing suite itself'

echo "FAILURE OUTPUT reaches Claude:"
out=$(printf '{"tool_input":{"file_path":"%s"}}' "$tmp/bad.sh" | "$H" 2>&1 >/dev/null)
for want in 'case-42' 'bad.test.sh' 'Do not leave it red'; do
  case "$out" in *"$want"*) echo "  ✓ stderr carries: $want" ;;
                 *) echo "  ✗ FAIL — stderr missing: $want"; fail=1 ;; esac
done

echo "DEGENERATE INPUT (never wedge the session):"
deg(){ printf '%s' "$2" | "$H" >/dev/null 2>&1; r=$?; if [ "$r" = 0 ]; then echo "  ✓ $1"; else echo "  ✗ FAIL (exit $r) — $1"; fail=1; fi; }
deg 'malformed json'      'not json at all'
deg 'empty payload'       ''
deg 'no file_path key'    '{"tool_input":{}}'
deg 'null tool_input'     '{"tool_input":null}'

echo "ESCAPE HATCH:"
TEST_ON_EDIT=off run "$tmp/bad.sh"; r=$?
if [ "$r" = 0 ]; then echo "  ✓ TEST_ON_EDIT=off skips a failing suite"; else echo "  ✗ FAIL (exit $r) — escape hatch"; fail=1; fi

exit "$fail"
