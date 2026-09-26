#!/bin/bash
# gitflow branch helpers: shared functions for branch creation and rename.
# Sourced by the gitflow command scripts. Every function is safe under `set -e`.

# is_protected_branch <name> — returns 0 if branch is main or master.
is_protected_branch() {
    [ "$1" = "main" ] || [ "$1" = "master" ]
}

# derive_branch_from_message <commit_message> — echoes <type>/<slug> derived from
# the first line of a conventional commit message.
derive_branch_from_message() {
    local msg="$1"
    local first_line="${msg%%$'\n'*}"

    local type="chore"
    local description="$first_line"

    # Conventional commit format requires a colon. If missing, fall back to chore/<slug>.
    if [[ "$first_line" == *:* ]]; then
        local before_colon="${first_line%%:*}"
        description="${first_line#*:}"
        description="${description# }"

        # Type = FIRST lowercase word before the colon (strip ! breaking marker).
        # Conventional commits are `type(scope):` — the type comes first, the
        # optional scope comes second in parens. Using `tail -1` wrongly picked
        # the scope as the branch prefix (e.g., `fix(gitflow):` → `gitflow/...`
        # instead of `fix/...`). `head -1` selects the type regardless of
        # whether a scope is present.
        local extracted
        extracted=$(printf '%s' "$before_colon" | grep -oE '[a-z]+!?' | head -1 | tr -d '!')
        [ -n "$extracted" ] && type="$extracted"
    fi

    # Slugify description: lowercase, non-alnum → '-', collapse, trim, truncate to 40 chars.
    local slug
    slug=$(printf '%s' "$description" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-40 \
        | sed -E 's/-+$//')
    [ -z "$slug" ] && slug="changes"

    echo "${type}/${slug}"
}

# branch_exists <name> — returns 0 if branch exists locally or on origin.
branch_exists() {
    local name="$1"
    if git show-ref --verify --quiet "refs/heads/$name"; then
        return 0
    fi
    if git ls-remote --exit-code --heads origin "$name" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# resolve_collision <base_name> — echoes a free branch name, appending -2, -3, etc.
# if base_name is taken.
resolve_collision() {
    local base="$1"
    local candidate="$base"
    local n=2
    while branch_exists "$candidate"; do
        candidate="${base}-${n}"
        n=$((n + 1))
    done
    echo "$candidate"
}

# create_and_switch <name> — creates branch from current HEAD and switches to it.
# Carries uncommitted changes via git's default checkout -b behavior.
create_and_switch() {
    local name="$1"
    git checkout -b "$name"
}

# safe_push — push the current branch to origin, ensuring upstream is set
# to the matching remote branch (origin/<local-branch>).
#
# Why this exists: a plain `git push` under `push.default=simple` (the modern
# default) requires the branch's upstream name to match the local branch name.
# Several flows in this repo can leave a branch with the WRONG upstream:
#
#   - A branch created from `origin/main` can inherit origin/main as its
#     upstream (branch.autoSetupMerge). `push.default=simple` then refuses
#     plain `git push` because "main" != "<new>". This function is the
#     belt-and-suspenders so any branch with leftover bogus tracking still
#     pushes correctly.
#
# Detection: read @{u} via rev-parse --symbolic-full-name. If it matches
# origin/<local-branch>, do a plain `git push` (preserves the user's
# explicit `--force` / extra args via "$@"). Otherwise, treat the upstream
# as unset-or-wrong and use `git push -u origin <local-branch>` to
# (re)point it correctly. The -u flag overwrites any existing
# branch.<name>.{remote,merge} config — that's the whole point.
safe_push() {
    local local_branch upstream expected
    local_branch=$(git branch --show-current)
    if [ -z "$local_branch" ]; then
        echo "gitflow: safe_push — detached HEAD, refusing to push." >&2
        return 1
    fi
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
    expected="origin/${local_branch}"
    if [ "$upstream" = "$expected" ]; then
        git push "$@"
    else
        # No upstream OR upstream points elsewhere (e.g. origin/main from
        # inherited from the start-point). Set/correct tracking and push.
        git push -u origin "$local_branch" "$@"
    fi
}

# ─── Checkpoints ──────────────────────────────────────────────────────────
# A checkpoint is a LOCAL commit on whatever branch is checked out — main
# included — and is never pushed. /commit and /ship-main fold every unpushed
# checkpoint into the one real commit they make, so a `🔖 wip:` subject never
# reaches origin, where /deploy would read it to compute the version bump.
CHECKPOINT_PREFIX='🔖 wip:'

# checkpoint_fold_base — echoes the commit that the trailing run of unpushed
# checkpoint commits sits on; HEAD itself when there are none.
#
# Walks back from HEAD while the commit is a checkpoint AND no remote ref
# contains it. A pushed checkpoint (from before checkpoints went local) is never
# folded: rewriting it would need a force-push. A root commit stops the walk.
checkpoint_fold_base() {
    local base subject
    base=$(git rev-parse HEAD)
    while :; do
        subject=$(git log -1 --format=%s "$base")
        case "$subject" in
            "$CHECKPOINT_PREFIX"*) ;;
            *) break ;;
        esac
        [ -z "$(git for-each-ref --contains "$base" --format='%(refname)' refs/remotes)" ] || break
        git rev-parse --verify --quiet "${base}^" >/dev/null || break
        base=$(git rev-parse "${base}^")
    done
    echo "$base"
}

# fold_checkpoints <base> — soft-reset HEAD to <base>, so every checkpoint
# commit above it becomes staged content for the caller's single commit.
# No-op when <base> is HEAD. Run it only after every gate has passed: a gate
# that fails afterwards would leave the checkpoints already unwound.
fold_checkpoints() {
    local base="$1" n
    [ "$base" = "$(git rev-parse HEAD)" ] && return 0
    n=$(git rev-list --count "${base}..HEAD")
    echo "gitflow: folding $n checkpoint commit(s) into this commit." >&2
    git reset --soft "$base"
}

# fast_forward_local_main — refresh local main from origin/main (fail-loud).
#
# Used in two places:
#   1. /catchup invoked while standing on main (no body of work in flight, or
#      the user is just reviewing) — updates local main.
#   2. /work cutting a NEW body-of-work branch — ensures the branch is
#      branched off freshly-pulled main, not a stale local copy.
#
# Caller MUST be standing on main when invoking — this fast-forwards the
# checked-out branch.
#
# Failure semantics (fail-loud):
#   - Not on main/master → exit 3, instruct caller
#   - Working tree dirty → exit 5, refuse (a fast-forward would either fail or
#     silently strand the edits; /work handles the dirty case separately)
#   - `git fetch origin main` fails → exit 6 (network / auth / scope)
#   - Local main has commits origin/main lacks → exit 7. Checkpoints are the
#     one ordinary cause (they are local by design), and the message names
#     /commit or /ship-main as the way out; anything else is anomalous
#   - Already up-to-date → exit 0 with informational message
#   - Fast-forward succeeds → exit 0, report old → new SHA + commits pulled
fast_forward_local_main() {
    local branch
    branch=$(git branch --show-current)
    if [ -z "$branch" ]; then
        echo "fast_forward_local_main: detached HEAD — cannot refresh main." >&2
        return 3
    fi
    if ! is_protected_branch "$branch"; then
        echo "fast_forward_local_main: must be on main (currently on '$branch')." >&2
        return 3
    fi

    if ! git diff --quiet 2>/dev/null \
       || ! git diff --cached --quiet 2>/dev/null \
       || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
        echo "fast_forward_local_main: working tree on $branch has uncommitted or untracked changes." >&2
        echo "  Commit, checkpoint, or stash them before refreshing main." >&2
        echo "  Inspect with 'git status' and resolve before re-running." >&2
        return 5
    fi

    echo "gitflow: fetching origin/$branch." >&2
    local fetch_out
    if ! fetch_out=$(git fetch origin "$branch" 2>&1); then
        echo "fast_forward_local_main: git fetch origin $branch failed: $fetch_out" >&2
        echo "  Fix: check network + gh auth (gh auth status)." >&2
        return 6
    fi

    local local_sha remote_sha
    local_sha=$(git rev-parse HEAD)
    remote_sha=$(git rev-parse "origin/$branch")

    if [ "$local_sha" = "$remote_sha" ]; then
        echo "gitflow: $branch already at origin/$branch ($local_sha) — nothing to pull." >&2
        return 0
    fi

    if git merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null; then
        # Local is strict ancestor of remote → clean fast-forward.
        local n
        n=$(git rev-list --count "$local_sha..$remote_sha")
        echo "gitflow: fast-forwarding $branch: ${local_sha:0:8} → ${remote_sha:0:8} (+$n commit(s))." >&2
        if ! git merge --ff-only "origin/$branch"; then
            echo "fast_forward_local_main: merge --ff-only failed unexpectedly." >&2
            return 6
        fi
        return 0
    fi

    if [ "$(checkpoint_fold_base)" != "$local_sha" ]; then
        echo "fast_forward_local_main: local $branch carries unpushed checkpoint commits." >&2
        echo "  /commit (branch + PR) or /ship-main (straight to $branch) folds them into one real commit." >&2
        return 7
    fi

    if git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
        echo "fast_forward_local_main: local $branch is AHEAD of origin/$branch." >&2
        echo "  Local has commits not on origin/$branch — anomalous under gitflow's model (main is read-only)." >&2
        echo "  Inspect with: git log origin/$branch..HEAD" >&2
        return 7
    fi

    echo "fast_forward_local_main: local $branch and origin/$branch have DIVERGED (no fast-forward path)." >&2
    echo "  Local SHA:  $local_sha" >&2
    echo "  Remote SHA: $remote_sha" >&2
    echo "  Inspect with: git log --oneline --all --graph origin/$branch HEAD" >&2
    return 7
}

# main_drift_report [base] [who] — say how far the current branch has fallen
# behind origin/<base>, and which files both sides touched. Silent when it has not.
#
# A branch cut from a stale local main, or left open while another PR merges,
# otherwise goes unnoticed until the final squash fails — after the review, the
# triage and the build have all run on code that cannot merge. So every command
# that starts or advances a body of work calls this and reports early, while the
# conflict is still small and the tree is still yours.
#
# "Ours" counts uncommitted and untracked changes too: on main, before /commit
# cuts a branch, the whole body of work is still in the working tree.
#
# Returns 0 when HEAD already contains origin/<base>, and also when the fetch
# failed (reported — being offline never blocks work). Returns 10 when HEAD is
# behind. Callers WARN on 10; only /merge refuses, and only on a real conflict
# (main_merge_conflicts).
main_drift_report() {
    local base="${1:-main}" who="${2:-gitflow}" target mb n theirs ours overlap
    target="origin/$base"
    if ! git fetch -q origin "$base" 2>/dev/null; then
        echo "$who: could not fetch $target — whether $base has moved is unknown." >&2
        return 0
    fi
    if git merge-base --is-ancestor "$target" HEAD 2>/dev/null; then
        return 0
    fi
    if ! mb=$(git merge-base HEAD "$target" 2>/dev/null); then
        return 0
    fi
    n=$(git rev-list --count "HEAD..$target")
    echo "$who: $base has moved — this checkout is $n commit(s) behind $target:" >&2
    git log -n 10 --format='    %h %s' "HEAD..$target" >&2
    if [ "$n" -gt 10 ]; then
        echo "    … and $((n - 10)) more" >&2
    fi
    theirs=$(git diff --name-only "$mb" "$target" | sort -u)
    ours=$( { git diff --name-only "$mb" HEAD; git diff --name-only HEAD; \
              git ls-files --others --exclude-standard; } | sort -u)
    overlap=$(comm -12 <(printf '%s\n' "$theirs") <(printf '%s\n' "$ours") | grep -v '^$' || true)
    if [ -n "$overlap" ]; then
        echo "  Changed on both sides — catch up now, while the conflict is small:" >&2
        printf '%s\n' "$overlap" | sed -n '1,20s/^/    /p' >&2
    fi
    if is_protected_branch "$(git branch --show-current)"; then
        echo "  Run /catchup to fast-forward $base (commit or checkpoint uncommitted edits first)." >&2
    else
        echo "  Run /catchup to merge $base into this branch." >&2
    fi
    return 10
}

# main_merge_conflicts [base] — would merging origin/<base> into HEAD conflict?
#
# A trial merge with `git merge-tree`: nothing in the working tree, the index or
# any ref is touched. Deterministic and local, unlike the host's own "mergeable"
# flag, which is recomputed asynchronously and reads UNKNOWN for seconds after
# every push. Needs git 2.38+.
#
# Returns 0 when it merges cleanly, 1 on a conflict (conflicted paths printed),
# 2 when it cannot tell (old git, missing ref) — callers treat 2 as unknown.
main_merge_conflicts() {
    local base="${1:-main}" out rc
    # `&& rc=0 || rc=$?`, never a bare assignment: under a caller's `set -e` a
    # conflict (exit 1) would otherwise end the caller instead of reporting.
    out=$(git merge-tree --write-tree --name-only --no-messages HEAD "origin/$base" 2>/dev/null) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    if [ "$rc" -eq 1 ]; then
        printf '%s\n' "$out" | sed -n '2,$ { /^$/d; s/^/    /; p; }' >&2
        return 1
    fi
    return 2
}
