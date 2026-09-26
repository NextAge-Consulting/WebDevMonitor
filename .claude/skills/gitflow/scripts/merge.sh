#!/bin/bash
# gitflow merge: squash-merge current branch's PR after CI passes, then land on main.
# Usage: merge.sh [--pr <number>] [--base main] [--force-unchecked]
#
# If --pr is not provided, the script uses the PR associated with the current branch.
# If multiple open PRs exist for the current branch, the script lists them and exits —
# caller must re-invoke with --pr <number>.
#
# --force-unchecked bypasses the CI-passed gate AND the production build gate. Use only
# for emergency hotfixes with explicit user authorization.
#
# Production build gate (exit 15): `npm run build --workspaces --if-present` runs LOCALLY
# before the squash. CI does not build — it type-checks, lints and tests — so a build-only
# break (bundler, Tailwind, an import alias a package's own tsconfig does not map) is
# invisible to every earlier gate. This is the last moment the PR is still OPEN, which is
# the whole point: a failure here is fixed on the branch that caused it, in the PR that is
# already under review. Catching it at /deploy instead means the branch is gone and the
# only possible remedy is a second PR to repair the first.
#
# It is NOT in CI on purpose: CI fires on every push, so building there would tax every
# commit, every /open-pr and every triage fix with a full build. Once per merge is the
# right frequency.
#
# Post-merge cleanup:
#   - Switch this checkout to the base branch and fast-forward it to the merged tip.
#   - Delete the now-merged local branch (the remote one is deleted server-side).
#   - Reinstall dependencies if landing on the new base changed a manifest.
#
# The body of work ends here. The next `/work` starts a fresh branch off the
# base you are now standing on.

set -eo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # propagate errexit into $(…) subshells (bash 4.4+)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"

PR_NUMBER=""
BASE="main"
FORCE_UNCHECKED=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --pr)                PR_NUMBER="$2"; shift 2 ;;
        --base)              BASE="$2"; shift 2 ;;
        --force-unchecked)   FORCE_UNCHECKED=1; shift 1 ;;
        *) echo "merge.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

if ! command -v gh >/dev/null 2>&1; then
    echo "merge.sh: gh CLI is required for merge (squash-merge via REST API is not implemented here)." >&2
    echo "  Install: brew install gh  then: gh auth login" >&2
    exit 8
fi

# Read the current branch with explicit failure handling. set -e + the
# simple-substitution case would catch a non-zero exit from 'git branch'
# on bash 3.2 the same as 4.4+, but the explicit pattern lets us emit a
# specific diagnostic on git failure vs detached HEAD vs already-on-main.
if ! CURRENT_BRANCH=$(git branch --show-current); then
    echo "merge.sh: 'git branch --show-current' failed. Inspect with 'git status'." >&2
    exit 15
fi
if [ -z "$CURRENT_BRANCH" ]; then
    echo "merge.sh: detached HEAD — no branch to merge." >&2
    echo "  /merge operates on a named branch's PR. Check out the body-of-work branch first." >&2
    exit 14
fi
if [ "$CURRENT_BRANCH" = "$BASE" ]; then
    echo "merge.sh: already on $BASE. Nothing to merge." >&2
    exit 3
fi

# ─── Locate the checkout ───────────────────────────────────────────────────
# Explicit failure handling — the script cannot operate without knowing where
# it is, and the explicit pattern works identically on bash 3.2 (where
# 'shopt -s inherit_errexit' is a no-op) and bash 4.4+.
if ! REPO_ROOT=$(git rev-parse --show-toplevel); then
    echo "merge.sh: 'git rev-parse --show-toplevel' failed — not in a git working tree." >&2
    exit 16
fi

# The pre-merge tip of the feature branch. Compared against the merged base
# further down to decide whether dependencies need reinstalling.
if ! PRE_MERGE_SHA=$(git rev-parse HEAD); then
    echo "merge.sh: 'git rev-parse HEAD' failed — cannot record the pre-merge commit." >&2
    exit 16
fi

# Resolve PR number if not provided
if [ -z "$PR_NUMBER" ]; then
    PR_LIST=$(gh pr list --head "$CURRENT_BRANCH" --state open --json number,title,url)
    COUNT=$(echo "$PR_LIST" | jq 'length')
    if [ "$COUNT" -eq 0 ]; then
        echo "merge.sh: no open PR found for branch $CURRENT_BRANCH." >&2
        echo "  Run /open-pr first." >&2
        exit 9
    fi
    if [ "$COUNT" -gt 1 ]; then
        echo "merge.sh: multiple open PRs for branch $CURRENT_BRANCH:" >&2
        echo "$PR_LIST" | jq -r '.[] | "  #\(.number) \(.title) — \(.url)"' >&2
        echo "  Re-invoke with --pr <number>." >&2
        exit 10
    fi
    PR_NUMBER=$(echo "$PR_LIST" | jq -r '.[0].number')
fi

echo "gitflow: target PR #$PR_NUMBER" >&2
echo "gitflow: merging '$CURRENT_BRANCH' in $REPO_ROOT" >&2

# ─── Base drift gate (exit 23) ─────────────────────────────────────────────
# Before the build and the readiness wait: a PR that conflicts with its base
# cannot squash, and finding that out after several minutes of building and
# polling is the failure this exists to prevent. A trial merge is local and
# exact; drift that merges cleanly is reported and the merge goes ahead.
if [ "$FORCE_UNCHECKED" -eq 0 ] && ! main_drift_report "$BASE" merge.sh; then
    main_merge_conflicts "$BASE" && CONFLICT=0 || CONFLICT=$?
    case "$CONFLICT" in
        0) echo "gitflow: $BASE moved, but it merges cleanly — continuing." >&2 ;;
        1) echo "merge.sh: PR #$PR_NUMBER conflicts with origin/$BASE in the files above." >&2
           echo "  Run /catchup, resolve, and /merge again. Nothing was merged." >&2
           exit 23 ;;
        *) echo "gitflow: could not trial-merge origin/$BASE (git 2.38+ needed) — continuing." >&2 ;;
    esac
fi

# ─── Production build gate ─────────────────────────────────────────────────
# Runs BEFORE the readiness wait: a build break should fail in seconds, not after
# several minutes of polling CI and Gemini for a merge that is not going to happen.
# `--if-present` skips any workspace with no build script, so a repo with none is a
# no-op. Non-Node repos have no package.json and skip the block entirely.
if [ "$FORCE_UNCHECKED" -eq 0 ] && [ -f "$REPO_ROOT/package.json" ]; then
    # `--workspaces` ERRORS with "No workspaces found!" on a single-package repo, so it
    # is used only when the manifest actually declares them.
    #
    # jq, not grep: `grep '"workspaces"'` matches the substring ANYWHERE — a dependency
    # of that name, a script, a description — and a false positive here blocks a merge
    # that should have proceeded, which is how a gate ends up disabled. jq asks the exact
    # question (top-level key, present or not) and handles both the array and object
    # forms. It is already a hard dependency of this script.
    if jq -e 'has("workspaces")' "$REPO_ROOT/package.json" >/dev/null 2>&1; then
        BUILD_ARGS="--workspaces --if-present"
    else
        BUILD_ARGS="--if-present"
    fi
    echo "gitflow: running production build (npm run build $BUILD_ARGS)..." >&2
    # shellcheck disable=SC2086 # BUILD_ARGS is two known literal flags, not user input
    if ! (cd "$REPO_ROOT" && npm run build $BUILD_ARGS); then
        echo "merge.sh: production build FAILED — nothing merged." >&2
        echo "  Fix it on this branch and push; the PR is still open, so the fix lands" >&2
        echo "  in the PR that caused it rather than in a follow-up." >&2
        exit 15
    fi
    echo "gitflow: production build OK." >&2
fi

# Verify CI passed AND Gemini Code Assist has reviewed current HEAD (unless bypass).
if [ "$FORCE_UNCHECKED" -eq 0 ]; then
    WAIT_SCRIPT="$SCRIPT_DIR/wait-for-pr-ready.sh"
    if [ ! -x "$WAIT_SCRIPT" ]; then
        echo "merge.sh: $WAIT_SCRIPT missing or not executable." >&2
        exit 12
    fi

    echo "gitflow: verifying PR is ready (CI green + Gemini reviewed HEAD if enabled)..." >&2
    set +e
    "$WAIT_SCRIPT" --pr "$PR_NUMBER"
    WAIT_EXIT=$?
    set -e
    case $WAIT_EXIT in
        0) ;;
        2)
            echo "merge.sh: CI failed on PR #$PR_NUMBER — fix and push before merging." >&2
            exit 11
            ;;
        3)
            echo "merge.sh: readiness wait timed out — see diagnostic above." >&2
            echo "  Re-invoke with --force-unchecked only if hotfix authorized." >&2
            exit 11
            ;;
        5)
            echo "merge.sh: readiness wait interrupted." >&2
            exit 11
            ;;
        *)
            echo "merge.sh: readiness wait failed with exit $WAIT_EXIT." >&2
            exit 11
            ;;
    esac
fi

# ─── Squash-merge, then delete the remote branch (two separate steps) ───────
# The merge and the remote-branch delete are split ON PURPOSE. Bundled as a
# single `gh pr merge --squash --delete-branch`, a transient failure of the
# DELETE half — e.g. a GitHub 503 — makes gh report the whole command as
# failed, so the script aborts BEFORE the base-branch sync + npm ci below,
# stranding this checkout on the merged feature branch after a merge that
# actually landed. Splitting them keeps the squash-merge fatal and the delete
# best-effort, so the checkout always ends up on a current base once the
# merge is in.
#
# Both gh calls run from /tmp with `-R <owner>/<repo>`: with no local repo
# context gh performs only the server-side operation and never attempts a
# local `git branch -D`. That local delete would fail anyway — we are standing
# ON the branch being merged — and its failure would abort the script before
# the base-branch sync below. The local cleanup happens further down, in order,
# once this checkout is back on the base branch.
if ! REMOTE_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner); then
    echo "merge.sh: 'gh repo view' failed — cannot resolve owner/repo slug for the squash-merge call." >&2
    exit 17
fi
# The squash commit carries the PR's own title and body, passed explicitly.
# GitHub's default squash message depends on a per-repository setting, and its
# "commit messages" option lists the branch's commits and DROPS the PR body —
# the `Closes #N` line /open-pr writes and /deploy reads to move shipped issues
# to the deploy status. Passing both makes that independent of the setting.
if ! PR_TITLE=$(gh -R "$REMOTE_REPO" pr view "$PR_NUMBER" --json title -q .title); then
    echo "merge.sh: could not read PR #$PR_NUMBER's title — nothing merged." >&2
    exit 22
fi
if ! PR_BODY=$(gh -R "$REMOTE_REPO" pr view "$PR_NUMBER" --json body -q .body); then
    echo "merge.sh: could not read PR #$PR_NUMBER's body — nothing merged." >&2
    exit 22
fi
echo "gitflow: squash-merging PR #$PR_NUMBER (invoking gh from /tmp so it does no local git)..." >&2
# Pre-check /tmp accessibility BEFORE the subshell so a 'cd' failure
# does not get mis-blamed on 'gh pr merge'. Under any sane POSIX-ish
# system /tmp exists and is traversable; the explicit check exists to
# emit a specific diagnostic if the system is genuinely broken.
if [ ! -d /tmp ] || [ ! -x /tmp ]; then
    echo "merge.sh: /tmp is not accessible — cannot invoke gh from outside the git tree." >&2
    echo "  Diagnose the system before retrying. /tmp must exist and be traversable." >&2
    exit 21
fi
# The squash-merge is FATAL on failure — a failed merge means nothing shipped.
# set -e in the outer shell IS inherited by `(...)` subshells on bash 3.2 and
# 4.4+ (NOT the inherit_errexit case — that governs `$()`), so the explicit
# `if !` is for diagnostic clarity, not error propagation.
if ! (
    cd /tmp
    gh -R "$REMOTE_REPO" pr merge "$PR_NUMBER" --squash \
        --subject "$PR_TITLE (#$PR_NUMBER)" --body "$PR_BODY"
); then
    echo "merge.sh: 'gh pr merge --squash' failed for PR #$PR_NUMBER. Inspect on github.com or via 'gh pr view $PR_NUMBER'." >&2
    exit 20
fi

# Delete the remote branch — BEST-EFFORT, non-fatal. A transient API failure
# here (GitHub 503, etc.) must NOT abort the script before the base-branch
# sync + npm ci below: the merge already landed and this checkout MUST end up
# on a current base. On failure the remote branch simply lingers — the next
# `git fetch --prune`, or a manual `git push origin --delete`, clears it.
#
# `|| true` is load-bearing: when deleteBranchOnMerge is enabled (repo default
# for many), the squash-merge above already removed the head branch, so this
# DELETE 404s and exits non-zero. Under `set -eo pipefail` a bare subshell that
# exits non-zero ABORTS the whole script — stranding this checkout on the merged
# feature branch after a merge that actually landed. `|| true` keeps it
# best-effort as documented.
( cd /tmp && gh -R "$REMOTE_REPO" api -X DELETE "repos/$REMOTE_REPO/git/refs/heads/$CURRENT_BRANCH" >/dev/null 2>&1 ) || true
# Verify the ACTUAL outcome rather than trusting the DELETE's exit code. When the
# repo has deleteBranchOnMerge enabled (common), GitHub removes the head branch
# during the squash-merge above, so this explicit DELETE 404s on an already-gone
# ref and exits non-zero — a success, not a failure. Only warn if the branch
# genuinely still exists afterward (the auto-delete-off case where our DELETE
# truly failed). A lingering ref returns 200 here; an absent one returns 404.
if ( cd /tmp && gh -R "$REMOTE_REPO" api "repos/$REMOTE_REPO/git/refs/heads/$CURRENT_BRANCH" >/dev/null 2>&1 ); then
    echo "gitflow: remote-branch delete for '$CURRENT_BRANCH' did not take — branch still exists; delete it with: git push origin --delete $CURRENT_BRANCH" >&2
fi

# ─── Land on the base branch ───────────────────────────────────────────────
# The merge is in. Move this checkout onto the base and fast-forward it to the
# merged tip, so the session ends where the next body of work starts.
#
# The tree is clean at this point by construction: /open-pr and /merge both
# operate on a pushed branch, so anything uncommitted would have blocked the
# PR long before here. If a checkout somehow IS dirty, `git checkout` refuses
# rather than clobbering — which is the outcome we want, loudly.
cd "$REPO_ROOT"
echo "gitflow: switching to $BASE and fast-forwarding..." >&2
git fetch origin "$BASE"
if ! git checkout "$BASE"; then
    echo "merge.sh: could not switch to $BASE — the merge LANDED but this checkout is still on '$CURRENT_BRANCH'." >&2
    echo "  Resolve what git reported above, then: git checkout $BASE && git pull --ff-only" >&2
    exit 18
fi
if ! git pull --ff-only; then
    echo "merge.sh: could not fast-forward $BASE — the merge LANDED but local $BASE is behind." >&2
    echo "  Resolve what git reported above, then: git pull --ff-only" >&2
    exit 18
fi

# ─── Delete the merged local branch ────────────────────────────────────────
# We are on the base branch now, so the ref is free to remove. gh (invoked
# from /tmp above) deleted the remote branch but never touches the local one.
#
# Suppression rationale (Constitution §XIII): best-effort cleanup AFTER a
# completed ship. Failure modes: already deleted by a concurrent process, or a
# ref-update race. Neither is merge-blocking — the PR is merged and the remote
# branch is gone; aborting here would be noise after a successful ship.
git branch -D "$CURRENT_BRANCH" 2>/dev/null || true

# ─── Reinstall dependencies if landing on the base changed a manifest ──────
# Compare the branch tip we came from against the base we now stand on. Two
# cases produce a diff here: the squash brought in a manifest change made by
# someone whose install you never ran, or the base moved under you while this
# PR was open. Either way node_modules no longer matches the lockfile on disk,
# which bites /deploy's `npm run build` gate and every later test run.
# Best-effort: a failed install is surfaced, never aborts the completed merge.
#
# `npm ci`, NEVER bare `npm install` (rules/dependencies.md §I). This is the
# last thing to touch the lockfile before /deploy's build gate. Bare
# `npm install` is free to REWRITE package-lock.json — and does, whenever the
# local npm resolves optional/peer deps differently from the npm that wrote it.
# The corrupted lockfile then sits as an uncommitted change on the base branch,
# which /deploy blocks on (dirty tree) or bakes into the release. `npm ci`
# installs strictly from the committed lockfile and never edits it.
if git diff --name-only "$PRE_MERGE_SHA..HEAD" 2>/dev/null \
     | grep -qE '(^|/)package(-lock)?\.json$'; then
    echo "gitflow: manifests changed on $BASE — reinstalling dependencies (npm ci)..." >&2
    npm ci --no-audit --no-fund >&2 \
        || echo "gitflow: npm ci FAILED — run 'npm ci' in $REPO_ROOT before /deploy." >&2
fi

echo "gitflow: merge complete." >&2
