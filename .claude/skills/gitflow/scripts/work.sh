#!/bin/bash
# gitflow work: start or resume a body of work on a branch in this checkout.
#
# Usage:
#   work.sh                              # refresh main and stay put, or resume the current branch
#   work.sh --issue <N[,N…]>            # link issue(s) to the current branch, dump their context
#   work.sh --retrieve <branch>          # fetch a teammate's branch and switch to it
#   work.sh --discussion <slug|url>      # default mode, then print a finished discussion's folder
#
# Responsibilities:
#   - On main: refresh main from origin and STAY THERE. No branch is cut.
#   - On any other branch: resume it, untouched.
#   - For --issue: validate, link the issue via git config on the CURRENT branch,
#     transition to In Progress, assign the current user, dump issue context for
#     the Claude session. No branch is cut — see below.
#   - For --retrieve: fetch the remote branch, fast-forward any local copy, switch.
#   - For --discussion: find the discussion folder the analysis skill wrote (by its
#     slug or by the artifact URL recorded in its pointer), run the default mode,
#     then print the pointer and the folder's files. Reading the published page and
#     its comments needs Claude's own tools, so the pull-back itself is work.md's.
#
# One checkout, one branch at a time. Parallel bodies of work are not a thing
# this shop does; `git switch` is how you move between them when it is.
#
# WHY BARE `work.sh` DOES NOT CUT A BRANCH
# ----------------------------------------
# It used to, and that was wrong in both directions.
#
# It removed a choice that had not been made yet. At session-init nobody knows
# whether the session is a feature, a kit/infra change, or a question answered
# from the handoff — and `/ship-main` REFUSES unless you are on main, so cutting
# a branch here guaranteed the infra path was blocked before it began. The two
# commands contradicted each other on every infra session.
#
# And it bought nothing, because the safety already exists downstream and is
# strictly better there: `/commit` on main auto-creates a branch named from the
# commit MESSAGE, and `git-guard.sh` blocks raw `git commit`.
#
# So the branch belongs to the moment the decision is actually made — the first
# commit — not to session-init. `--issue N` is NOT an exception to that. An
# issue number says what the work is ABOUT, never which pipeline it belongs in:
# an issue can be a docs or infra change that belongs straight on main, and in
# a repo with no CI and no deploy the PR round-trip buys nothing at all. Cutting
# a branch on the issue number made /ship-main unreachable for the whole session,
# which is the same failure the paragraph above describes.
#
# --issue therefore parks the link on the current branch and lets the first
# commit carry it across (migrate_branch_linked_issues). /ship-main consumes it
# instead, as a `Closes #N` line for each issue answered code complete — so an
# issue still reaches the deploy status with no PR anywhere in the picture.

set -eo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # propagate errexit into $(…) subshells (bash 4.4+)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"
# shellcheck source=_claude-project/skills/gitflow/scripts/issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

# ─── Arg parsing ───────────────────────────────────────────────────────────

MODE=""        # "", "issue", "retrieve", "discussion"
ARG=""         # the value for the mode (issue#, branch, discussion slug or URL)

# A value flag given last with no value leaves one argument to shift, not two;
# `shift 2` would then fail and end the script before the mode could say what
# was missing. Each mode reports its own empty value.
while [[ $# -gt 0 ]]; do
    case $1 in
        --issue)
            [ -n "$MODE" ] && { echo "work.sh: --issue conflicts with --$MODE" >&2; exit 2; }
            MODE="issue"; ARG="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
        --retrieve)
            [ -n "$MODE" ] && { echo "work.sh: --retrieve conflicts with --$MODE" >&2; exit 2; }
            MODE="retrieve"; ARG="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
        --discussion)
            [ -n "$MODE" ] && { echo "work.sh: --discussion conflicts with --$MODE" >&2; exit 2; }
            MODE="discussion"; ARG="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
        *)
            # Bare positional issue token(s) → shorthand for --issue. Accepts
            # every shape --issue does ("27", "27,28", "#27,#28", "27, 28"), so
            # the two spellings cannot disagree, and the pattern demands a
            # leading digit or #, so a branch name never matches and still
            # reaches the error below.
            #
            # Tokens ACCUMULATE rather than overwrite, which is what makes
            # `work.sh 27 28` work. The shell splits that into two arguments
            # before this loop ever sees it, so a version that only took the
            # first rejected the second as an unknown option — the spelling a
            # person is most likely to type by hand.
            if [[ "$1" =~ ^[#0-9][#0-9,\ ]*$ ]] && { [ -z "$MODE" ] || [ "$MODE" = "issue" ]; }; then
                MODE="issue"; ARG="${ARG:+$ARG,}$1"; shift 1
            else
                echo "work.sh: unknown option: $1" >&2; exit 2
            fi
            ;;
    esac
done

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "work.sh: not in a git repository" >&2
    exit 3
}
cd "$PROJECT_ROOT"

# ─── Guard: a retired global /work command shadows this project's copy ─────
# Claude Code resolves command files personal-over-project: with `work.md` in
# BOTH `~/.claude/commands/` and `<project>/.claude/commands/`, the personal one
# wins and the project's copy never loads. The kit used to ship `work.md`
# globally and no longer does — so a machine that installed it once keeps
# running the retired doc forever, silently, while the kit's current copy sits
# there inert.
#
# Nothing in the kit's own maintenance path can fix that: `/sync-dev-kit` does
# not scan `~/.claude/` by design, and there is no installer to reconcile it.
# This script is the only thing that runs on EVERY `/work` — and it runs whichever
# doc won, because both invoke it. So this is the one place the stale file can be
# caught. Fail loud rather than warn: a warning on a session-init command is read
# past, and the whole point is that the failure is otherwise invisible.
GLOBAL_WORK_CMD="$HOME/.claude/commands/work.md"
if [ -f "$GLOBAL_WORK_CMD" ]; then
    cat >&2 <<EOF
work.sh: REFUSING — a retired global /work command is shadowing this project's copy.

  Found:   $GLOBAL_WORK_CMD
  Shadows: $PROJECT_ROOT/.claude/commands/work.md

  Personal commands outrank project commands, so the file above is what /work
  reads — and it is the OLD version, which cuts a wip branch at session-init and
  blocks /ship-main. The kit no longer ships a global /work.

  Fix it with one command, then re-run /work:

      rm "$GLOBAL_WORK_CMD"

  Nothing else is needed. The project's copy takes over immediately.
EOF
    exit 8
fi

# ─── Helper: is the working tree clean? ────────────────────────────────────
# Untracked counts as dirty: an untracked file is usually the bulk of a
# half-finished change, and treating it as "clean" is how work gets stranded.
tree_is_clean() {
    git diff --quiet 2>/dev/null && \
        git diff --cached --quiet 2>/dev/null && \
        [ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]
}

# ─── Helper: refresh main, tolerating a dirty tree ─────────────────────────
# fast_forward_local_main refuses on a dirty tree by design — it is also used
# by /catchup, where a dirty tree means something is wrong. Here it does not:
# starting work with edits already in the tree is ordinary (you noticed
# something before you typed /work), and those edits stay exactly where they are.
#
# So: refresh when we can, say so loudly when we cannot, and never block.
# Nothing is lost either way — main is simply left at the commit you already had.
refresh_main_if_possible() {
    if tree_is_clean; then
        if ! fast_forward_local_main; then
            echo "work.sh: could not refresh main from origin (cause above)." >&2
            echo "  Branching off local main as it stands. /catchup once you are online." >&2
        fi
    else
        echo "work.sh: uncommitted changes present — NOT refreshing main from origin." >&2
        echo "  Your changes are untouched." >&2
        main_drift_report main work.sh || true
    fi
}

# ─── Mode: default ─────────────────────────────────────────────────────────
# On main  → refresh main and stay on it. No branch is cut; see the header for why.
# Elsewhere → resume; this is the re-entry path across consecutive sessions.
mode_default() {
    local branch
    branch=$(git branch --show-current)

    if [ -z "$branch" ]; then
        echo "work.sh: detached HEAD — no branch to start or resume." >&2
        echo "  Inspect with 'git status', then switch to a branch." >&2
        exit 7
    fi

    if is_protected_branch "$branch"; then
        refresh_main_if_possible
        echo "work.sh: on '$branch' — no branch cut; the session has not chosen a path yet." >&2
        echo "  /commit branches from your message · /ship-main commits here." >&2
        report_parked_issue_links "$branch"
        if ! tree_is_clean; then
            echo "work.sh: (uncommitted changes present — they follow you onto whichever path you take)" >&2
        fi
    else
        echo "work.sh: resuming body of work on '$branch'." >&2
        # Resuming refreshes nothing — but a main that moved while this branch sat
        # is exactly what the rest of the body of work would otherwise trip over.
        main_drift_report main work.sh || true
        if ! tree_is_clean; then
            echo "work.sh: (uncommitted changes present — picking up where you left off)" >&2
        fi
    fi
}

# ─── Mode: --issue <N[,N…]> ────────────────────────────────────────────────
#
# Linking the FIRST issue and linking a further issue mid-work are the same act,
# so this is the only place either happens. Nothing here cares whether the branch
# already carries links; `link_issue_to_branch` is idempotent and the git-config
# list simply grows.
mode_issue() {
    local nums
    nums=$(parse_issue_csv "$ARG")
    if [ -z "$nums" ]; then
        echo "work.sh: --issue had no valid issue numbers: '$ARG'" >&2
        echo "  Accepts: 27 · 27,28 · '#27 #28'" >&2
        exit 2
    fi

    local branch num
    branch=$(git branch --show-current)

    if [ -z "$branch" ]; then
        echo "work.sh: detached HEAD — refusing to link $(format_issue_refs "$nums")." >&2
        echo "  Inspect with 'git status', then switch to a branch." >&2
        exit 7
    fi

    # EVERY issue is validated before ANY side-effect fires. Validating inside
    # the apply loop would leave the first two issues linked, transitioned and
    # assigned when the third turns out to be a typo — a half-applied state the
    # user then has to find and unpick by hand.
    for num in $nums; do
        if ! validate_issue "$num" >/dev/null; then
            echo "work.sh: issue #$num inaccessible; aborting without linking anything" >&2
            exit 4
        fi
    done

    if is_protected_branch "$branch"; then
        # No branch is cut here. An issue number says what the work is ABOUT,
        # not which pipeline it belongs in: plenty of issues are a docs or
        # infra change that should go straight to main, and cutting a branch
        # now blocks /ship-main for the rest of the session. The link parks on
        # this branch and the first commit carries it onto whatever branch it
        # creates. See the header.
        refresh_main_if_possible
        echo "work.sh: $(format_issue_refs "$nums") linked on '$branch' — no branch cut." >&2
        echo "  /commit branches from your message and carries the link · /ship-main commits here and closes it." >&2
    else
        # Already on a body of work → one more issue on it.
        echo "work.sh: on branch '$branch' — linking $(format_issue_refs "$nums") to it." >&2
    fi

    for num in $nums; do
        link_issue_to_branch "$num"
        move_issue_to_in_progress "$num"
        assign_issue_to_current_user "$num"
    done

    # Context last, and in its own loop: the linking chatter above is noise the
    # reader scrolls past, and the issue bodies are the part actually read.
    for num in $nums; do
        dump_issue_context "$num"
    done
}

# ─── Mode: --retrieve <branch> ─────────────────────────────────────────────
# Fetch someone else's branch and switch to it. Refuses on a dirty tree: your
# own work has to be committed before you leave it, or switching either drags
# it along or blocks halfway. /checkpoint is the one-verb answer.
mode_retrieve() {
    local branch="$ARG"
    if [ -z "$branch" ]; then
        echo "work.sh: --retrieve requires a branch name" >&2
        exit 2
    fi

    if ! tree_is_clean; then
        echo "work.sh: uncommitted changes on '$(git branch --show-current)'." >&2
        echo "  /checkpoint first, then re-run — switching branches with work in the tree" >&2
        echo "  either drags it onto theirs or refuses partway." >&2
        exit 5
    fi

    echo "work.sh: fetching origin/$branch" >&2
    if ! git fetch origin "$branch" 2>/dev/null; then
        echo "work.sh: branch '$branch' not found on origin" >&2
        exit 4
    fi

    # Fetching alone leaves an existing local branch pointing at the old commit.
    sync_local_branch "$branch"

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git checkout "$branch" >&2
    else
        git checkout -b "$branch" "origin/$branch" >&2
    fi
    echo "work.sh: on '$branch'. Your own branch is untouched — 'git switch <yours>' when you are done here." >&2
}

# ─── Mode: --discussion <slug|url> ─────────────────────────────────────────
# A discussion lives in project-documentation/temporary/discussion-<slug>/, with a
# pointer <slug>-discussion.md whose front matter records the artifact URL. The human
# copies whichever is to hand — the slug from the folder, or the URL from the browser
# tab the discussion happened in — so both resolve.
#
# Resolved BEFORE the default mode runs: a typo fails with nothing refreshed.
DISCUSSION_ROOT="project-documentation/temporary"

# The artifact id is the URL's last path segment; the query, fragment and a
# trailing slash are noise a copied link may carry.
artifact_id_of() {
    local u="$1"
    u="${u%%[?#]*}"
    u="${u%/}"
    printf '%s\n' "${u##*/}"
}

pointer_artifact() {
    awk '/^artifact:/ { sub(/^artifact:[ \t]*/, ""); print; exit }' "$1"
}

list_open_discussions() {
    local p d found=""
    for p in "$DISCUSSION_ROOT"/discussion-*/*-discussion.md; do
        [ -f "$p" ] || continue
        found=1
        d="${p%/*}"
        echo "  ${d##*/discussion-}  $(pointer_artifact "$p")" >&2
    done
    [ -n "$found" ] || echo "  (none — no discussion-*/ folder under $DISCUSSION_ROOT/)" >&2
}

resolve_discussion() {
    local want="$1" p slug id
    if [[ "$want" == *"://"* ]]; then
        id=$(artifact_id_of "$want")
        for p in "$DISCUSSION_ROOT"/discussion-*/*-discussion.md; do
            [ -f "$p" ] || continue
            [ "$(artifact_id_of "$(pointer_artifact "$p")")" = "$id" ] && { dirname "$p"; return 0; }
        done
        return 1
    fi
    slug="${want#discussion-}"
    slug="${slug%/}"
    [ -f "$DISCUSSION_ROOT/discussion-$slug/$slug-discussion.md" ] || return 1
    echo "$DISCUSSION_ROOT/discussion-$slug"
}

mode_discussion() {
    if [ -z "$ARG" ]; then
        echo "work.sh: --discussion requires a slug or the artifact URL" >&2
        exit 2
    fi

    local dir
    if ! dir=$(resolve_discussion "$ARG"); then
        echo "work.sh: no discussion matches '$ARG'. Open discussions:" >&2
        list_open_discussions
        exit 4
    fi

    mode_default

    local slug f
    slug="${dir##*/discussion-}"
    echo "work.sh: discussion '$slug' — $dir/" >&2
    echo "=== DISCUSSION FOLDER: $dir/ ==="
    for f in "$dir"/*; do
        [ -e "$f" ] && echo "  ${f##*/}"
    done
    echo "=== POINTER: $dir/$slug-discussion.md ==="
    cat "$dir/$slug-discussion.md"
}

# Fast-forward a local branch to origin when it is strictly behind.
#
# Without this, --retrieve fetches origin/<branch> and then checks out the LOCAL
# branch, so a teammate's pushed commits are fetched and ignored — you land on a
# stale copy with no warning. That breaks the round trip the flag exists for.
#
# Fast-forward ONLY. A local branch carrying commits origin does not have is left
# untouched and reported; silently rewriting it would destroy work.
sync_local_branch() {
    local branch="$1"
    git show-ref --verify --quiet "refs/heads/$branch" || return 0
    git show-ref --verify --quiet "refs/remotes/origin/$branch" || return 0

    local local_sha remote_sha
    local_sha=$(git rev-parse "refs/heads/$branch")
    remote_sha=$(git rev-parse "refs/remotes/origin/$branch")
    [ "$local_sha" = "$remote_sha" ] && return 0

    if ! git merge-base --is-ancestor "$local_sha" "$remote_sha"; then
        echo "work.sh: local '$branch' has commits origin does not have — leaving it as is." >&2
        echo "work.sh:   local  $local_sha" >&2
        echo "work.sh:   origin $remote_sha" >&2
        echo "work.sh: reconcile the two before continuing." >&2
        return 0
    fi

    # Strictly behind. If it is the branch we are standing on, the merge has to
    # happen in the working tree; otherwise moving the ref is enough.
    if [ "$branch" = "$(git branch --show-current)" ]; then
        echo "work.sh: fast-forwarding '$branch' to origin" >&2
        git merge --ff-only "origin/$branch" >&2
    else
        echo "work.sh: fast-forwarding local '$branch' to origin" >&2
        git update-ref "refs/heads/$branch" "$remote_sha"
    fi
}

# ─── Dispatch ──────────────────────────────────────────────────────────────
case "$MODE" in
    "")         mode_default ;;
    "issue")    mode_issue ;;
    "retrieve") mode_retrieve ;;
    "discussion") mode_discussion ;;
    *)
        echo "work.sh: internal error — unknown mode '$MODE'" >&2
        exit 99
        ;;
esac
