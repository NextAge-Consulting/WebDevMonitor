#!/usr/bin/env bash
# Regression suite for work.sh --discussion.
#
# The human pastes whichever handle is to hand — the folder slug, or the artifact URL
# copied from a browser tab with whatever query or fragment it carried — so both must
# land on the same folder, and a miss must fail before the default mode touches main.
# Runs against a real clone because the default mode reads and refreshes git state.
set -uo pipefail
W="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/work.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# work.sh refuses when a global /work command exists; keep this machine's out of it.
export HOME="$tmp/home"; mkdir -p "$HOME"

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
d=project-documentation/temporary/discussion-session-timeout
mkdir -p "$d"
cat > "$d/session-timeout-discussion.md" <<'MD'
---
slug: session-timeout
artifact: https://claude.ai/code/artifact/0b1c2d3e-aaaa-bbbb-cccc-111122223333
published: 2026-09-24
---
# Session Timeout Review

- D1 — Which option?
MD
printf '{}\n' > "$d/session-timeout.json"
printf 'reply\n' > "$d/feedback-product-owner.md"
git add -A; git commit -qm base; git push -q origin main

run() { out=$("$W" "$@" 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err"); }

run --discussion session-timeout
[ "$rc" -eq 0 ] && ok "slug resolves" || bad "slug resolves (rc=$rc): $err"
grep -q 'D1 — Which option?' <<<"$out" && ok "pointer printed" || bad "pointer printed: $out"
grep -q 'feedback-product-owner.md' <<<"$out" && ok "folder files listed" || bad "folder files listed: $out"
grep -q 'no branch cut' <<<"$err" && ok "default mode ran" || bad "default mode ran: $err"

run --discussion discussion-session-timeout/
[ "$rc" -eq 0 ] && ok "folder name resolves" || bad "folder name resolves (rc=$rc): $err"

run --discussion 'https://claude.ai/code/artifact/0b1c2d3e-aaaa-bbbb-cccc-111122223333/?tab=comments#d1'
[ "$rc" -eq 0 ] && grep -q 'session-timeout-discussion.md' <<<"$out" && ok "URL with query and fragment resolves" || bad "URL resolves (rc=$rc): $err"

# The shape a published artifact link actually takes: a short id, no /code/ segment.
sed -i.bak 's#^artifact: .*#artifact: https://claude.ai/artifact/18Rnsr3c5BD6ZzRmwmVuUY#' "$d/session-timeout-discussion.md" && rm "$d/session-timeout-discussion.md.bak"
run --discussion 'https://claude.ai/artifact/18Rnsr3c5BD6ZzRmwmVuUY'
[ "$rc" -eq 0 ] && ok "short artifact link resolves" || bad "short artifact link resolves (rc=$rc): $err"

before=$(git rev-parse HEAD)
run --discussion https://claude.ai/code/artifact/ffffffff-0000-0000-0000-000000000000
[ "$rc" -eq 4 ] && ok "unknown URL exits 4" || bad "unknown URL exits 4 (rc=$rc)"
grep -q 'session-timeout  https://claude.ai' <<<"$err" && ok "miss lists open discussions" || bad "miss lists open discussions: $err"
grep -q 'no branch cut' <<<"$err" && bad "miss ran the default mode" || ok "miss runs nothing else"
[ "$before" = "$(git rev-parse HEAD)" ] || bad "miss moved HEAD"

run --discussion nope
[ "$rc" -eq 4 ] && ok "unknown slug exits 4" || bad "unknown slug exits 4 (rc=$rc)"

run --discussion
[ "$rc" -eq 2 ] && ok "missing value exits 2" || bad "missing value exits 2 (rc=$rc): $err"

run --discussion session-timeout --retrieve main
[ "$rc" -eq 2 ] && ok "conflicting mode exits 2" || bad "conflicting mode exits 2 (rc=$rc)"

exit "$fail"
