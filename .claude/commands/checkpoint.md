# /checkpoint

A local save point, without deep analysis. Part of the gitflow subsystem. A checkpoint is a commit on the branch you are standing on — `main` included — that cuts no branch and pushes nothing. Its real user is an autonomous session diffing its own stages.

$ARGUMENTS

## Procedure

### Step 1: Invoke the script

Pass the user's optional message suffix (from `$ARGUMENTS`) as positional arguments. The script auto-formats as `🔖 wip: <timestamp> [- suffix]`.

```bash
.claude/skills/gitflow/scripts/checkpoint.sh [optional suffix text]
```

### Step 2: Report

- Checkpoint saved: report the timestamp and the branch, and that it is local only
- Nothing to checkpoint: report
- Script exited non-zero: surface exit code and message

## Checkpoints never reach origin

`/commit` and `/ship-main` fold every unpushed checkpoint into the one real commit they make: they soft-reset to the commit the checkpoints sit on and commit once, after every gate has passed. So a `🔖 wip:` subject never lands on `main`, where `/deploy` reads subjects to compute the version bump.

On `main`, a `/commit` moves the checkpoints onto the branch it cuts and resets local `main` to where they started. Until one of the two runs, local `main` is ahead of `origin/main`, so `/catchup` refuses to fast-forward and `/deploy` refuses to start — each says why.

A checkpoint that was already pushed is never folded; rewriting it would need a force-push.

## What this command skips

- Typecheck, lint and semgrep — the real commit runs them over the folded content
- Changelog — checkpoints never appear in the changelog
- Version bump — only main branch merges trigger bumps
- The code-complete question — a checkpoint is partway by definition; issue links stay on the branch until `/commit` or `/ship-main` carries them

## Blocking conditions

- Detached HEAD
- Nothing to checkpoint (empty diff)
