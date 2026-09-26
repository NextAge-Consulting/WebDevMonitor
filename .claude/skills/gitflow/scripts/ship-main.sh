#!/bin/bash
# gitflow ship-main: direct conventional commit straight to main — no branch,
# no PR, no CI. THE CONSCIOUS EXCEPTION for quick infra / emergency work.
#
# Usage: ship-main.sh --message "<conventional message>" [--model "<name>"] [--skip-typecheck]
#                     [--complete "<N[,N…]>" --notes <dir>]
#
# How it differs from /commit: default /commit on main AUTO-CREATES a feature
# branch (the safety for accidental-on-main). /ship-main does the opposite ON
# PURPOSE — it commits on main and pushes directly. You only get here by
# explicitly asking ("ship to main", "infra commit",
# "emergency to main"); it is NEVER inferred from being on main.
#
# Guardrails:
#   - Refuses unless on main/master (a body of work in progress is on its own
#     branch, so it can't trip this by accident).
#   - Runs the same typecheck + biome lint as /commit (the assist worth keeping);
#     --skip-typecheck for a true emergency.
#   - Folds any unpushed /checkpoint commits into the one commit it makes, so no
#     `🔖 wip:` subject reaches main for /deploy to read.
#   - Commits with a CONVENTIONAL message so the next /deploy classifies it for
#     bump-level + changelog exactly like a merged-PR squash commit.
#   - Pushes straight to main; rebases the commit onto origin/main if it advanced.
#
# Requires main to NOT require a PR — the default; the pipeline uses no branch
# protection (see pipeline.md §1.1). A direct push to main triggers NO workflows
# (CI is pull_request-only; deploys are workflow_dispatch-only), so it lands
# silently and instantly. CI is intentionally skipped — this is the exception
# path; the local typecheck above is the safety net.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"
# shellcheck source=./issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

MESSAGE=""
MODEL_NAME="Claude"
SKIP_TYPECHECK=0
COMPLETE_ISSUES=""
NOTES_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --message)         MESSAGE="$2"; shift 2 ;;
        --model)           MODEL_NAME="$2"; shift 2 ;;
        --skip-typecheck)  SKIP_TYPECHECK=1; shift 1 ;;
        --notes) NOTES_DIR="$2"; shift 2 ;;
        --complete)
            COMPLETE_ISSUES=$(parse_issue_csv "$2")
            if [ -z "$COMPLETE_ISSUES" ]; then
                echo "ship-main.sh: --complete needs issue numbers (got '$2')" >&2
                exit 2
            fi
            shift 2 ;;
        *) echo "ship-main.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$MESSAGE" ]; then
    echo "ship-main.sh: --message is required" >&2
    exit 2
fi

# --- Guardrail: must be on main/master ------------------------------------
CURRENT_BRANCH=$(git branch --show-current)
if ! is_protected_branch "$CURRENT_BRANCH"; then
    echo "ship-main.sh: refusing — /ship-main only runs on main (you are on '$CURRENT_BRANCH')." >&2
    echo "  /ship-main is the deliberate direct-to-main exception for infra/emergency work." >&2
    echo "  For feature work on a branch, use /commit." >&2
    exit 3
fi

# A --complete number that is not linked here fails now, before anything is
# committed or pushed.
if [ -n "$COMPLETE_ISSUES" ] && ! validate_complete_issues "$COMPLETE_ISSUES" "$CURRENT_BRANCH"; then
    exit 2
fi

# The commit any unpushed checkpoints sit on. The gates judge the folded content
# against it; the fold itself waits until they have all passed.
FOLD_BASE=$(checkpoint_fold_base)

# --- Validation (the assist that stays; --skip-typecheck for emergencies) --
if [ "$SKIP_TYPECHECK" -eq 0 ]; then
    if [ -f "package.json" ] && grep -q '"check-types"' package.json 2>/dev/null; then
        echo "gitflow: running npm run check-types..." >&2
        if ! npm run check-types >/dev/null 2>&1; then
            echo "" >&2
            echo "gitflow: TypeScript errors detected. Fix before shipping to main (or --skip-typecheck for a true emergency)." >&2
            echo "  Run: npm run check-types" >&2
            exit 4
        fi
    elif [ -f "pyproject.toml" ]; then
        if command -v pyright >/dev/null 2>&1; then
            echo "gitflow: running pyright..." >&2
            if ! pyright >/dev/null 2>&1; then
                echo "gitflow: Python type errors. Fix before shipping (run: pyright), or --skip-typecheck." >&2
                exit 4
            fi
        elif command -v mypy >/dev/null 2>&1; then
            echo "gitflow: running mypy..." >&2
            if ! mypy . >/dev/null 2>&1; then
                echo "gitflow: Python type errors. Fix before shipping (run: mypy .), or --skip-typecheck." >&2
                exit 4
            fi
        fi
    fi
fi

# ALWAYS `@biomejs/biome`, NEVER a bare `biome`, and always `--no-install` —
# see the note on the same gate in commit.sh. A bare `npx biome` runs an
# unrelated package that exits 0, so this gate passed without linting.
# Gated on a root package.json too, like CI's `biome` job and commit.sh's gate:
# without one there is no Node stack to install Biome into.
if { [ -f "biome.json" ] || [ -f "biome.jsonc" ]; } && [ -f "package.json" ]; then
    echo "gitflow: running biome lint..." >&2
    if ! npx --no-install @biomejs/biome --version >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: biome.json is present but @biomejs/biome is not installed." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        echo "  Fix: npm i -D @biomejs/biome@<the version biome.json's \$schema names>" >&2
        exit 4
    fi
    if ! npx --no-install @biomejs/biome lint >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: Biome lint errors detected. Fix before shipping to main." >&2
        echo "  Run: npx --no-install @biomejs/biome lint" >&2
        exit 4
    fi
fi

# Semgrep (mirrors the CI `semgrep` job), scoped to the files this commit touches.
# Identical in intent and shape to the gate in commit.sh — read the long note
# there for why it is scoped to changed files and why a missing semgrep fails.
#
# It matters MORE here than on the /commit path, not less: this commits straight
# to main, so a finding that slips through does not sit on a branch waiting for
# review — it lands on the default branch and breaks CI for everyone. That
# `/sync-dev-kit` recommends /ship-main for landing kit updates is exactly the
# route by which an unscanned change would arrive there.
if [ -f ".github/workflows/ci.yml" ] && grep -qE '^[[:space:]]*semgrep:[[:space:]]*$' .github/workflows/ci.yml 2>/dev/null; then
    if ! command -v semgrep >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: CI runs semgrep, but semgrep is not installed here." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        echo "  Fix: brew install semgrep   (or: pipx install semgrep)" >&2
        exit 4
    fi

    # Tracked modifications plus untracked additions, minus deletions, measured from
    # FOLD_BASE so content saved in checkpoints — which skipped every gate — is
    # scanned too. `mapfile`
    # is deliberately not used: macOS ships bash 3.2 as /bin/bash and does not
    # have it, so this script would die on the shebang platform it most often
    # runs on.
    SEMGREP_FILES=()
    while IFS= read -r semgrep_f; do
        [ -n "$semgrep_f" ] && [ -f "$semgrep_f" ] && SEMGREP_FILES+=("$semgrep_f")
    done < <(
        {
            git diff --name-only --diff-filter=d "$FOLD_BASE" 2>/dev/null
            git ls-files --others --exclude-standard 2>/dev/null
        } | sort -u
    )

    if [ ${#SEMGREP_FILES[@]} -gt 0 ]; then
        echo "gitflow: running semgrep on ${#SEMGREP_FILES[@]} changed file(s)..." >&2
        # Output is captured and REPLAYED on failure rather than suppressed with
        # a "run it yourself" hint. A semgrep scan is tens of seconds; telling
        # the user to pay that twice to find out what was wrong is the kind of
        # small tax that gets a gate disabled.
        if ! SEMGREP_OUT=$(semgrep scan --config auto --error "${SEMGREP_FILES[@]}" 2>&1); then
            echo "" >&2
            echo "gitflow: Semgrep findings in the files this commit touches. Fix before shipping to main." >&2
            echo "" >&2
            printf '%s\n' "$SEMGREP_OUT" >&2
            exit 4
        fi
    fi
fi

# --- Fold checkpoints, stage + commit directly on main ---------------------
fold_checkpoints "$FOLD_BASE"
git add -A
if git diff --cached --quiet; then
    echo "gitflow: nothing to commit." >&2
    exit 5
fi

# --- Name the complete issues in the commit itself -------------------------
# /work <issue#> parks its link here rather than cutting a branch, so ship-main
# is the path that consumes it — but only for the issues that are code complete.
# Shipping part of the work to main must not name an unfinished issue: the
# `Closes` line is what /deploy reads to move an issue to the deploy status, and
# on a repository with auto-close on, GitHub closes it on this push. Incomplete
# issues stay parked on main for the work that finishes them.
SHIP_CLOSE_ISSUES="$(read_branch_complete_issues "$CURRENT_BRANCH") $COMPLETE_ISSUES"
SHIP_CLOSE_ISSUES=$(printf '%s' "$SHIP_CLOSE_ISSUES" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed -E 's/ +$//')
SHIP_CLOSES_LINE=$(closes_line_for_issues "$SHIP_CLOSE_ISSUES")
# Each of them reaches Staged below, so each needs its comment written now,
# before the commit.
if [ -n "$SHIP_CLOSE_ISSUES" ] && ! require_staged_notes "$SHIP_CLOSE_ISSUES" "$NOTES_DIR" "$CURRENT_BRANCH"; then
    exit 2
fi
if [ -n "$SHIP_CLOSES_LINE" ]; then
    MESSAGE="$MESSAGE

$SHIP_CLOSES_LINE"
    echo "gitflow: adding '$SHIP_CLOSES_LINE' for the issues marked code complete." >&2
fi

echo "gitflow: ship-main — committing directly on $CURRENT_BRANCH: $MESSAGE" >&2
git commit --no-verify -m "$MESSAGE

Co-Authored-By: $MODEL_NAME <noreply@anthropic.com>"

# --- Push to main; rebase onto origin/main if it advanced -----------------
PUSH_ERR=$(mktemp)
if git push origin "$CURRENT_BRANCH" 2>"$PUSH_ERR"; then
    rm -f "$PUSH_ERR"
    echo "gitflow: pushed directly to $CURRENT_BRANCH." >&2
else
    if grep -qiE "non-fast-forward|fetch first|behind|rejected" "$PUSH_ERR"; then
        rm -f "$PUSH_ERR"
        echo "gitflow: origin/$CURRENT_BRANCH advanced — rebasing the ship-main commit onto it..." >&2
        if ! git pull --rebase origin "$CURRENT_BRANCH" >&2; then
            echo "ship-main.sh: rebase hit conflicts. Resolve them, then: git push origin $CURRENT_BRANCH" >&2
            exit 6
        fi
        if ! git push origin "$CURRENT_BRANCH" >&2; then
            echo "ship-main.sh: push failed after rebase — resolve manually." >&2
            exit 6
        fi
        echo "gitflow: pushed directly to $CURRENT_BRANCH (after rebase)." >&2
    else
        cat "$PUSH_ERR" >&2
        rm -f "$PUSH_ERR"
        echo "ship-main.sh: push to $CURRENT_BRANCH failed (see above)." >&2
        exit 6
    fi
fi

# Consumed: the Closes line now sits on a commit on the default branch. Staged
# first (marking needs the link), then unlink exactly those issues so they
# cannot re-attach to unrelated later work; incomplete ones stay parked. Placed
# after BOTH push paths — every failing path above exits, so reaching here
# means the push landed. Unlinking happens even when the board update fails:
# the commit already names the issue, and a second ship-main must not name it
# again. Written as `if`, not `[ … ] && …`: under `set -e` a false test as the
# last statement of the block aborts the script (bash-rules.md §III).
if [ -n "$SHIP_CLOSE_ISSUES" ]; then
    STAGE_RC=0
    stage_complete_issues "$SHIP_CLOSE_ISSUES" "$CURRENT_BRANCH" || STAGE_RC=$?
    NOTES_RC=0
    if [ "$STAGE_RC" -eq 0 ]; then
        post_staged_notes "$SHIP_CLOSE_ISSUES" "$NOTES_DIR" "$CURRENT_BRANCH" || NOTES_RC=$?
    fi
    unlink_issues_from_branch "$SHIP_CLOSE_ISSUES" "$CURRENT_BRANCH"
    if [ "$STAGE_RC" -ne 0 ]; then
        echo "ship-main.sh: the commit is live on $CURRENT_BRANCH; only the board update failed. Fix the cause —" >&2
        echo "  the next /deploy still moves $(format_issue_refs "$SHIP_CLOSE_ISSUES") to the deploy status." >&2
        exit 11
    fi
    echo "gitflow: code complete → Staged: $(format_issue_refs "$SHIP_CLOSE_ISSUES")." >&2
    if [ "$NOTES_RC" -ne 0 ]; then
        echo "ship-main.sh: the commit is live and the board updated; only a Staged comment failed (see above)." >&2
        exit 13
    fi
fi

echo "gitflow: ship-main complete — live on $CURRENT_BRANCH. (No PR, no CI — it's an exception commit.)" >&2
