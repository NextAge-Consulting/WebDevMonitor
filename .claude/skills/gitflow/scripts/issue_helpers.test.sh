#!/usr/bin/env bash
# Regression suite for the branch↔issue link storage in issue_helpers.sh.
#
# These functions decide which issues a commit names as closed, which are code
# complete, and which /open-pr refuses to open over,
# so a silent regression here either strands an issue open or closes one nobody
# meant to touch. Everything below runs against a real throwaway git repo rather
# than a mock, because the storage IS git config — a mock would only assert that
# the mock works.
#
# The gh-dependent helpers (validate_issue, dump_issue_context, the project-board
# transitions) are deliberately not covered: they are thin wrappers over `gh`
# whose failure modes are network and auth, not logic.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/issue_helpers.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

git init -q -b main "$tmp/repo"
cd "$tmp/repo" || exit 1
git config user.email t@example.com
git config user.name Tester

# shellcheck source=./issue_helpers.sh
source "$S"

t(){ # t <want> <got> <label>
  if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got '$2', want '$1') — $3"; fail=1; fi; }

echo "parse_issue_csv:"
t "27 28" "$(parse_issue_csv '#27, #28')" 'commas, spaces and # all accepted'
# No numbers at all must come back empty and SUCCEED: work.sh captures this under
# set -e, and a failing parse ended the script before it could explain the bad value.
out=$(set -e; parse_issue_csv 'abc'; echo rc=$?)
t "rc=0" "$out" 'no numbers: empty and exit 0'
out=$(set -e; parse_issue_csv ''; echo rc=$?)
t "rc=0" "$out" 'empty value: empty and exit 0'

echo "link storage:"
link_issue_to_branch 7 main
link_issue_to_branch 9 main
t "7 9" "$(read_branch_linked_issues main)" 'links accumulate in order'
link_issue_to_branch 7 main
t "7 9" "$(read_branch_linked_issues main)" 're-linking the same issue is idempotent'
t "" "$(read_branch_linked_issues never-used)" 'unknown branch reads empty'

echo "formatting:"
t "#7, #9" "$(format_issue_refs "$(read_branch_linked_issues main)")" 'refs render comma-separated'
t "Closes #7, #9" "$(closes_line_for_issues "$(read_branch_linked_issues main)")" 'closes line'
t "" "$(closes_line_for_issues "")" 'empty in, empty out — must not emit a bare "Closes"'
t "" "$(format_issue_refs "")" 'empty refs'

echo "migration across a branch creation:"
migrate_branch_linked_issues main feat/thing 2>/dev/null
t "7 9" "$(read_branch_linked_issues feat/thing)" 'links land on the new branch'
t "" "$(read_branch_linked_issues main)" 'source is CLEARED — a stale link must not re-close later'
migrate_branch_linked_issues main feat/thing 2>/dev/null
t "7 9" "$(read_branch_linked_issues feat/thing)" 'migrating an empty source is a no-op'
migrate_branch_linked_issues feat/thing feat/thing 2>/dev/null
t "7 9" "$(read_branch_linked_issues feat/thing)" 'migrating onto itself does not self-destruct'

echo "clearing:"
clear_branch_linked_issues feat/thing
t "" "$(read_branch_linked_issues feat/thing)" 'clear empties the list'
clear_branch_linked_issues feat/thing
t "" "$(read_branch_linked_issues feat/thing)" 'clearing twice is safe'

echo "code complete:"
link_issue_to_branch 3 feat/cc
link_issue_to_branch 5 feat/cc
link_issue_to_branch 8 feat/cc
t "3 5 8" "$(read_branch_incomplete_issues feat/cc)" 'nothing marked: every linked issue is incomplete'
mark_issue_complete 5 feat/cc
t "5" "$(read_branch_complete_issues feat/cc)" 'marking records the issue'
t "3 8" "$(read_branch_incomplete_issues feat/cc)" 'incomplete excludes it, in link order'
mark_issue_complete 5 feat/cc
t "5" "$(read_branch_complete_issues feat/cc)" 'marking twice is idempotent'
if mark_issue_complete 99 feat/cc 2>/dev/null; then r=accepted; else r=refused; fi
t refused "$r" 'an unlinked issue cannot be marked'
t "5" "$(read_branch_complete_issues feat/cc)" 'a refused mark writes nothing'
if validate_complete_issues "3 8" feat/cc; then r=ok; else r=bad; fi
t ok "$r" 'linked numbers validate'
if out=$(validate_complete_issues "3 42" feat/cc 2>&1); then r=accepted; else r=refused; fi
t refused "$r" 'an unlinked number fails validation'
case "$out" in *"#42"*) t ok ok 'validation names the offender';; *) t ok "no mention" 'validation names the offender';; esac

echo "migration carries completeness:"
migrate_branch_linked_issues feat/cc feat/cc2 2>/dev/null
t "3 5 8" "$(read_branch_linked_issues feat/cc2)" 'links move'
t "5" "$(read_branch_complete_issues feat/cc2)" 'complete marks move with them'
t "" "$(read_branch_complete_issues feat/cc)" 'source complete list is cleared'

echo "unlinking only what was consumed:"
mark_issue_complete 8 feat/cc2
unlink_issues_from_branch "5 8" feat/cc2
t "3" "$(read_branch_linked_issues feat/cc2)" 'the closed issues leave, the incomplete one stays parked'
t "" "$(read_branch_complete_issues feat/cc2)" 'their complete marks leave with them'
unlink_issues_from_branch "3" feat/cc2
t "" "$(read_branch_linked_issues feat/cc2)" 'unlinking the last issue empties the list'

echo "set -e safety:"
# ship-main.sh runs under `set -e`. A helper returning non-zero on the empty
# path would abort the whole script mid-ship, after the commit and before the
# push. Each of these must return 0 with nothing linked.
# shellcheck source=./issue_helpers.sh
if ( set -e; source "$S"; closes_line_for_issues "" >/dev/null; \
  format_issue_refs "" >/dev/null; clear_branch_linked_issues nothing-here; \
  migrate_branch_linked_issues nothing-here also-nothing >/dev/null 2>&1; \
  read_branch_incomplete_issues nothing-here >/dev/null; \
  unlink_issues_from_branch "" nothing-here; validate_complete_issues "" nothing-here; \
  report_parked_issue_links nothing-here 2>/dev/null; \
  issues_needing_notes "" nothing-here >/dev/null; require_staged_notes "" "" nothing-here; \
  post_staged_notes "" "" nothing-here ); then r=ok; else r=aborted; fi
t ok "$r" 'every empty path returns 0 under set -e'

echo "the Staged comment:"
# Every issue reaching Staged gets exactly one comment for its author. These pin
# which issues still need one, the refusal when its file is missing, and that the
# record follows the issue across a branch creation and leaves with it on unlink.
link_issue_to_branch 11 feat/notes
link_issue_to_branch 12 feat/notes
t "11 12" "$(issues_needing_notes "11 12" feat/notes)" 'nothing posted: both need a comment'
mark_issue_noted 11 feat/notes
t "12" "$(issues_needing_notes "11 12" feat/notes)" 'a posted issue needs no second comment'
mark_issue_noted 11 feat/notes
t "11" "$(read_branch_noted_issues feat/notes)" 'recording twice is idempotent'
notes="$tmp/notes"; mkdir -p "$notes"
if require_staged_notes "11 12" "$notes" feat/notes 2>/dev/null; then r=accepted; else r=refused; fi
t refused "$r" 'refuses when an issue still needing its comment has no file'
: > "$notes/12.md"
if require_staged_notes "11 12" "$notes" feat/notes 2>/dev/null; then r=accepted; else r=refused; fi
t refused "$r" 'an empty file is not a comment'
echo "Built." > "$notes/12.md"
if require_staged_notes "11 12" "$notes" feat/notes 2>/dev/null; then r=accepted; else r=refused; fi
t accepted "$r" 'accepts once every issue needing one has its file'
if require_staged_notes "11" "" feat/notes 2>/dev/null; then r=accepted; else r=refused; fi
t accepted "$r" 'no --notes is fine when nothing still needs a comment'
if require_staged_notes "12" "" feat/notes 2>/dev/null; then r=accepted; else r=refused; fi
t refused "$r" 'no --notes is refused when an issue still needs one'
migrate_branch_linked_issues feat/notes feat/notes2 2>/dev/null
t "11" "$(read_branch_noted_issues feat/notes2)" 'the record follows a branch creation'
t "" "$(read_branch_noted_issues feat/notes)" 'and is cleared from the source'
unlink_issues_from_branch "11" feat/notes2
t "" "$(read_branch_noted_issues feat/notes2)" 'unlinking an issue drops its record'

echo "parked-link reporting:"
link_issue_to_branch 42 main
out=$(report_parked_issue_links main 2>&1)
case "$out" in *"#42"*) t ok ok 'names the parked issue';; *) t ok "no mention" 'names the parked issue';; esac
case "$out" in *"--unset branch.main.gitflow-issues"*) t ok ok 'prints the exact command to drop it';; *) t ok "missing" 'prints the exact command to drop it';; esac
clear_branch_linked_issues main
t "" "$(report_parked_issue_links main 2>&1)" 'silent when nothing is parked'

exit "$fail"
