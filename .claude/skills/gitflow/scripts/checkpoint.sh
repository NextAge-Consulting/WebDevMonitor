#!/bin/bash
# gitflow checkpoint: a local save point on the current branch.
# Usage: checkpoint.sh [optional message suffix]
#
# Message format: 🔖 wip: <timestamp> [- suffix]
#
# A checkpoint is a LOCAL commit on whatever branch is checked out, main
# included. It cuts no branch and pushes nothing. Its user is an autonomous
# session diffing its own stages; /commit and /ship-main fold every unpushed
# checkpoint into the one real commit they make (branch_helpers.sh,
# checkpoint_fold_base), so a checkpoint never reaches origin.
#
# Checkpoints skip typecheck and lint: they are folded away before anything
# ships, and the real commit runs every gate over the folded content.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"

TIMESTAMP=$("$SCRIPT_DIR/get_timestamp.sh")

SUFFIX=""
if [ $# -gt 0 ]; then
    SUFFIX=" - $*"
fi

MESSAGE="${CHECKPOINT_PREFIX} ${TIMESTAMP}${SUFFIX}"

CURRENT_BRANCH=$(git branch --show-current)
if [ -z "$CURRENT_BRANCH" ]; then
    echo "checkpoint.sh: detached HEAD — there is no branch to checkpoint on." >&2
    exit 3
fi

git add -A

if git diff --cached --quiet; then
    echo "gitflow: nothing to checkpoint." >&2
    exit 5
fi

echo "gitflow: checkpoint: $MESSAGE" >&2
git commit --no-verify -m "$MESSAGE"

echo "gitflow: checkpoint saved locally on $CURRENT_BRANCH — not pushed; /commit or /ship-main folds it." >&2
