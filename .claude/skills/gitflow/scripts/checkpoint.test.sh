#!/usr/bin/env bash
# Regression suite for local checkpoints and the fold that /commit and
# /ship-main perform.
#
# The contract: a checkpoint is a local commit that cuts no branch and pushes
# nothing, and no `🔖 wip:` subject ever reaches origin — /deploy reads
# origin/main's subjects to compute the version bump. Runs the real scripts
# against a real bare origin, because what they change IS git's refs.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

wip_on() { git log --format=%s "$1" | grep -c '^🔖 wip:' || true; }

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
printf 'a\n' > a.txt; git add -A; git commit -qm "chore: base"; git push -q origin main
BASE=$(git rev-parse HEAD)

# ─── /checkpoint on main: local commit, no branch, no push ────────────────
printf 'one\n' > a.txt
"$D/checkpoint.sh" first >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "checkpoint succeeds on main" || bad "checkpoint on main (rc=$rc)"
[ "$(git branch --show-current)" = "main" ] && ok "no branch cut" || bad "branch cut: $(git branch --show-current)"
[ "$(git rev-parse origin/main)" = "$BASE" ] && ok "nothing pushed" || bad "checkpoint pushed"
git log -1 --format=%s | grep -q '^🔖 wip: .* - first$' && ok "checkpoint subject" || bad "subject: $(git log -1 --format=%s)"
"$D/checkpoint.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && ok "empty checkpoint exits 5" || bad "empty checkpoint (rc=$rc)"

# /catchup and /work cannot fast-forward over a checkpoint — and say why.
out=$(bash -c "source '$D/branch_helpers.sh'; fast_forward_local_main" 2>&1); rc=$?
[ "$rc" -eq 7 ] && grep -q 'checkpoint' <<<"$out" && ok "fast-forward names the checkpoints" || bad "fast-forward (rc=$rc): $out"

# ─── A failing gate leaves the checkpoints alone ──────────────────────────
printf 'two\n' > b.txt
"$D/checkpoint.sh" second >/dev/null 2>&1
printf '{"scripts":{"check-types":"exit 1"}}\n' > package.json
"$D/commit.sh" --message "feat: add b" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] && ok "typecheck gate fails the commit" || bad "gate (rc=$rc)"
[ "$(git branch --show-current)" = "feat/add-b" ] && ok "branch cut before the gate" || bad "branch: $(git branch --show-current)"
[ "$(wip_on HEAD)" -eq 2 ] && ok "checkpoints intact after a failed gate" || bad "checkpoints after failed gate: $(wip_on HEAD)"
[ "$(git rev-parse main)" = "$BASE" ] && ok "main no longer carries the checkpoints" || bad "main still at $(git rev-parse main)"
rm package.json

# ─── /commit folds them into one real commit ──────────────────────────────
"$D/commit.sh" --message "feat: add b" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "commit succeeds" || bad "commit (rc=$rc)"
[ "$(git rev-list --count "$BASE"..HEAD)" -eq 1 ] && ok "one commit above base" || bad "commits above base: $(git rev-list --count "$BASE"..HEAD)"
[ "$(git log -1 --format=%s)" = "feat: add b" ] && ok "real subject" || bad "subject: $(git log -1 --format=%s)"
[ "$(git show HEAD:a.txt)" = "one" ] && [ "$(git show HEAD:b.txt)" = "two" ] && ok "folded content kept" || bad "folded content"
[ "$(wip_on origin/feat/add-b)" -eq 0 ] && ok "no checkpoint reached origin" || bad "checkpoint on origin"

# ─── A pushed checkpoint is never folded (that would need a force-push) ────
printf 'three\n' > c.txt
"$D/checkpoint.sh" >/dev/null 2>&1
git push -q origin feat/add-b
PUSHED=$(git rev-parse HEAD)
printf 'four\n' > d.txt
"$D/checkpoint.sh" >/dev/null 2>&1
"$D/commit.sh" --message "feat: add d" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(git rev-parse HEAD^)" = "$PUSHED" ] && ok "folds only the unpushed checkpoint" || bad "pushed checkpoint (rc=$rc)"

# ─── /ship-main folds them too ─────────────────────────────────────────────
git switch -q main
printf 'five\n' > e.txt
"$D/checkpoint.sh" >/dev/null 2>&1
printf 'six\n' > f.txt
"$D/checkpoint.sh" >/dev/null 2>&1
"$D/ship-main.sh" --message "chore: ship e and f" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "ship-main succeeds" || bad "ship-main (rc=$rc)"
[ "$(git rev-list --count "$BASE"..origin/main)" -eq 1 ] && ok "one commit landed on main" || bad "commits on main: $(git rev-list --count "$BASE"..origin/main)"
[ "$(wip_on origin/main)" -eq 0 ] && ok "no checkpoint on origin/main" || bad "checkpoint on origin/main"
[ "$(git show origin/main:f.txt)" = "six" ] && ok "shipped content kept" || bad "shipped content"

exit "$fail"
