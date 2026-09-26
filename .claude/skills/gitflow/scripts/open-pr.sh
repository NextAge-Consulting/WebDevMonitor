#!/bin/bash
# gitflow open-pr: push current branch, create a PR.
# Usage: open-pr.sh --title "<PR title>" --body "<PR body>" \
#                   [--base main] [--draft] [--complete "<N[,N…]>"]
#
# Code-complete gate: every issue linked on the branch must be code complete
# before a PR opens, because opening one sets them all to Staged. An issue not
# yet marked (by /commit) must be named in --complete — the slash command asks
# "this will mark #N as Staged" first, and a no means no PR. Anything left
# unconfirmed exits 12 before the push.
#
# Changelog: NOT touched here. Single-writer model — `/deploy` is the sole
# author of changelog.md (deploy.sh inserts the consolidated release entry
# under today's date header at version-bump time). open-pr previously also
# wrote a per-PR entry; that produced duplicate bullets in main's changelog
# (one from open-pr's feature-branch commit + one from deploy's release-
# branch commit). The duplicate was structural: both scripts read the same
# --changelog-file content, both wrote under the same date header, neither
# deduped. Removed entirely rather than patched.
#
# Transport detection (for PR creation):
#   - If `gh` is available (local), uses gh pr create
#   - Else (cloud containers), uses GitHub REST API via curl + $GITHUB_TOKEN
#
# Cloud Claude sessions receive $GITHUB_TOKEN automatically via the GitHub proxy.
# Local Claude sessions must have `gh auth login` completed, or set $GITHUB_TOKEN manually.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"
# shellcheck source=_claude-project/skills/gitflow/scripts/branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"

TITLE=""
BODY=""
BASE="main"
DRAFT=""
COMPLETE_ISSUES=""
NOTES_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --title)            TITLE="$2"; shift 2 ;;
        --body)             BODY="$2"; shift 2 ;;
        --base)             BASE="$2"; shift 2 ;;
        --draft)            DRAFT="--draft"; shift 1 ;;
        --notes)            NOTES_DIR="$2"; shift 2 ;;
        --complete)
            COMPLETE_ISSUES=$(parse_issue_csv "$2")
            if [ -z "$COMPLETE_ISSUES" ]; then
                echo "open-pr.sh: --complete needs issue numbers (got '$2')" >&2
                exit 2
            fi
            shift 2 ;;
        *) echo "open-pr.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$TITLE" ]; then
    echo "open-pr.sh: --title is required" >&2
    exit 2
fi
if [ -z "$BODY" ]; then
    echo "open-pr.sh: --body is required" >&2
    exit 2
fi

CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" = "$BASE" ]; then
    echo "open-pr.sh: current branch is $BASE — cannot open PR against itself." >&2
    exit 3
fi

# Working tree must be clean (caller should have committed first).
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "open-pr.sh: working tree has uncommitted changes. /commit or /checkpoint first." >&2
    exit 3
fi

# ─── Code-complete gate ────────────────────────────────────────────────────
# Before the push, so a refusal leaves nothing half-done.
if [ -n "$COMPLETE_ISSUES" ] && ! validate_complete_issues "$COMPLETE_ISSUES" "$CURRENT_BRANCH"; then
    exit 2
fi
UNCONFIRMED=""
for num in $(read_branch_incomplete_issues "$CURRENT_BRANCH"); do
    confirmed=0
    for c in $COMPLETE_ISSUES; do [ "$c" = "$num" ] && confirmed=1; done
    if [ "$confirmed" -eq 0 ]; then UNCONFIRMED="${UNCONFIRMED:+$UNCONFIRMED }$num"; fi
done
if [ -n "$UNCONFIRMED" ]; then
    echo "open-pr.sh: not code complete: $(format_issue_refs "$UNCONFIRMED")." >&2
    echo "  Opening the PR marks every linked issue Staged. Confirm with --complete \"${UNCONFIRMED// /,}\"," >&2
    echo "  or keep working and /commit when they are done." >&2
    exit 12
fi
# Every linked issue reaches Staged below, so every one still without its
# comment needs it written now — before the push.
if ! require_staged_notes "$(read_branch_linked_issues "$CURRENT_BRANCH")" "$NOTES_DIR" "$CURRENT_BRANCH"; then
    exit 2
fi

# ─── Inject Closes #N from branch-scoped linked issues ────────────────────
# Issues linked via /work <issue#> are stored in git config
# (branch.<name>.gitflow-issues). Prepend a `Closes #N, #M ...` line to the
# PR body: the squash commit carries it onto main, where /deploy reads it to
# find what shipped. Whether merging also closes the issue is the repository's
# auto-close setting, not this script's. Idempotent: if the body already starts
# with Closes, we don't double-prepend.
LINKED_ISSUES=$(read_branch_linked_issues "$CURRENT_BRANCH")
if [ -n "$LINKED_ISSUES" ]; then
    CLOSES_LINE=$(closes_line_for_issues "$LINKED_ISSUES")
    if ! printf '%s' "$BODY" | head -n 1 | grep -qE '^Closes\s+#[0-9]'; then
        BODY="${CLOSES_LINE}

${BODY}"
        echo "gitflow: prepended '$CLOSES_LINE' to PR body (from branch-linked issues)." >&2
    fi
fi

# ─── Push and create PR ────────────────────────────────────────────────────

# Before the review is requested: a branch behind its base gets reviewed, triaged
# and fixed on code that may not merge. Reported, not blocked.
main_drift_report "$BASE" open-pr.sh || true

# Push branch via safe_push — handles missing-upstream AND wrong-upstream
# (e.g. origin/main inherited from the branch's start-point).
# shellcheck disable=SC2119 # safe_push takes no args by design (reads current branch + upstream from git state)
safe_push

# Create PR
PR_NUMBER=""
if command -v gh >/dev/null 2>&1; then
    echo "gitflow: creating PR via gh..." >&2
    PR_URL=$(gh pr create --title "$TITLE" --body "$BODY" --base "$BASE" $DRAFT)
    echo "$PR_URL"
    PR_NUMBER=$(basename "$PR_URL")
elif [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "gitflow: creating PR via GitHub REST API (gh not available)..." >&2

    # Derive owner/repo from origin URL
    REMOTE_URL=$(git config --get remote.origin.url)
    # Handles https://github.com/OWNER/REPO.git and git@github.com:OWNER/REPO.git
    REPO_SLUG=$(echo "$REMOTE_URL" | sed -E 's#(git@github\.com:|https://github\.com/)([^/]+/[^/.]+)(\.git)?#\2#')
    if [ -z "$REPO_SLUG" ]; then
        echo "open-pr.sh: could not parse owner/repo from $REMOTE_URL" >&2
        exit 6
    fi

    DRAFT_JSON="false"
    [ -n "$DRAFT" ] && DRAFT_JSON="true"
    PAYLOAD=$(jq -n \
        --arg title "$TITLE" \
        --arg body  "$BODY" \
        --arg head  "$CURRENT_BRANCH" \
        --arg base  "$BASE" \
        --argjson draft "$DRAFT_JSON" \
        '{title: $title, body: $body, head: $head, base: $base, draft: $draft}')

    RESPONSE=$(curl -sS -X POST \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${REPO_SLUG}/pulls" \
        -d "$PAYLOAD")

    PR_URL=$(echo "$RESPONSE" | jq -r '.html_url // empty')
    if [ -z "$PR_URL" ]; then
        echo "open-pr.sh: PR creation failed." >&2
        echo "$RESPONSE" | jq -r '.message // .' >&2
        exit 7
    fi
    PR_NUMBER=$(echo "$RESPONSE" | jq -r '.number // empty')
    echo "gitflow: PR opened: $PR_URL" >&2
else
    echo "open-pr.sh: neither gh CLI nor \$GITHUB_TOKEN available. Cannot create PR." >&2
    exit 8
fi

# ─── Trigger Gemini review explicitly ──────────────────────────────────────
# Gemini Code Assist's auto-review on PR open is disabled in
# _gemini-project/config.yaml (pull_request_opened.code_review: false).
# Trigger the first review here so /triage has something to walk and
# wait-for-pr-ready.sh sees a posted trigger (it gates on the presence
# of a `/gemini review` comment scoped to the current HEAD).
#
# Skipped when:
#   - GEMINI_NOT_INSTALLED="true" in .claude/sync-substitutions.json
#     (this repo genuinely has no Gemini App installed)
#   - $DRAFT is set (draft PRs honor include_drafts: false)
#
# Fail-loud on post failure: if the trigger isn't posted, the wait gate
# downstream will proceed CI-only on this HEAD and the user will silently
# lose Gemini coverage on the initial review. Surface it now so the user
# can decide (retry the comment, set GEMINI_NOT_INSTALLED, or accept).
if [ -n "$PR_NUMBER" ] && [ -z "$DRAFT" ]; then
    PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    SUBS_FILE="${PROJECT_ROOT}/.claude/sync-substitutions.json"
    GEMINI_SKIP=""
    if [ -n "$PROJECT_ROOT" ] && [ -f "$SUBS_FILE" ] && command -v jq >/dev/null 2>&1; then
        GEMINI_SKIP=$(jq -r '.GEMINI_NOT_INSTALLED // ""' "$SUBS_FILE" 2>/dev/null || echo "")
    fi
    if [ "$GEMINI_SKIP" != "true" ]; then
        if command -v gh >/dev/null 2>&1; then
            if gh pr comment "$PR_NUMBER" --body "/gemini review" >/dev/null 2>&1; then
                echo "gitflow: posted /gemini review on PR #$PR_NUMBER — Gemini will review within ~5 min" >&2
            else
                echo "open-pr.sh: failed to post /gemini review on PR #$PR_NUMBER." >&2
                echo "  PR is open. Post the comment manually or re-run with gh authenticated." >&2
                exit 9
            fi
        elif [ -n "${GITHUB_TOKEN:-}" ]; then
            if ! RESPONSE=$(curl -sS -X POST \
                -H "Authorization: Bearer $GITHUB_TOKEN" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${REPO_SLUG}/issues/${PR_NUMBER}/comments" \
                -d '{"body": "/gemini review"}' 2>/dev/null); then
                echo "open-pr.sh: curl command failed to post /gemini review." >&2
                exit 9
            fi
            if echo "$RESPONSE" | jq -e '.id' >/dev/null 2>&1; then
                echo "gitflow: posted /gemini review on PR #$PR_NUMBER — Gemini will review within ~5 min" >&2
            else
                echo "open-pr.sh: failed to post /gemini review on PR #$PR_NUMBER via GitHub API." >&2
                echo "$RESPONSE" | jq -r '.message // .' >&2
                exit 9
            fi
        else
            echo "open-pr.sh: neither gh CLI nor \$GITHUB_TOKEN available — cannot post /gemini review trigger." >&2
            echo "  PR is open (#$PR_NUMBER). Post '/gemini review' as a PR comment manually," >&2
            echo "  or set GEMINI_NOT_INSTALLED=\"true\" in .claude/sync-substitutions.json if Gemini is absent." >&2
            exit 9
        fi
    fi
fi

# ─── Every linked issue → Staged on the project board ─────────────────────
# The gate above guaranteed each one is complete or confirmed. All of them are
# set, not only the newly confirmed: that is what repairs a board update that
# failed at /commit. The PR is already open at this point — on failure, fix the
# cause and set the status on the board; the transition is idempotent.
if [ -n "$LINKED_ISSUES" ]; then
    if ! stage_complete_issues "$LINKED_ISSUES" "$CURRENT_BRANCH"; then
        echo "open-pr.sh: the PR is open; only the board update failed. Fix the cause and set the status on the board." >&2
        exit 11
    fi
    if ! post_staged_notes "$LINKED_ISSUES" "$NOTES_DIR" "$CURRENT_BRANCH"; then
        echo "open-pr.sh: the PR is open and the board updated; only a Staged comment failed (see above)." >&2
        exit 13
    fi
fi

echo "gitflow: PR open complete." >&2
