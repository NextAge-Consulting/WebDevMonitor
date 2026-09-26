#!/bin/bash
# wait-for-pr-ready: poll until PR is ready for triage/merge.
#
# Ready = ALL CI checks pass AND
#         (no /gemini review trigger posted for current HEAD
#          OR Gemini Code Assist has posted a review on current HEAD).
#
# ─── Trigger-aware Gemini gating ───────────────────────────────────────
# Gemini Code Assist's auto-review on PR open is disabled in the kit's
# .gemini/config.yaml (pull_request_opened.code_review: false). Reviews
# fire only when a `/gemini review` comment is posted on the PR. The
# gitflow scripts post that comment at the moments where review is
# wanted: /open-pr always; /commit when the user passes --review (or
# accepts the prompt); /deploy never on release PRs (no code).
#
# The wait gate reads that comment history. If a `/gemini review` comment
# exists with `created_at` > HEAD's committer date, a review IS expected
# for this HEAD and we wait for it. If no such comment exists, no review
# is coming and we proceed on CI alone.
#
# This couples trigger and wait via observable state (comment presence)
# rather than per-callsite flags. /deploy doesn't need a --ci-only flag:
# it never posts the trigger on the release PR, the wait reads that, and
# proceeds CI-only automatically. Same for /merge after /commit --no-review.
#
# Comments don't need an author filter — a `/gemini review` comment is a
# `/gemini review` comment regardless of who posted it. Manual triggers
# from the user are treated identically to scripted triggers.
#
# GEMINI_NOT_INSTALLED="true" in .claude/sync-substitutions.json still
# short-circuits the entire Gemini path, for repos where the App is
# genuinely absent. In that mode no trigger should ever be posted (the
# trigger scripts honor the same flag), so the trigger check would
# return "no trigger" anyway — but the explicit short-circuit makes the
# intent clear and avoids one round-trip per poll cycle.
#
# CI gate is intentionally dumb: query every check on the PR (no
# `--required` filter), any FAILURE blocks, any PENDING/IN_PROGRESS
# keeps polling, all SUCCESS or empty list = pass.
#
# Re-reads HEAD + trigger state each cycle so user-pushed mid-wait commits
# retarget the poll.
#
# Usage: wait-for-pr-ready.sh [--pr <number>] [--timeout-min <minutes>] [--poll-sec <seconds>]
#
# Exit codes:
#   0  ready
#   2  any CI check FAILED on current HEAD
#   3  timeout
#   4  config / repo state error
#   5  user interrupted

set -e
trap 'echo "wait-for-pr-ready: interrupted" >&2; exit 5' INT

PR_NUMBER=""
TIMEOUT_MIN=15
POLL_SEC=30

while [[ $# -gt 0 ]]; do
    case $1 in
        --pr)            PR_NUMBER="$2"; shift 2 ;;
        --timeout-min)   TIMEOUT_MIN="$2"; shift 2 ;;
        --poll-sec)      POLL_SEC="$2"; shift 2 ;;
        *) echo "wait-for-pr-ready: unknown option: $1" >&2; exit 4 ;;
    esac
done

if ! command -v gh >/dev/null 2>&1; then
    echo "wait-for-pr-ready: gh CLI required." >&2
    exit 4
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "wait-for-pr-ready: jq required." >&2
    exit 4
fi

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$PROJECT_ROOT" ]; then
    echo "wait-for-pr-ready: not in a git repository." >&2
    exit 4
fi

SUBS_FILE="${PROJECT_ROOT}/.claude/sync-substitutions.json"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
if [ -z "$REPO" ]; then
    echo "wait-for-pr-ready: could not resolve repo via gh — run 'gh auth login'." >&2
    exit 4
fi

if [ -z "$PR_NUMBER" ]; then
    CURRENT_BRANCH=$(git branch --show-current)
    PR_NUMBER=$(gh pr list --head "$CURRENT_BRANCH" --state open --json number --jq '.[0].number // empty')
    if [ -z "$PR_NUMBER" ]; then
        echo "wait-for-pr-ready: no open PR found for branch $CURRENT_BRANCH." >&2
        exit 4
    fi
fi

read_gemini_not_installed() {
    [ -f "$SUBS_FILE" ] || { echo ""; return; }
    jq -r '.GEMINI_NOT_INSTALLED // ""' "$SUBS_FILE" 2>/dev/null || echo ""
}

# Returns: pass | fail | pending. Queries ALL checks on the PR via the
# statusCheckRollup field, which unifies CheckRuns + StatusContexts and — unlike
# `gh pr checks` — exits 0 with `[]` when the PR has no checks (instead of exit 1
# with "no checks reported"). That exit-code distinction matters: it lets us
# treat zero-checks as a clean pass (kit-style repos with no CI) while still
# treating actual gh CLI failures (auth/network/rate-limit) as pending+retry.
#
# Normalized state per check:
#   CheckRun.status == COMPLETED   → use .conclusion (SUCCESS / FAILURE / ...)
#   CheckRun.status == anything    → PENDING (in-flight)
#   StatusContext                  → use .state (SUCCESS / PENDING / FAILURE / ERROR)
# Aggregate:
#   Any FAILURE / CANCELLED / TIMED_OUT / ACTION_REQUIRED / ERROR → fail
#   Any PENDING / IN_PROGRESS / QUEUED / WAITING                  → pending
#   All SUCCESS / NEUTRAL / SKIPPED (or empty list)               → pass
ci_state() {
    local rollup
    if ! rollup=$(gh pr view "$PR_NUMBER" --json statusCheckRollup --jq '.statusCheckRollup' 2>/dev/null); then
        echo "pending"; return
    fi
    [ -z "$rollup" ] && { echo "pass"; return; }
    local count
    count=$(echo "$rollup" | jq 'length')
    if [ "$count" = "0" ]; then echo "pass"; return; fi
    local states
    states=$(echo "$rollup" | jq -r '
        [ .[] |
          if (.__typename // "") == "CheckRun" then
            (if .status == "COMPLETED" then .conclusion else "PENDING" end)
          else .state
          end
        ] | join(" ")')
    case " $states " in
        *" FAILURE "*|*" CANCELLED "*|*" TIMED_OUT "*|*" ACTION_REQUIRED "*|*" ERROR "*) echo "fail"; return ;;
    esac
    case " $states " in
        *" PENDING "*|*" IN_PROGRESS "*|*" QUEUED "*|*" WAITING "*) echo "pending"; return ;;
    esac
    echo "pass"
}

# Returns ISO-8601 timestamp of the HEAD commit's committer date.
# Used to scope trigger-comment lookups: only comments posted AFTER this
# timestamp count as triggers for the current HEAD. Older /gemini review
# comments (e.g. from prior triage rounds) MUST NOT arm the gate for a
# newer HEAD that nobody triggered.
head_committer_date() {
    local head=$1
    gh api "repos/$REPO/commits/$head" --jq '.commit.committer.date' 2>/dev/null || echo ""
}

# Returns: "yes" if a `/gemini review` PR comment exists with created_at >
# committer-date-of-HEAD; "no" otherwise. PR top-level comments live under
# the issues API (PRs are issues for comment-attachment purposes). Inline
# review comments use a different endpoint and are not the trigger surface.
#
# Body match is exact-line case-insensitive `/gemini review` to avoid
# matching prose like "I'll run /gemini review later". Future-proof: if
# Gemini adds variants like `/gemini review --focus security`, extend the
# match here.
gemini_trigger_for_head() {
    local head=$1
    local head_date
    head_date=$(head_committer_date "$head")
    # Empty head_date means head_committer_date's gh api call failed (any real
    # commit has a committer date). Return "error" so the poll loop retries
    # instead of falling through to the "no trigger → CI-only ready" path.
    [ -z "$head_date" ] && { echo "error"; return; }
    local count
    if ! count=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
        --jq '[.[] | select((.body // "") | test("(?i)^[[:space:]]*/gemini[[:space:]]+review[[:space:]]*$")) | select(.created_at > "'"$head_date"'")] | length' 2>/dev/null); then
        echo "error"; return
    fi
    [ "$count" -gt 0 ] 2>/dev/null && echo "yes" || echo "no"
}

# Returns count of Gemini inline review comments FRESHLY posted against current
# HEAD (>= 0), or "error" on transient gh api failure so callers can distinguish
# "no findings" from "lookup failed" instead of silently under-reporting.
#
# Filter on `original_commit_id` (IMMUTABLE — the commit Gemini wrote the comment
# against), NOT `commit_id`. On inline comments `commit_id` is MUTABLE: GitHub
# auto-bumps it to the latest HEAD wherever the flagged line still resolves, so a
# stale comment from a PRIOR review pass gets re-anchored to the current HEAD and
# counted — inflating the count ("Gemini raised 3", then /triage finds only 1
# fresh). Matches the /triage skill's Step 2 freshness rule (commands/triage.md):
# inline comments filter by original_commit_id, reviews by commit_id (which IS
# immutable on the /reviews endpoint — see gemini_review_for_head below).
gemini_findings_count_for_head() {
    local head=$1
    local count
    if ! count=$(gh api "repos/$REPO/pulls/$PR_NUMBER/comments" --paginate \
        --jq '[.[] | select(.user.login=="gemini-code-assist[bot]" and .original_commit_id=="'"$head"'")] | length' 2>/dev/null); then
        echo "error"; return
    fi
    echo "$count"
}

# Returns: posted | none | error. "posted" if any Gemini review exists with
# commit_id == current HEAD. "error" on transient gh api failure so the poll
# loop retries instead of stalling waiting for a review that may already exist.
gemini_review_for_head() {
    local head=$1
    local count
    if ! count=$(gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --paginate \
        --jq '[.[] | select(.user.login=="gemini-code-assist[bot]" and .commit_id=="'"$head"'")] | length' 2>/dev/null); then
        echo "error"; return
    fi
    [ "$count" -gt 0 ] 2>/dev/null && echo "posted" || echo "none"
}


# Gemini sometimes DECLINES to review — e.g. workflow-only diffs: "Gemini is
# unable to generate a review for this pull request due to the file types
# involved not being currently supported." That lands as an ISSUE COMMENT, not
# a review object, so the review wait would poll to TIMEOUT (observed on
# e.g. a small .github/workflows-only diff). A
# decline comment newer than HEAD's committer date is terminal for this HEAD —
# the gate treats it as reviewed-with-zero-findings. Returns: yes | no | error.
gemini_declined_for_head() {
    local head_date
    if ! head_date=$(gh api "repos/$REPO/commits/$1" --jq '.commit.committer.date' 2>/dev/null); then
        echo "error"; return
    fi
    local count
    if ! count=$(gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
        --jq '[.[] | select(.user.login=="gemini-code-assist[bot]") | select((.body // "") | test("(?i)unable to generate a review")) | select(.created_at > "'"$head_date"'")] | length' 2>/dev/null); then
        echo "error"; return
    fi
    [ "$count" -gt 0 ] 2>/dev/null && echo "yes" || echo "no"
}

START=$(date +%s)
TIMEOUT_SEC=$((TIMEOUT_MIN * 60))
LAST_HEAD=""
LAST_CI=""
LAST_TRIGGER=""
LAST_REVIEW=""

echo "wait-for-pr-ready: polling PR #$PR_NUMBER (timeout ${TIMEOUT_MIN}min, every ${POLL_SEC}s)" >&2

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))

    if [ "$ELAPSED" -gt "$TIMEOUT_SEC" ]; then
        echo "" >&2
        echo "wait-for-pr-ready: TIMEOUT after ${TIMEOUT_MIN}min." >&2
        echo "  CI state: $LAST_CI" >&2
        echo "  Gemini trigger for HEAD: $LAST_TRIGGER" >&2
        echo "  Gemini review on HEAD: $LAST_REVIEW (GEMINI_NOT_INSTALLED='$(read_gemini_not_installed)')" >&2
        echo "  Likely causes:" >&2
        echo "    - CI is genuinely slow; re-run with --timeout-min <larger>" >&2
        echo "    - /gemini review was posted but Gemini is queued / rate-limited (free tier quota: 33/day)" >&2
        echo "    - Gemini Code Assist App is not installed on $REPO (set GEMINI_NOT_INSTALLED=\"true\" in .claude/sync-substitutions.json)" >&2
        echo "    - PR is in draft state and .gemini/config.yaml has include_drafts: false" >&2
        exit 3
    fi

    HEAD=$(gh pr view "$PR_NUMBER" --json headRefOid -q .headRefOid 2>/dev/null || echo "")
    if [ -z "$HEAD" ]; then
        echo "wait-for-pr-ready: could not read PR HEAD; will retry." >&2
        sleep "$POLL_SEC"
        continue
    fi
    if [ "$HEAD" != "$LAST_HEAD" ] && [ -n "$LAST_HEAD" ]; then
        echo "wait-for-pr-ready: HEAD moved to ${HEAD:0:7} mid-wait — retargeting." >&2
    fi
    LAST_HEAD=$HEAD

    LAST_CI=$(ci_state)
    if [ "$LAST_CI" = "fail" ]; then
        echo "" >&2
        echo "wait-for-pr-ready: CI FAILED on PR #$PR_NUMBER." >&2
        echo "  Review: gh pr checks $PR_NUMBER" >&2
        exit 2
    fi

    GEMINI_NOT_INSTALLED=$(read_gemini_not_installed)
    if [ "$GEMINI_NOT_INSTALLED" = "true" ]; then
        LAST_TRIGGER="skipped"
        LAST_REVIEW="skipped"
    else
        LAST_TRIGGER=$(gemini_trigger_for_head "$HEAD")
        if [ "$LAST_TRIGGER" = "yes" ]; then
            LAST_REVIEW=$(gemini_review_for_head "$HEAD")
            if [ "$LAST_REVIEW" = "none" ] && [ "$(gemini_declined_for_head "$HEAD")" = "yes" ]; then
                LAST_REVIEW="declined"
            fi
        else
            LAST_REVIEW="n/a"
        fi
    fi

    # Ready conditions:
    #   - CI pass + Gemini gating skipped → ready
    #   - CI pass + no trigger for HEAD → ready (CI-only)
    #   - CI pass + trigger present + review posted → ready
    if [ "$LAST_CI" = "pass" ]; then
        if [ "$LAST_TRIGGER" = "skipped" ]; then
            echo "wait-for-pr-ready: ready (CI=$LAST_CI, Gemini=skipped, HEAD=${HEAD:0:7}, ${ELAPSED}s elapsed)" >&2
            exit 0
        fi
        if [ "$LAST_TRIGGER" = "no" ]; then
            echo "wait-for-pr-ready: ready (CI=$LAST_CI, Gemini=no-trigger-for-HEAD, HEAD=${HEAD:0:7}, ${ELAPSED}s elapsed)" >&2
            exit 0
        fi
        if [ "$LAST_REVIEW" = "declined" ]; then
            echo "wait-for-pr-ready: ready (CI=$LAST_CI, Gemini=declined-unsupported-files, findings=0, HEAD=${HEAD:0:7}, ${ELAPSED}s elapsed)" >&2
            exit 0
        fi
        if [ "$LAST_REVIEW" = "posted" ]; then
            FINDINGS=$(gemini_findings_count_for_head "$HEAD")
            echo "wait-for-pr-ready: ready (CI=$LAST_CI, Gemini=posted, findings=$FINDINGS, HEAD=${HEAD:0:7}, ${ELAPSED}s elapsed)" >&2
            if [ "$FINDINGS" = "error" ]; then
                echo "wait-for-pr-ready: findings lookup failed (transient gh api error). Run /triage to be safe before /merge." >&2
            elif [ "$FINDINGS" -gt 0 ] 2>/dev/null; then
                echo "wait-for-pr-ready: Gemini raised $FINDINGS finding(s). Run /triage to walk them, or /merge to ship without triage." >&2
            fi
            exit 0
        fi
    fi

    printf "wait-for-pr-ready: %ds elapsed — CI=%s, trigger=%s, review=%s, HEAD=%s\n" \
        "$ELAPSED" "$LAST_CI" "$LAST_TRIGGER" "$LAST_REVIEW" "${HEAD:0:7}" >&2

    sleep "$POLL_SEC"
done
