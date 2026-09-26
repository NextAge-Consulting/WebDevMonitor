#!/usr/bin/env bash
# test-on-edit.sh — PostToolUse hook. Runs a file's test suite the moment the file changes.
#
# THE CONVENTION
#   A file `X.<ext>` is tested by a sibling `X.test.sh`. Editing either one runs it.
#   That is the whole contract — no registry, no config, no runner to keep in sync.
#   Drop a `X.test.sh` next to anything and it is wired up from that moment.
#
# WHY ON EDIT, AND NOT IN CI OR ON SYNC
#   Both of the obvious alternatives test the wrong thing at the wrong time.
#
#   CI runs on a Linux runner. The defect that motivated this was BSD-vs-GNU sed:
#   `\b` is supported by GNU and not by BSD, so a guard hook was silently INERT on
#   every Mac in the shop while an ubuntu runner went green. CI would have certified
#   the breakage. Only running on the actual machine catches a platform difference.
#
#   Sync runs the suite over files nobody just touched — work at the wrong moment,
#   attributed to the wrong change. On edit, the failure lands in front of the person
#   who caused it, while they still have the context to fix it.
#
# EXIT SEMANTICS
#   PostToolUse cannot un-write the edit — the file is already changed. exit 2 does
#   the next best thing: stderr is delivered to Claude in full, naming the failing
#   cases, so the break is known immediately rather than at the next person's expense.
#
#   Set TEST_ON_EDIT=off to skip for one command.

set -uo pipefail

[ "${TEST_ON_EDIT:-on}" = "off" ] && exit 0

payload=$(cat)

file=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print((d.get("tool_input") or {}).get("file_path") or "")
' 2>/dev/null <<<"$payload")

[ -z "$file" ] && exit 0

# Editing the test itself re-runs it; editing the subject runs its sibling.
case "$file" in
  *.test.sh) suite="$file" ;;
  *)         suite="${file%.*}.test.sh" ;;
esac

[ -f "$suite" ] || exit 0
[ -x "$suite" ] || chmod +x "$suite" 2>/dev/null

output=$("$suite" 2>&1)
status=$?

[ "$status" -eq 0 ] && exit 0

cat >&2 <<EOF
🧪 TEST FAILED — $(basename "$file") has a suite, and your edit broke it.

  suite: $suite

$output

This file is covered by a test precisely so a change to it is never tweak-and-pray.
Fix the code, or — if the behaviour change was intended — update the suite in the
same pass so it encodes the new contract. Do not leave it red.
EOF
exit 2
