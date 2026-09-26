#!/bin/bash
# gitflow commit: full conventional commit with AI-generated message.
# Usage: commit.sh --message "<full conventional message>" [--model "Claude Opus 4.7"] [--skip-typecheck]
#                  [--complete "<N[,N…]>" --notes <dir>]
#        commit.sh --push-only
#
# Modes:
#   default     — typecheck, stage all, commit, push (the normal /commit flow)
#   --push-only — skip typecheck/stage/commit; push current HEAD via safe_push.
#                 Use when a prior /commit succeeded at commit but failed at push
#                 (e.g. bogus upstream inherited from the start-point, transient
#                 network failure). No-op if HEAD == @{u}.
#
# Responsibilities (default mode):
#   - Auto-create or rename branch as needed (see Branch behavior below)
#   - Run project-type-appropriate typecheck (unless --skip-typecheck)
#   - Fold any unpushed /checkpoint commits into this one (after every gate)
#   - Stage all changes
#   - Commit with --no-verify (validation is done by this script)
#   - Push to origin via safe_push (sets upstream correctly on first push)
#   - Mark the --complete issues code complete and move them to Staged. The
#     slash command asks which linked issues are complete; this script only
#     acts on the answer, and only after the push has landed.
#   - Post each newly staged issue's comment from <notes_dir>/<N>.md. Refuses to
#     run at all, before committing, when one is missing.
#
# Branch behavior:
#   - On main/master: derive <type>/<slug> from message, create branch, commit on it.
#     Checkpoint commits on main move to the new branch; local main is reset to
#     the commit they sat on, so main never keeps a checkpoint.
#   - On any other branch: commit in place.
#
# Not responsibilities:
#   - Changelog: handled by /open-pr (Claude-generated, committed to feature branch pre-push)
#   - Version bump + tag: handled by /deploy (local, human-in-the-loop) — not by any GitHub Action

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"
# shellcheck source=./issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

MESSAGE=""
MODEL_NAME="Claude"
SKIP_TYPECHECK=0
PUSH_ONLY=0
REVIEW=0
NO_REVIEW=0
COMPLETE_ISSUES=""
NOTES_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --message)         MESSAGE="$2"; shift 2 ;;
        --model)           MODEL_NAME="$2"; shift 2 ;;
        --skip-typecheck)  SKIP_TYPECHECK=1; shift 1 ;;
        --push-only)       PUSH_ONLY=1; shift 1 ;;
        --review)          REVIEW=1; shift 1 ;;
        --no-review)       NO_REVIEW=1; shift 1 ;;
        --notes)           NOTES_DIR="$2"; shift 2 ;;
        --complete)
            COMPLETE_ISSUES=$(parse_issue_csv "$2")
            if [ -z "$COMPLETE_ISSUES" ]; then
                echo "commit.sh: --complete needs issue numbers (got '$2')" >&2
                exit 2
            fi
            shift 2 ;;
        *) echo "commit.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ "$REVIEW" -eq 1 ] && [ "$NO_REVIEW" -eq 1 ]; then
    echo "commit.sh: --review and --no-review are mutually exclusive" >&2
    exit 2
fi

# ─── Mode: --push-only (retry push for an already-committed branch) ───────
# This exists for the case where a prior /commit landed the commit locally
# but the push step failed (typical cause: bogus upstream config from
# a branch cut from origin/main inherited branch.<name>.merge pointing at
# refs/heads/main, then plain `git push` fails under push.default=simple).
# safe_push corrects the upstream and pushes.
if [ "$PUSH_ONLY" -eq 1 ]; then
    if [ -n "$MESSAGE" ] || [ "$SKIP_TYPECHECK" -eq 1 ] || [ -n "$COMPLETE_ISSUES" ]; then
        echo "commit.sh: --push-only is exclusive with --message / --skip-typecheck / --complete" >&2
        exit 2
    fi
    CURRENT_BRANCH=$(git branch --show-current)
    if [ -z "$CURRENT_BRANCH" ]; then
        echo "commit.sh: --push-only requires a named branch (detached HEAD)" >&2
        exit 3
    fi
    # Clean-tree check: no working / staged diff AND no untracked files
    # (excluding .gitignore'd). Mirrors tree_is_clean in work.sh for
    # consistency — untracked files often signal a half-finished resolution
    # that the user didn't realize was incomplete, and --push-only pushing
    # HEAD without them silently strands the work locally.
    if ! git diff --quiet 2>/dev/null \
       || ! git diff --cached --quiet 2>/dev/null \
       || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
        echo "commit.sh: --push-only refuses to run with uncommitted or untracked changes." >&2
        echo "  Either /commit (regular flow), or stash/discard/.gitignore the leftovers first." >&2
        exit 5
    fi
    echo "gitflow: --push-only — pushing $CURRENT_BRANCH via safe_push." >&2
    # shellcheck disable=SC2119 # safe_push takes no args by design (reads current branch + upstream from git state)
    safe_push
    echo "gitflow: push complete on $CURRENT_BRANCH." >&2
    exit 0
fi

if [ -z "$MESSAGE" ]; then
    echo "commit.sh: --message is required (unless --push-only)" >&2
    exit 2
fi

CURRENT_BRANCH=$(git branch --show-current)

# A --complete number that is not linked here fails now, before anything is
# committed. The links are still on this branch — migration below carries them.
if [ -n "$COMPLETE_ISSUES" ] && ! validate_complete_issues "$COMPLETE_ISSUES" "$CURRENT_BRANCH"; then
    exit 2
fi
# Every issue about to reach Staged needs its comment written first.
if [ -n "$COMPLETE_ISSUES" ] && ! require_staged_notes "$COMPLETE_ISSUES" "$NOTES_DIR" "$CURRENT_BRANCH"; then
    exit 2
fi

# A main that moved since this work began is reported now — on main that means
# BEFORE a branch is cut from a stale copy. A warning, never a block: most drift
# merges cleanly, and /merge refuses the drift that does not.
main_drift_report main commit.sh || true

# The commit any unpushed checkpoints sit on. Every gate below judges the
# folded content against it; the fold itself waits until they have all passed.
FOLD_BASE=$(checkpoint_fold_base)

# Branch resolution
if is_protected_branch "$CURRENT_BRANCH"; then
    TARGET_NAME=$(resolve_collision "$(derive_branch_from_message "$MESSAGE")")
    echo "gitflow: on $CURRENT_BRANCH — auto-creating $TARGET_NAME for commit." >&2
    PREVIOUS_BRANCH="$CURRENT_BRANCH"
    create_and_switch "$TARGET_NAME"
    CURRENT_BRANCH="$TARGET_NAME"
    # The checkpoints now live on the new branch, so main goes back to the
    # commit they sat on. Done here rather than at the fold: a gate that fails
    # below must not leave main still carrying them.
    if [ "$FOLD_BASE" != "$(git rev-parse HEAD)" ]; then
        git branch -f "$PREVIOUS_BRANCH" "$FOLD_BASE"
    fi
    # /work <issue#> parks its link on main rather than cutting a branch, so the
    # branch created HERE is the one the issue belongs to.
    migrate_branch_linked_issues "$PREVIOUS_BRANCH" "$CURRENT_BRANCH"
fi

# Typecheck (script-level validation; hook layer is belt-and-suspenders)
if [ "$SKIP_TYPECHECK" -eq 0 ]; then
    if [ -f "package.json" ] && grep -q '"check-types"' package.json 2>/dev/null; then
        echo "gitflow: running npm run check-types..." >&2
        if ! npm run check-types >/dev/null 2>&1; then
            echo "" >&2
            echo "gitflow: TypeScript errors detected. Fix before committing." >&2
            echo "  Run: npm run check-types" >&2
            exit 4
        fi
    elif [ -f "pyproject.toml" ]; then
        if command -v pyright >/dev/null 2>&1; then
            echo "gitflow: running pyright..." >&2
            if ! pyright >/dev/null 2>&1; then
                echo "gitflow: Python type errors. Fix before committing (run: pyright)." >&2
                exit 4
            fi
        elif command -v mypy >/dev/null 2>&1; then
            echo "gitflow: running mypy..." >&2
            if ! mypy . >/dev/null 2>&1; then
                echo "gitflow: Python type errors. Fix before committing (run: mypy .)." >&2
                exit 4
            fi
        fi
    fi
fi

# Biome lint (if the project has adopted Biome — gated on biome.json presence
# AND a root package.json). Mirrors the CI `biome` job so lint failures fire
# locally in <1s instead of on the PR 30s later. CI runs that job only when a
# root package.json exists (its `node` detection), and Biome can only be
# installed as a devDependency of one — so a project with the kit's biome.json
# but no Node stack skips this gate, exactly as CI does, rather than failing on
# a linter it has no way to install. No-op in projects without Biome.
#
# ALWAYS `@biomejs/biome`, NEVER a bare `biome`, and always `--no-install`.
# `npx biome` resolves to an UNRELATED package of that name on npm (an
# environment-variable manager) which accepts `lint` as an unknown command and
# EXITS 0 — so this gate reported success without linting anything. Without
# `--no-install`, npx silently downloads whatever is latest, which is how a
# project's pinned biome.json schema and the binary actually running it drift
# apart with nothing to say so.
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
        echo "gitflow: Biome lint errors detected. Fix before committing." >&2
        echo "  Run: npx --no-install @biomejs/biome lint" >&2
        exit 4
    fi
fi

# Semgrep (mirrors the CI `semgrep` job), scoped to the files this commit touches.
#
# It is here because semgrep was the ONE CI gate with no local mirror, and that
# gap has a shape: every other check fires in this script in about a second, so
# a push is expected to reach CI green — which leaves semgrep as the only thing
# that can surprise you, after the PR is already open and a review has been
# triggered against a HEAD that is about to be replaced.
#
# Gated on CI actually declaring the job, so the local gate and the remote one
# can never disagree about whether this repo is scanned at all.
#
# CHANGED FILES ONLY, and that limit is real: a rule that fires on a file this
# commit does not touch still surfaces only in CI, which scans everything. This
# catches what you are about to INTRODUCE — the case that costs the round trip —
# and keeps the gate at seconds rather than the minute a full scan takes. It is
# the same trade the biome gate above makes.
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
            echo "gitflow: Semgrep findings in the files this commit touches. Fix before committing." >&2
            echo "" >&2
            printf '%s\n' "$SEMGREP_OUT" >&2
            exit 4
        fi
    fi
fi

# Every gate passed — fold the checkpoints, then stage everything.
fold_checkpoints "$FOLD_BASE"
git add -A

# Abort if nothing staged (avoid empty commits)
if git diff --cached --quiet; then
    echo "gitflow: nothing to commit." >&2
    exit 5
fi

# Commit with --no-verify (validation already run above)
echo "gitflow: committing on $CURRENT_BRANCH: $MESSAGE" >&2
git commit --no-verify -m "$MESSAGE

Co-Authored-By: $MODEL_NAME <noreply@anthropic.com>"

# Push via safe_push — handles missing-upstream AND wrong-upstream (e.g.
# origin/main inherited from the branch's start-point).
# shellcheck disable=SC2119 # safe_push takes no args by design (reads current branch + upstream from git state)
safe_push

# Code complete → Staged, now that the commit is on origin.
if [ -n "$COMPLETE_ISSUES" ]; then
    if ! stage_complete_issues "$COMPLETE_ISSUES" "$CURRENT_BRANCH"; then
        echo "commit.sh: the commit and push landed; only the board update failed. Fix the cause —" >&2
        echo "  /open-pr sets every linked issue to Staged again." >&2
        exit 11
    fi
    echo "gitflow: code complete → Staged: $(format_issue_refs "$COMPLETE_ISSUES")." >&2
    if ! post_staged_notes "$COMPLETE_ISSUES" "$NOTES_DIR" "$CURRENT_BRANCH"; then
        echo "commit.sh: the commit, push and board update landed; only a Staged comment failed (see above)." >&2
        exit 13
    fi
fi

# Trigger Gemini re-review on the new HEAD ONLY when --review was passed.
# Gemini Code Assist's auto-review on PR open is disabled in the kit's
# .gemini/config.yaml; reviews fire only via explicit `/gemini review`
# comment. The slash-command handler (.claude/commands/commit.md) prompts
# the user when neither --review nor --no-review was passed and a PR is
# open, then re-invokes with the appropriate flag — so by the time this
# script runs, the choice is already made.
#
# Posting via `gh pr comment` lands under the developer's GitHub identity
# (not a `[bot]` user), bypassing Gemini's loop-prevention filter.
#
# Skipped when:
#   - --no-review was passed (or --review wasn't), regardless of repo state
#   - GEMINI_NOT_INSTALLED="true" in .claude/sync-substitutions.json
#   - No open PR for the current branch (nothing to comment on)
#   - `gh` CLI is not on PATH
#
# Fail-loud on post failure: if the user asked for a review and the comment
# didn't land, the downstream wait-for-pr-ready.sh gate will see no trigger
# and proceed CI-only — the user would silently lose Gemini coverage on
# this commit. Surface immediately.
if [ "$REVIEW" -eq 1 ]; then
    trigger_gemini_review() {
        command -v gh >/dev/null 2>&1 || {
            echo "commit.sh: --review passed but gh CLI is not on PATH — cannot post /gemini review." >&2
            return 9
        }
        local project_root subs_file gemini_skip pr_number
        project_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
        subs_file="${project_root}/.claude/sync-substitutions.json"
        if [ -f "$subs_file" ]; then
            gemini_skip=$(jq -r '.GEMINI_NOT_INSTALLED // ""' "$subs_file" 2>/dev/null || echo "")
            if [ "$gemini_skip" = "true" ]; then
                echo "gitflow: GEMINI_NOT_INSTALLED=true — skipping /gemini review trigger despite --review" >&2
                return 0
            fi
        fi
        pr_number=$(gh pr list --head "$CURRENT_BRANCH" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
        if [ -z "$pr_number" ]; then
            echo "gitflow: --review passed but no open PR for branch $CURRENT_BRANCH — skipping trigger." >&2
            return 0
        fi
        if gh pr comment "$pr_number" --body "/gemini review" >/dev/null 2>&1; then
            echo "gitflow: posted /gemini review on PR #$pr_number — Gemini will re-review within ~5 min" >&2
            return 0
        fi
        echo "commit.sh: failed to post /gemini review on PR #$pr_number." >&2
        echo "  Commit + push succeeded, but Gemini was NOT triggered. Post the comment manually" >&2
        echo "  or re-invoke /commit with --review (commit will be a no-op if HEAD == origin/branch)." >&2
        return 10
    }
    trigger_gemini_review || exit $?
fi

echo "gitflow: commit complete on $CURRENT_BRANCH." >&2
