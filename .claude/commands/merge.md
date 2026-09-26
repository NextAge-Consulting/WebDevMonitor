# /merge

Squash-merge the current branch's PR after CI passes. Part of the gitflow subsystem. Invoked directly (`/merge`) or via natural-language triggers ("merge", "merge to main", "ship it", "land this").

$ARGUMENTS

## Procedure

### Step 1: Identify the target PR

If `$ARGUMENTS` contains a PR number (e.g., `/merge 42`), use that. Otherwise let the script auto-detect from the current branch.

### Step 2: Invoke the script

```bash
.claude/skills/gitflow/scripts/merge.sh [--pr <number>]
```

The script:
- Finds the open PR for the current branch (or uses --pr)
- Checks the PR against its base FIRST (exit 23): when `origin/main` has moved, a trial
  merge (`git merge-tree`) decides — a conflict refuses before any build or wait, and drift
  that merges cleanly is reported and the merge goes ahead.
- Runs a **local production build gate** — `npm run build --workspaces --if-present` —
  before the readiness wait and before the squash. CI does not build (it type-checks,
  lints and tests), so a build-only break is invisible until here. This is the last
  moment the PR is still OPEN, so a failure is fixed on the branch that caused it rather
  than in a follow-up PR repairing the first. Not in CI on purpose: CI fires on every
  push, and building there would tax every commit, `/open-pr` and triage fix.
- Invokes `wait-for-pr-ready.sh` which is **trigger-aware**: blocks until CI required checks pass AND — if a `/gemini review` comment was posted for the current HEAD — Gemini Code Assist has posted its review. If no trigger comment exists for the current HEAD (e.g. last `/commit` was `--no-review`), proceeds on CI-only. `GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json` short-circuits the entire Gemini path. Polls every 30s, times out fail-loud after 15min.
- Squash-merges via `gh pr merge --squash` with the PR's own title and body as the commit message, whatever the repository's squash setting — the body carries the `Closes #N` line `/deploy` reads to move shipped issues — then deletes the remote branch as a separate best-effort step
- Switches this checkout to `main` and fast-forwards it to the merged tip
- Deletes the now-merged local branch
- Reinstalls dependencies if landing on the new `main` changed a package manifest

### Step 3: Report

- Merge succeeded: report the PR number and the commit SHA on main
- Multiple PRs on branch: script lists them and exits; ask user which one (then re-invoke with `--pr <number>`)
- Conflicts with its base (exit 23): the conflicting files are listed and nothing merged —
  run `/catchup`, resolve, then `/merge` again
- Production build failed (exit 15): surface the build error; nothing merged and the PR
  is still open, so the fix goes on this branch and into this PR
- CI checks failing: surface which check failed, link to PR checks page
- Readiness wait timeout (Gemini queued / rate-limited despite a posted trigger): surface the diagnostic message; user decides whether to opt this repo out of Gemini gating (`GEMINI_NOT_INSTALLED="true"` — only correct if Gemini is genuinely absent), extend timeout, or `--force-unchecked` for emergency. The "no triggers fired, ship on CI alone" case happens automatically — `/commit --no-review` is the user's explicit signal that `/merge` should not wait for Gemini.
- Merge conflict: rare with squash but possible; surface the conflict and stop

### Step 4: Note post-merge state

After `/merge` completes, the squash commit is on main and this checkout is standing on it — the next `/work` cuts a fresh branch from here. **No deploy fires automatically.** To ship to production, run `/deploy` (which bumps version, writes changelog, pushes, triggers the deploy workflow). Multiple merges can accumulate on main between deploys — `/deploy` ships all commits since the last release tag in one bump.

## What this command does NOT do

- Does not create the next working branch — `/work` does that when you start the next body of work
- Does not bump version — `/deploy` does this
- Does not create a tag — same
- Does not deploy to production — `/deploy` does this
- Does not regenerate the changelog — `/deploy` does this

## Blocking conditions

- Current branch is already `main`: nothing to merge
- No open PR for current branch: run `/open-pr` first
- CI has failing required checks: fix and push before merging
- `gh` CLI not available: squash-merge-via-API is not implemented in `merge.sh`; install gh or run the merge manually via GitHub web UI
- The PR's title or body cannot be read: exit 22, nothing merged
- The branch conflicts with its base: exit 23, nothing merged — `/catchup` first

## Emergency bypass

`--force-unchecked` flag on the script bypasses the CI gate. Use ONLY for hotfixes with explicit user authorization. Never use in automated flows.
