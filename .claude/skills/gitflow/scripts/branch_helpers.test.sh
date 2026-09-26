#!/usr/bin/env bash
# Regression suite for the main-drift helpers in branch_helpers.sh.
#
# main_drift_report and main_merge_conflicts decide whether /work, /commit and
# /open-pr warn that main has moved and whether /merge refuses before its build.
# They run against a real origin and clone rather than a mock, because what they
# read IS git's ref and merge state.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/branch_helpers.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
printf 'a\n' > shared.txt; printf 'x\n' > mine.txt
git add -A; git commit -qm base; git push -q origin main

# shellcheck source=./branch_helpers.sh
source "$S"

# Up to date: silent, 0.
out=$(main_drift_report main t 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "up to date is silent" || bad "up to date is silent (rc=$rc out=$out)"

# Someone else lands a commit touching shared.txt.
git clone -q "$tmp/origin.git" "$tmp/other" 2>/dev/null
( cd "$tmp/other" && git config user.email o@example.com && git config user.name o \
  && printf 'theirs\n' > shared.txt && git commit -qam "their change" && git push -q origin main )

# On a stale main with an uncommitted edit to the same file: reports drift AND the overlap.
printf 'ours\n' > shared.txt
out=$(main_drift_report main t 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "stale main returns 10" || bad "stale main returns 10 (rc=$rc)"
grep -q '1 commit(s) behind' <<<"$out" && ok "counts commits behind" || bad "counts commits behind: $out"
grep -q 'their change' <<<"$out" && ok "lists incoming commits" || bad "lists incoming commits: $out"
grep -q '    shared.txt' <<<"$out" && ok "uncommitted overlap reported on main" || bad "uncommitted overlap: $out"
grep -q 'fast-forward main' <<<"$out" && ok "main gets the fast-forward advice" || bad "main advice: $out"

# The same work committed on a feature branch: overlap still reported, branch advice.
git switch -qc feat/x; git commit -qam "our change"
out=$(main_drift_report main t 2>&1); rc=$?
[ "$rc" -eq 10 ] && grep -q '    shared.txt' <<<"$out" && ok "committed overlap reported on a branch" || bad "branch overlap (rc=$rc): $out"
grep -q 'merge main into this branch' <<<"$out" && ok "branch gets the merge advice" || bad "branch advice: $out"
grep -q 'mine.txt' <<<"$out" && bad "untouched file listed as overlap" || ok "only files changed on both sides"

# Trial merge: shared.txt changed differently on both sides → conflict, tree untouched.
before=$(git status --porcelain; git rev-parse HEAD)
out=$(main_merge_conflicts main 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q '    shared.txt' <<<"$out" && ok "conflict detected and named" || bad "conflict (rc=$rc): $out"
[ "$before" = "$(git status --porcelain; git rev-parse HEAD)" ] && ok "trial merge touches nothing" || bad "trial merge changed the checkout"

# Safe inside a set -e caller: a conflict must be reported, not end the caller.
out=$(bash -c "set -eo pipefail; source '$S'; main_merge_conflicts main || echo rc=\$?; echo survived" 2>&1)
grep -q 'survived' <<<"$out" && grep -q 'rc=1' <<<"$out" && ok "safe under set -e" || bad "set -e caller: $out"

# A branch that does not overlap merges cleanly.
git switch -q main; git reset -q --hard origin/main 2>/dev/null || git reset -q --hard "origin/main"
git switch -qc feat/y; printf 'y\n' > mine.txt; git commit -qam "unrelated"
( cd "$tmp/other" && printf 'more\n' >> shared.txt && git commit -qam "more of theirs" && git push -q origin main )
git fetch -q origin main
main_merge_conflicts main 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "non-overlapping drift merges cleanly" || bad "clean merge (rc=$rc)"

exit "$fail"
