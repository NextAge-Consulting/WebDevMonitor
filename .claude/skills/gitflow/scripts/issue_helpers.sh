#!/bin/bash
# gitflow issue helpers: shared functions for /work to resolve
# GitHub issues, link them to the current branch, transition project status,
# assign the current user, and dump issue context for the Claude session.
#
# Sourced by work.sh, commit.sh, checkpoint.sh, ship-main.sh, open-pr.sh and
# deploy.sh.
#
# ─── Design notes ──────────────────────────────────────────────────────────
# - Issue→branch linking is stored in git config (branch-scoped):
#     branch.<name>.gitflow-issues = "23 25 26"
#   Git auto-removes branch config on `git branch -D`, so stale state doesn't
#   accumulate after merges.
#
# - An issue is marked CODE COMPLETE per branch, in a second list beside the
#   links: branch.<name>.gitflow-complete = "23 25". /commit and /ship-main ask
#   which linked issues are complete; /open-pr refuses to open while any linked
#   issue is not. Complete is what moves an issue to Staged.
#
# - `/open-pr` and `/ship-main` write `Closes #<N>` for complete issues. That
#   line is the history and it is how /deploy finds what shipped. Whether it
#   actually closes anything is GitHub configuration, not gitflow's: the
#   repository's "Auto-close issues with merged linked pull requests" setting,
#   and the board's "Auto-close issue" workflow
#   (project-documentation/github-project-board-setup.md).
#
# - Failure semantics (zero-tolerance fail-loud-when-configured):
#   * GITFLOW_PROJECT_ID empty → feature off, silent skip (kit default).
#   * GITFLOW_PROJECT_ID populated but other config missing → ERROR + return 1.
#   * Issue not on configured project → ERROR + return 1.
#   * GraphQL mutation fails (typically missing `project` scope) → ERROR + return 1.
#   * Issue assignment failure → ERROR + return 1 (always — not gated on PROJECT_ID).
#   work.sh runs under `set -e` so a non-zero return
#   propagates to script exit; the user retries after fixing the config /
#   scope / project-membership cause. All GraphQL operations are idempotent.
#
# - Config (project/field/option IDs) comes from .claude/gitflow-project.conf
#   at repo root. Empty values are explicit feature-off; partial config
#   (PROJECT_ID set, STATUS_FIELD_ID missing) is an error, not silent.
#   Kit template ships this file empty; per-repo setup fills it in.

# ─── Config loading ────────────────────────────────────────────────────────
# Call once per script; subsequent invocations re-source cleanly.
load_gitflow_project_config() {
    local config_path
    config_path="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/gitflow-project.conf"
    if [ -f "$config_path" ]; then
        # shellcheck disable=SC1090
        source "$config_path"
    fi
}

# ─── Issue-number parsing ──────────────────────────────────────────────────
# parse_issue_csv "23,25,#26 #42" → echoes "23 25 26 42" (space-separated)
# Accepts any combination of commas, spaces, and optional # prefixes.
parse_issue_csv() {
    local raw="$1"
    printf '%s' "$raw" \
        | tr ',' ' ' \
        | tr -s ' ' \
        | sed -E 's/#//g' \
        | tr ' ' '\n' \
        | sed -n -E '/^[0-9]+$/p' \
        | tr '\n' ' ' \
        | sed -E 's/ +$//'
}

# ─── GitHub repo resolution ────────────────────────────────────────────────
# Resolves owner/repo from origin remote URL. Echoes "owner/repo".
gitflow_repo_slug() {
    local url
    url=$(git config --get remote.origin.url)
    # Handles https://github.com/OWNER/REPO.git and git@github.com:OWNER/REPO.git
    echo "$url" | sed -E 's#(git@github\.com:|https://github\.com/)([^/]+/[^/.]+)(\.git)?#\2#'
}

# ─── Issue validation ──────────────────────────────────────────────────────
# validate_issue <number> → returns 0 if issue exists and is accessible.
# Prints issue title on success, error on stderr on failure.
validate_issue() {
    local num="$1"
    local title
    if ! title=$(gh issue view "$num" --json title --jq .title 2>&1); then
        echo "issue_helpers: issue #$num not found or inaccessible: $title" >&2
        return 1
    fi
    printf '%s' "$title"
}

# ─── Issue context dump (for Claude session) ───────────────────────────────
# dump_issue_context <number> — prints title, body, and comments to stdout
# in a format Claude consumes directly as part of the command output.
dump_issue_context() {
    local num="$1"
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo " ISSUE #$num"
    echo "════════════════════════════════════════════════════════════════"
    gh issue view "$num" --json number,title,state,labels,author,body,comments \
        --template '
{{- "Title: " -}}{{ .title }}
{{ "State: " -}}{{ .state -}} | Author: {{ .author.login -}} | Labels: {{ range .labels }}{{ .name }} {{ end -}}

── Body ────────────────────────────────────────────────────────
{{ .body }}
{{ if .comments }}
── Comments ({{ len .comments }}) ─────────────────────────────────
{{ range .comments -}}
{{ .author.login -}}  ({{ .createdAt -}})
{{ .body }}
────────────────────────────────────────────────────────────────
{{ end -}}
{{ end -}}
'
}

# ─── Slug from issue title (for branch name) ───────────────────────────────
# slug_from_issue <number> [type] — echoes "<type>/<slug>" where type defaults
# to "feat" and slug is derived from the issue title (lowercased, non-alnum
# to -, truncated to 40 chars). Issue # is NOT prefixed: a branch may close
# multiple issues and embedding one number is misleading. Issue↔branch link
# lives in git config; collisions resolved by work.sh (resolve_collision).
slug_from_issue() {
    local num="$1"
    local type="${2:-feat}"
    local title
    title=$(gh issue view "$num" --json title --jq .title 2>/dev/null)
    [ -z "$title" ] && title="issue-$num"

    local slug
    slug=$(printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-40 \
        | sed -E 's/-+$//')
    [ -z "$slug" ] && slug="changes"

    echo "${type}/${slug}"
}

# ─── Branch ↔ issue link storage (git config) ──────────────────────────────
# link_issue_to_branch <issue_num> [branch_name]
# Stores in git config: branch.<name>.gitflow-issues = "23 25 26" (space-sep).
# Idempotent: re-linking the same issue is a no-op.
link_issue_to_branch() {
    local num="$1"
    local branch="${2:-$(git branch --show-current)}"
    local key="branch.${branch}.gitflow-issues"
    local current
    current=$(git config --local --get "$key" 2>/dev/null || echo "")

    # Check if already linked (idempotent).
    for existing in $current; do
        if [ "$existing" = "$num" ]; then
            return 0
        fi
    done

    local new_list
    if [ -z "$current" ]; then
        new_list="$num"
    else
        new_list="$current $num"
    fi
    git config --local "$key" "$new_list"
}

# read_branch_linked_issues [branch_name] — echoes space-separated issue numbers.
read_branch_linked_issues() {
    local branch="${1:-$(git branch --show-current)}"
    git config --local --get "branch.${branch}.gitflow-issues" 2>/dev/null || echo ""
}

# clear_branch_linked_issues [branch_name] — drops the link list AND the
# complete list for a branch. Called once the links have been consumed (carried
# onto a new branch), so the same issue cannot be re-attached to unrelated
# later work.
clear_branch_linked_issues() {
    local branch="${1:-$(git branch --show-current)}"
    git config --local --unset-all "branch.${branch}.gitflow-issues" 2>/dev/null || true
    git config --local --unset-all "branch.${branch}.gitflow-complete" 2>/dev/null || true
    git config --local --unset-all "branch.${branch}.gitflow-noted" 2>/dev/null || true
}

# ─── Code-complete state (git config) ──────────────────────────────────────
# read_branch_complete_issues [branch_name] — echoes the issues marked complete.
read_branch_complete_issues() {
    local branch="${1:-$(git branch --show-current)}"
    git config --local --get "branch.${branch}.gitflow-complete" 2>/dev/null || echo ""
}

# read_branch_incomplete_issues [branch_name] — linked issues NOT yet marked
# complete, in link order. This is what /commit and /ship-main ask about and
# what /open-pr gates on.
read_branch_incomplete_issues() {
    local branch="${1:-$(git branch --show-current)}"
    local linked complete out="" num c hit
    linked=$(read_branch_linked_issues "$branch")
    complete=$(read_branch_complete_issues "$branch")
    for num in $linked; do
        hit=0
        for c in $complete; do [ "$c" = "$num" ] && hit=1; done
        if [ "$hit" -eq 0 ]; then out="${out:+$out }$num"; fi
    done
    echo "$out"
}

# mark_issue_complete <issue_num> [branch_name] — idempotent. Refuses (return 1)
# an issue that is not linked on the branch: "complete" means complete work on
# THIS body of work, and a typo'd number must not reach the board.
mark_issue_complete() {
    local num="$1"
    local branch="${2:-$(git branch --show-current)}"
    local linked hit=0 n
    linked=$(read_branch_linked_issues "$branch")
    for n in $linked; do [ "$n" = "$num" ] && hit=1; done
    if [ "$hit" -eq 0 ]; then
        echo "issue_helpers: #$num is not linked on '$branch' — link it with /work $num first." >&2
        return 1
    fi
    local key="branch.${branch}.gitflow-complete" current
    current=$(read_branch_complete_issues "$branch")
    for n in $current; do [ "$n" = "$num" ] && return 0; done
    git config --local "$key" "${current:+$current }$num"
}

# validate_complete_issues "<space-separated nums>" [branch_name] — return 1,
# naming each offender, when any number is not linked on the branch. Scripts
# call this BEFORE they commit or push, so a bad --complete fails with nothing
# half-done.
validate_complete_issues() {
    local nums="$1"
    local branch="${2:-$(git branch --show-current)}"
    local linked bad="" num n hit
    linked=$(read_branch_linked_issues "$branch")
    for num in $nums; do
        hit=0
        for n in $linked; do [ "$n" = "$num" ] && hit=1; done
        if [ "$hit" -eq 0 ]; then bad="${bad:+$bad }$num"; fi
    done
    if [ -n "$bad" ]; then
        echo "issue_helpers: not linked on '$branch': $(format_issue_refs "$bad"). Linked: $(format_issue_refs "$linked")" >&2
        return 1
    fi
}

# unlink_issues_from_branch "<space-separated nums>" [branch_name] — removes
# those issues from both lists and leaves the rest. /ship-main consumes only the
# issues it closed; an incomplete issue stays parked for later work.
unlink_issues_from_branch() {
    local nums="$1"
    local branch="${2:-$(git branch --show-current)}"
    local kind list keep num n drop
    for kind in gitflow-issues gitflow-complete gitflow-noted; do
        list=$(git config --local --get "branch.${branch}.${kind}" 2>/dev/null || echo "")
        keep=""
        for n in $list; do
            drop=0
            for num in $nums; do [ "$n" = "$num" ] && drop=1; done
            if [ "$drop" -eq 0 ]; then keep="${keep:+$keep }$n"; fi
        done
        if [ -n "$keep" ]; then
            git config --local "branch.${branch}.${kind}" "$keep"
        else
            git config --local --unset-all "branch.${branch}.${kind}" 2>/dev/null || true
        fi
    done
}

# migrate_branch_linked_issues <from_branch> <to_branch>
# Carries issue links, and which of them are complete, across a branch creation
# and clears the source.
#
# /work <issue#> no longer cuts a branch — it parks the link on whatever
# branch the session is standing on, normally main. The branch is cut later
# by whichever command declares the path, and that command calls this to
# bring the links along.
migrate_branch_linked_issues() {
    local from="$1" to="$2"
    [ "$from" = "$to" ] && return 0

    local list complete noted
    list=$(read_branch_linked_issues "$from")
    [ -z "$list" ] && return 0
    complete=$(read_branch_complete_issues "$from")
    noted=$(read_branch_noted_issues "$from")

    local num
    for num in $list; do
        link_issue_to_branch "$num" "$to"
    done
    for num in $complete; do
        mark_issue_complete "$num" "$to"
    done
    for num in $noted; do
        mark_issue_noted "$num" "$to"
    done
    clear_branch_linked_issues "$from"
    echo "gitflow: carried issue link(s) $(format_issue_refs "$list") from $from onto $to." >&2
}

# stage_complete_issues "<space-separated nums>" [branch_name]
# Marks each issue complete on the branch, then moves each to Staged on the
# board. Called only AFTER the commit or PR it belongs to has landed, so a
# failure here never strands half a commit. The local mark is written first:
# a board failure (almost always the `project` scope) leaves the issue complete
# locally, and /open-pr sets every linked issue to Staged again, so the board
# catches up at the latest there.
stage_complete_issues() {
    local nums="$1"
    local branch="${2:-$(git branch --show-current)}"
    local num
    for num in $nums; do
        mark_issue_complete "$num" "$branch" || return 1
    done
    for num in $nums; do
        if ! move_issue_to_staged "$num"; then
            echo "issue_helpers: #$num is marked code complete, but its board status was not updated (see above)." >&2
            return 1
        fi
    done
}

# ─── The Staged comment (git config + the issue itself) ─────────────────────
# When an issue reaches Staged it gets ONE comment for its author: what was
# built, what they will see, and where it differs from what they asked
# (references/staged-comment.md). Claude writes it; the scripts refuse to stage
# an issue without it and post it once the board has moved. `gitflow-noted`
# records which issues have had theirs, so /open-pr re-staging an issue /commit
# already staged never posts a second one.

# read_branch_noted_issues [branch_name] — issues whose comment has been posted.
read_branch_noted_issues() {
    local branch="${1:-$(git branch --show-current)}"
    git config --local --get "branch.${branch}.gitflow-noted" 2>/dev/null || echo ""
}

# mark_issue_noted <issue_num> [branch_name] — idempotent.
mark_issue_noted() {
    local num="$1"
    local branch="${2:-$(git branch --show-current)}"
    local current n
    current=$(read_branch_noted_issues "$branch")
    for n in $current; do [ "$n" = "$num" ] && return 0; done
    git config --local "branch.${branch}.gitflow-noted" "${current:+$current }$num"
}

# issues_needing_notes "<space-separated nums>" [branch_name] — those not yet
# commented on, in the order given.
issues_needing_notes() {
    local nums="$1"
    local branch="${2:-$(git branch --show-current)}"
    local noted out="" num n hit
    noted=$(read_branch_noted_issues "$branch")
    for num in $nums; do
        hit=0
        for n in $noted; do [ "$n" = "$num" ] && hit=1; done
        if [ "$hit" -eq 0 ]; then out="${out:+$out }$num"; fi
    done
    echo "$out"
}

# require_staged_notes "<space-separated nums>" <notes_dir> [branch_name] —
# return 1, naming each missing file, unless every issue still needing its
# comment has a non-empty <notes_dir>/<N>.md. Scripts call this BEFORE they
# commit or push, so a refusal leaves nothing half-done.
require_staged_notes() {
    local nums="$1" dir="$2"
    local branch="${3:-$(git branch --show-current)}"
    local need missing="" num
    need=$(issues_needing_notes "$nums" "$branch")
    [ -z "$need" ] && return 0
    for num in $need; do
        if [ -z "$dir" ] || [ ! -s "$dir/$num.md" ]; then missing="${missing:+$missing }$num"; fi
    done
    if [ -n "$missing" ]; then
        echo "issue_helpers: no Staged comment for $(format_issue_refs "$missing")." >&2
        echo "  Write <notes_dir>/<N>.md per references/staged-comment.md and pass --notes <notes_dir>." >&2
        return 1
    fi
}

# post_staged_notes "<space-separated nums>" <notes_dir> [branch_name] — posts
# each issue's comment and records it. Called only AFTER the board has moved;
# returns 1 at the first failure, leaving the rest unposted and unrecorded so a
# retry posts exactly what is missing.
post_staged_notes() {
    local nums="$1" dir="$2"
    local branch="${3:-$(git branch --show-current)}"
    local need num slug
    need=$(issues_needing_notes "$nums" "$branch")
    [ -z "$need" ] && return 0
    slug=$(gitflow_repo_slug)
    for num in $need; do
        if ! gh issue comment "$num" -R "$slug" --body-file "$dir/$num.md" >/dev/null; then
            echo "issue_helpers: the Staged comment on #$num did not post (see above)." >&2
            echo "  Post it with: gh issue comment $num -R $slug --body-file $dir/$num.md" >&2
            return 1
        fi
        mark_issue_noted "$num" "$branch"
    done
    echo "gitflow: Staged comment posted on $(format_issue_refs "$need")." >&2
}

# format_issue_refs <space-separated nums> — "#1, #2, #3". Empty in, empty out.
format_issue_refs() {
    local out="" num
    for num in $1; do
        if [ -z "$out" ]; then out="#${num}"; else out="${out}, #${num}"; fi
    done
    echo "$out"
}

# report_parked_issue_links [branch_name]
# Surfaces links sitting on a protected branch at session-init. A link parks
# there when /work <issue#> runs and the session then ends without a commit;
# left silent, the next unrelated /ship-main would close an issue nobody meant
# to close. Reporting is the whole mitigation — the human decides.
report_parked_issue_links() {
    local branch="${1:-$(git branch --show-current)}"
    local list
    list=$(read_branch_linked_issues "$branch")
    [ -z "$list" ] && return 0
    echo "gitflow: issue(s) $(format_issue_refs "$list") are linked on '$branch' from an earlier session." >&2
    echo "  They ride onto the next /commit branch, or /ship-main closes the ones you mark complete." >&2
    echo "  Not yours? git config --local --unset branch.${branch}.gitflow-issues" >&2
}

# closes_line_for_issues <space-separated nums> — "Closes #1, #2". Empty in,
# empty out. GitHub reads this keyword in a PR body (on merge) and in a commit
# pushed to the default branch (on push), and closes the issue unless the
# repository's "Auto-close issues with merged linked pull requests" setting is
# off — which covers both paths. /deploy reads the same line to find what
# shipped, so it is written whether or not anything closes.
closes_line_for_issues() {
    local refs
    refs=$(format_issue_refs "$1")
    [ -z "$refs" ] && return 0
    echo "Closes ${refs}"
}

# ─── Project status transition ─────────────────────────────────────────────
# _move_issue_to_status <issue_num> <option_id_var_name> <label>
# Internal helper. <option_id_var_name> is the NAME of the env var holding
# the GraphQL option ID for the target status (e.g. GITFLOW_STATUS_STAGED_ID).
# Resolved indirectly so the wrappers stay one-liners.
#
# Failure semantics (zero-tolerance fail-loud-when-configured):
#   - GITFLOW_PROJECT_ID empty → silent skip, return 0 (feature off).
#   - GITFLOW_PROJECT_ID set + GITFLOW_STATUS_FIELD_ID empty → ERROR + return 1.
#   - GITFLOW_PROJECT_ID set + the requested status option ID empty → ERROR + return 1
#     (this status isn't configured for this project — populate
#     `.claude/sync-substitutions.json` or skip the call).
#   - Issue not found on configured project → ERROR + return 1.
#   - GraphQL mutation fails → ERROR + return 1 (almost always missing
#     `project` scope on gh auth; remediation message says so).
_move_issue_to_status() {
    local num="$1"
    local option_id_var="$2"
    local label="$3"
    load_gitflow_project_config

    # Feature-off path: PROJECT_ID empty = consumer didn't opt in.
    if [ -z "${GITFLOW_PROJECT_ID:-}" ]; then
        return 0
    fi

    # Configured-but-broken: PROJECT_ID set, FIELD_ID missing.
    if [ -z "${GITFLOW_STATUS_FIELD_ID:-}" ]; then
        echo "issue_helpers: ERROR — GITFLOW_PROJECT_ID is set but GITFLOW_STATUS_FIELD_ID is empty in .claude/gitflow-project.conf." >&2
        echo "  Fix: populate GITFLOW_STATUS_FIELD_ID in .claude/sync-substitutions.json, re-run /sync-dev-kit --finalize, retry." >&2
        echo "  Discover the field ID with the gh api graphql query in .claude/gitflow-project.conf header." >&2
        return 1
    fi

    # Configured-but-broken: PROJECT_ID set, target option ID empty.
    local option_id="${!option_id_var:-}"
    if [ -z "$option_id" ]; then
        echo "issue_helpers: ERROR — GITFLOW_PROJECT_ID is set but $option_id_var is empty." >&2
        echo "  This status ('$label') isn't configured for this project. Fix one of:" >&2
        echo "    - Populate $option_id_var in .claude/sync-substitutions.json (re-run /sync-dev-kit --finalize)." >&2
        echo "    - If this project's board doesn't have a '$label' column, add $option_id_var to _intentionally_empty in .claude/sync-substitutions.json." >&2
        return 1
    fi

    local repo_slug owner repo
    repo_slug=$(gitflow_repo_slug)
    owner="${repo_slug%/*}"
    repo="${repo_slug#*/}"

    # Find the project item ID for this issue on our configured project.
    local item_id graphql_out
    if ! graphql_out=$(gh api graphql -f query="
        query(\$owner: String!, \$repo: String!, \$num: Int!) {
            repository(owner: \$owner, name: \$repo) {
                issue(number: \$num) {
                    projectItems(first: 20) {
                        nodes { id project { id } }
                    }
                }
            }
        }" \
        -f owner="$owner" -f repo="$repo" -F num="$num" 2>&1); then
        echo "issue_helpers: ERROR — GraphQL lookup failed for issue #$num: $graphql_out" >&2
        echo "  Most likely cause: gh token missing 'project' scope. Fix: gh auth refresh -s project, retry." >&2
        return 1
    fi
    item_id=$(printf '%s' "$graphql_out" \
        | jq -r --arg pid "$GITFLOW_PROJECT_ID" \
            '.data.repository.issue.projectItems.nodes[]? | select(.project.id == $pid) | .id' \
        | head -1)

    if [ -z "$item_id" ]; then
        echo "issue_helpers: ERROR — issue #$num is not on the configured project (PROJECT_ID=$GITFLOW_PROJECT_ID)." >&2
        echo "  Fix one of:" >&2
        echo "    - Enable the project's 'Auto-add to project' workflow (Settings → Workflows → Auto-add to project)." >&2
        echo "    - Manually add issue #$num to the project, then retry." >&2
        echo "    - Verify GITFLOW_PROJECT_ID in .claude/sync-substitutions.json matches the project this repo's issues live on." >&2
        return 1
    fi

    # Update the Status field to the requested option.
    local mutation_out
    if ! mutation_out=$(gh api graphql -f query="
        mutation(\$pid: ID!, \$iid: ID!, \$fid: ID!, \$oid: String!) {
            updateProjectV2ItemFieldValue(input: {
                projectId: \$pid
                itemId: \$iid
                fieldId: \$fid
                value: { singleSelectOptionId: \$oid }
            }) { projectV2Item { id } }
        }" \
        -f pid="$GITFLOW_PROJECT_ID" \
        -f iid="$item_id" \
        -f fid="$GITFLOW_STATUS_FIELD_ID" \
        -f oid="$option_id" 2>&1); then
        echo "issue_helpers: ERROR — failed to update project status for #$num to '$label': $mutation_out" >&2
        echo "  Most likely cause: gh token missing 'project' scope. Fix: gh auth refresh -s project, retry." >&2
        echo "  Less common: the option ID ($option_id_var=$option_id) doesn't belong to GITFLOW_STATUS_FIELD_ID — re-run discovery and update .claude/sync-substitutions.json." >&2
        return 1
    fi

    echo "issue_helpers: moved #$num to $label on the project" >&2
}

# Public wrappers. Signature stays single-arg so call sites don't drift.
move_issue_to_in_progress() { _move_issue_to_status "$1" GITFLOW_STATUS_IN_PROGRESS_ID "In Progress"; }
move_issue_to_staged()      { _move_issue_to_status "$1" GITFLOW_STATUS_STAGED_ID      "Staged"; }
move_issue_to_deployed()    { _move_issue_to_status "$1" GITFLOW_STATUS_DEPLOYED_ID    "the deploy status"; }

# ─── Assign current user ───────────────────────────────────────────────────
# assign_issue_to_current_user <issue_num>
# Fail-loud: assignment isn't gated on project-board config (it's a plain
# `gh issue edit`), so the only failure modes are gh auth missing or the
# `gh` CLI itself broken. Either is a user-visible problem worth surfacing.
assign_issue_to_current_user() {
    local num="$1"
    local login
    if ! login=$(gh api user --jq .login 2>&1); then
        echo "issue_helpers: ERROR — could not determine current user for assignment of #$num: $login" >&2
        echo "  Fix: gh auth login (or gh auth status to inspect current credential), retry." >&2
        return 1
    fi
    if [ -z "$login" ]; then
        echo "issue_helpers: ERROR — gh api user returned empty login for assignment of #$num." >&2
        echo "  Fix: gh auth status, gh auth login, retry." >&2
        return 1
    fi

    local edit_out
    if ! edit_out=$(gh issue edit "$num" --add-assignee "$login" 2>&1); then
        echo "issue_helpers: ERROR — failed to assign #$num to $login: $edit_out" >&2
        echo "  Fix: confirm gh token has 'repo' scope (gh auth refresh -s repo) and the repo allows assigning the current user, retry." >&2
        return 1
    fi

    echo "issue_helpers: assigned #$num to $login" >&2
}
