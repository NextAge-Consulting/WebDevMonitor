#!/bin/bash
# gitflow catchup: refresh local code from origin. Two execution paths
# depending on which branch is checked out at invocation time:
#
#   1. On main/master (between bodies of work, OR user just wants latest code
#      for review) — fetches origin/<base> and fast-forwards local main.
#      Refuses if local main has diverged (has local-only commits).
#
#   2. On a feature branch — merges
#      origin/<base> INTO the feature branch via --no-ff so the integration
#      is a visible merge commit.
#
# Usage: catchup.sh [--base main]
#        catchup.sh --continue        # after manual conflict resolution (feature-branch path only)
#        catchup.sh --abort           # abort an in-progress merge (feature-branch path only)
#
# Why this exists. Two related failure modes:
#   - Feature branch falls behind main while in flight. The eventual /merge
#     may hit a 3-way conflict GitHub can't auto-resolve (e.g. both branches
#     inserted entries under the same changelog anchor — observed 2026-05-12
#     on PRs #147/#148). Code touched by the upstream change diverges from
#     the branch's assumptions, surfacing as runtime breakage post-merge.
#   - Local main goes stale between sessions. A dev starts /work two days
#     after another dev's merges + deploys; /work fast-forwards main when it
#     can but skips on a dirty tree or a failed fetch, and the next branch is
#     then cut off a stale main. This primitive makes the refresh explicit and
#     fail-loud.
#
# Before this primitive existed, the only paths were (a) `git merge origin/main`
# (forbidden direct git per .claude/rules/git.md), (b) `git rebase origin/main`
# (same), or (c) close the PR and re-open from a fresh branch off updated
# main. (c) was the tonight-of-2026-05-12 workaround — works but wastes a PR
# cycle. /catchup is the proper path.
#
# Mode = default — main path (on protected branch):
#   - Delegates to fast_forward_local_main in branch_helpers.sh.
#   - Refuses if dirty (main should never be dirty under gitflow's model).
#   - Refuses if local main has commits not on origin/main (anomalous).
#   - Fast-forwards on a clean ancestry path. Reports old → new SHA.
#
# Mode = default — feature path (on non-protected branch):
#   - Refuses on detached HEAD.
#   - Refuses if working tree is dirty (uncommitted or untracked files).
#     Rationale: `git merge` into a dirty tree mixes states the user can't
#     easily separate. Either commit/checkpoint first, or stash externally.
#   - Refuses if a merge is already in progress (MERGE_HEAD exists). Caller
#     must --continue or --abort first.
#   - Fetches origin/<base>.
#   - If HEAD already contains origin/<base> (already up-to-date), reports
#     and exits 0 without creating a merge commit.
#   - Otherwise runs `git merge --no-ff origin/<base>` so the integration is
#     a visible merge commit (not a stealth fast-forward). On clean merge:
#     pushes via safe_push and reports.
#   - On conflict: leaves the tree in conflict state, lists the conflicting
#     paths, prints the resolution recipe, and exits non-zero (code 6). The
#     caller (Claude / human) resolves the conflicts in-tree using Edit /
#     editor, then invokes `catchup.sh --continue`.
#
# Mode = --continue (after conflict resolution):
#   - Requires MERGE_HEAD to exist (refuses if there's no merge to continue).
#   - Verifies no conflict markers remain in tracked files via `git diff --check`.
#   - Stages everything, completes the merge commit with git's default
#     merge message (--no-edit), pushes via safe_push.
#
# Mode = --abort:
#   - Requires MERGE_HEAD. Invokes `git merge --abort` to restore the tree
#     to its pre-merge state. Useful when the conflict surface is too large
#     to resolve sanely and the caller prefers re-doing the work in a fresh
#     branch off new main.
#
# Not responsibilities:
#   - No rebase mode. /catchup is merge-based by design: preserves branch
#     history, no force-push needed, plays cleanly with GitHub PR diffs.
#     If you genuinely want a rebase, do it manually (and use SKIP_GIT_GUARD
#     for the `git rebase` call) — that's the rare-case escape hatch, not
#     a primitive.
#   - Does not run typecheck or lint. The merge commit may surface issues
#     that need follow-up commits; those go through /commit normally.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"

BASE="main"
MODE="default"

while [[ $# -gt 0 ]]; do
    case $1 in
        --base)       BASE="$2"; shift 2 ;;
        --continue)   MODE="continue"; shift 1 ;;
        --abort)      MODE="abort"; shift 1 ;;
        *) echo "catchup.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || {
    echo "catchup.sh: not in a git working tree." >&2
    exit 3
}

# ─── Mode: --abort ─────────────────────────────────────────────────────────
if [ "$MODE" = "abort" ]; then
    if [ ! -f "$GIT_DIR/MERGE_HEAD" ]; then
        echo "catchup.sh: no merge in progress (no MERGE_HEAD)." >&2
        exit 4
    fi
    echo "gitflow: aborting in-progress merge." >&2
    git merge --abort
    echo "gitflow: merge aborted. Working tree restored to pre-merge state." >&2
    exit 0
fi

# ─── Mode: --continue ──────────────────────────────────────────────────────
if [ "$MODE" = "continue" ]; then
    if [ ! -f "$GIT_DIR/MERGE_HEAD" ]; then
        echo "catchup.sh: no merge in progress (no MERGE_HEAD)." >&2
        echo "  Run catchup.sh (without --continue) to start a fresh merge." >&2
        exit 4
    fi
    # Refuse if conflict markers remain. `git diff --check` exits non-zero
    # when it finds conflict markers OR whitespace errors in staged/unstaged
    # diffs. For our purposes both deserve attention before completing the
    # merge — markers obviously, and whitespace errors because they signal
    # a half-edited resolution.
    if ! git diff --check >/dev/null 2>&1; then
        echo "catchup.sh: conflict markers or whitespace errors detected in tree." >&2
        echo "  Run 'git diff --check' to inspect. Resolve fully, then re-run catchup.sh --continue." >&2
        exit 5
    fi
    git add -A
    if git diff --cached --quiet; then
        echo "catchup.sh: nothing staged for merge commit. Either the conflict resolution was empty (no real changes) or files were not actually edited. Inspect 'git status' before retrying." >&2
        exit 5
    fi
    # --no-edit accepts git's default merge message; --no-verify skips
    # pre-commit hooks (the merge itself doesn't need typecheck — that
    # ran on the source PRs).
    echo "gitflow: completing merge commit." >&2
    git commit --no-verify --no-edit
    echo "gitflow: pushing merged HEAD." >&2
    # shellcheck disable=SC2119 # safe_push takes no args by design (reads current branch + upstream from git state)
    safe_push
    echo "gitflow: catchup complete on $(git branch --show-current)." >&2
    exit 0
fi

# ─── Mode: default (start a merge) ─────────────────────────────────────────

# Refuse if a merge is already in progress.
if [ -f "$GIT_DIR/MERGE_HEAD" ]; then
    echo "catchup.sh: a merge is already in progress (MERGE_HEAD exists)." >&2
    echo "  Either: resolve conflicts and run 'catchup.sh --continue', or 'catchup.sh --abort'." >&2
    exit 4
fi

CURRENT_BRANCH=$(git branch --show-current)
if [ -z "$CURRENT_BRANCH" ]; then
    echo "catchup.sh: detached HEAD — refusing to catch up." >&2
    exit 3
fi

# ─── Main-branch path: fast-forward local main from origin/main ────────────
# On a protected branch (main / master): no body of work in flight, or the user
# is just refreshing local code for review. Delegate
# to the shared helper; do NOT fall through to the feature-branch merge path
# below (would be a circular merge of main into itself).
if is_protected_branch "$CURRENT_BRANCH"; then
    fast_forward_local_main
    rc=$?
    exit $rc
fi

# ─── Feature-branch path: merge origin/<base> INTO current feature ─────────

# Refuse on dirty tree. Same conditions as tree_is_clean in work.sh:
# no uncommitted (working / staged) AND no untracked files (excluding
# .gitignore'd). Rationale: `git merge` into a dirty tree forces the user
# to disentangle states post-merge.
if ! git diff --quiet 2>/dev/null \
   || ! git diff --cached --quiet 2>/dev/null \
   || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    echo "catchup.sh: working tree has uncommitted or untracked changes." >&2
    echo "  /commit or /checkpoint first (or stash), then re-run catchup.sh." >&2
    exit 5
fi

echo "gitflow: fetching origin/$BASE." >&2
# Explicit return-code check; do NOT pipe into sed for cosmetic indent here.
# Without `set -o pipefail` (this script uses `set -e` alone for bash 3.2
# compatibility — see .claude/rules/bash-rules.md), `sed`'s exit code (always
# 0) masks any `git fetch` failure, silently passing the gate and proceeding
# to merge against a stale origin/<base>.
if ! git fetch origin "$BASE"; then
    echo "catchup.sh: 'git fetch origin $BASE' failed." >&2
    exit 6
fi

# Already up-to-date? HEAD contains origin/<base> with no new commits there.
# `git merge-base --is-ancestor origin/<base> HEAD` exits 0 if origin/<base>
# is an ancestor of HEAD (i.e. HEAD already contains it). No merge needed.
if git merge-base --is-ancestor "origin/$BASE" HEAD 2>/dev/null; then
    echo "gitflow: $CURRENT_BRANCH already contains origin/$BASE — no merge needed." >&2
    exit 0
fi

echo "gitflow: merging origin/$BASE into $CURRENT_BRANCH (--no-ff, explicit merge commit)." >&2
set +e
git merge --no-ff --no-edit "origin/$BASE"
MERGE_RC=$?
set -e

if [ "$MERGE_RC" -ne 0 ]; then
    # `git merge` returns non-zero on conflict (1) or fatal (>1). For both
    # cases the user should inspect; the actionable path differs only by
    # whether MERGE_HEAD exists.
    if [ -f "$GIT_DIR/MERGE_HEAD" ]; then
        echo "" >&2
        echo "catchup.sh: merge produced conflicts. Conflicting paths:" >&2
        git diff --name-only --diff-filter=U | sed 's/^/  /' >&2
        echo "" >&2
        echo "Resolution recipe:" >&2
        echo "  1. Edit each conflicting file to remove <<<<<<<, =======, >>>>>>> markers." >&2
        echo "  2. Verify with: git diff --check" >&2
        echo "  3. Complete the merge: catchup.sh --continue" >&2
        echo "  4. Or bail entirely: catchup.sh --abort" >&2
        exit 6
    else
        echo "catchup.sh: 'git merge' failed without leaving MERGE_HEAD. Inspect 'git status' before retrying." >&2
        exit 6
    fi
fi

echo "gitflow: clean merge — pushing." >&2
# shellcheck disable=SC2119 # safe_push takes no args by design (reads current branch + upstream from git state)
safe_push
echo "gitflow: catchup complete on $CURRENT_BRANCH (now contains origin/$BASE)." >&2
