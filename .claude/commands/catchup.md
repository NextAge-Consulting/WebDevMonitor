# /catchup

Refresh local code from origin. **Behavior depends on which branch is checked out** at invocation:

- **On main (between bodies of work, or just reviewing):** fetch + fast-forward local `main` from `origin/main`. Fail-loud on dirty / diverged main.
- **On a feature branch:** merge `origin/main` (or `--base <other>`) INTO the feature branch via an explicit merge commit (`--no-ff`).

One command, one mental model: "catch the branch I'm on up to date with origin." If that branch is main, fast-forward it. If it's a feature branch, merge main into it.

$ARGUMENTS

## When to invoke

**On main:**
- Starting a session after another developer has merged + deployed; you want your local repo current before reviewing or before /work cuts a new branch.
- Reviewing someone else's just-merged work without touching any feature branch.

**On a feature branch:**
- `/work`, `/commit` or `/open-pr` reported `main has moved` with files changed on both sides.
- `/merge` refused with exit 23.
- `gh pr view <N>` reports `mergeStateStatus: DIRTY` / `mergeable: CONFLICTING` after another PR merged.
- You know `main` has changed in a way that affects your branch (changelog overlap, file touched by both PRs, schema migration).
- Before opening a PR on a long-lived branch that has lagged main by more than a couple of merges.

Do NOT invoke when:
- A PR you've opened is already mergeable AND your branch is the only one that touched its files.
- You want to rebase (`/catchup` is merge-based by design — see "Why merge, not rebase" below).

## Supported invocations

| Input | Branch | What happens |
|-------|--------|--------------|
| `/catchup` | main | Fetch `origin/main`, refuse on dirty or diverged main, fast-forward local main. Report old → new SHA + commit count pulled. |
| `/catchup` | feature branch | Fetch `origin/main`. If HEAD already contains it, no-op. Otherwise merge `origin/main` into the current branch with an explicit merge commit (`--no-ff`) and push via `safe_push`. |
| `/catchup --base <branch>` | feature branch | Same as above but `origin/<branch>`. Rare. (Ignored on main.) |
| `/catchup --continue` | feature branch | After manual conflict resolution: stage all, complete the merge commit (default message), push. |
| `/catchup --abort` | feature branch | Abandon an in-progress merge; restore the tree to its pre-merge state. |

`--continue` / `--abort` are feature-branch-only because the on-main path is a fast-forward (no merge commit, no conflicts possible).

## Procedure

### Step 1: Pre-flight

Confirm no merge is already in progress (`--continue` / `--abort` cover that case). On feature branches the tree must be clean; on main the tree must be clean too — a fast-forward over uncommitted edits would fail or strand them; `/checkpoint` first.

### Step 2: Invoke the script

```bash
.claude/skills/gitflow/scripts/catchup.sh
```

### Step 3: If conflicts

The script exits non-zero (code 6) and lists conflicting paths. Resolve each file using `Edit`:

1. Open the file. Locate the `<<<<<<<`, `=======`, `>>>>>>>` markers.
2. Decide which side to keep, or write a manual merge. For changelog overlap, the typical resolution is: keep both entries, ordered by merge time (newer above older).
3. Repeat for each conflicting file.
4. Verify nothing was missed: `git diff --check` should exit clean.

### Step 4: Continue

```bash
.claude/skills/gitflow/scripts/catchup.sh --continue
```

Commits the merge with git's default message and pushes.

### Step 5: Verify

`gh pr view <N>` should now report `mergeable: MERGEABLE`. `/merge` can proceed.

## Why merge, not rebase

`/catchup` uses `git merge`, not `git rebase`. Rationale:

- **No force-push.** Rebase rewrites history and requires `--force-with-lease`. Force-push is a class of operation we keep behind explicit authorization, not automatable.
- **Squash-merge at PR ship time.** When `/merge` squashes the PR, the entire branch (including the catchup merge commit) collapses into one commit on main. The intermediate merge structure doesn't pollute main's history.
- **Cleaner conflict resolution surface.** A single 3-way merge produces one conflict pass; a rebase replays N commits and can surface the same conflict N times.

If you genuinely need a rebase (e.g. linearizing history before opening a PR), do it manually with `SKIP_GIT_GUARD=1 git rebase origin/main` — that's the rare-case escape hatch, not a primitive.

## Blocking conditions

| Exit code | Reason |
|---|---|
| 2 | Bad arguments. |
| 3 | Not in a git working tree / on detached HEAD. |
| 4 | Mode conflict (e.g. `--continue` without MERGE_HEAD; default mode with MERGE_HEAD already present). |
| 5 | Dirty tree (default mode) or conflict markers still present (continue mode). |
| 6 | Conflicts during merge, `git fetch` failed, or `git merge` failed. |
| 7 | (Main path only) Local main has diverged from origin/main — has local-only commits. Anomalous under gitflow; inspect `git log origin/main..HEAD`. |

## What this command does NOT do

- Does not rebase. Use `SKIP_GIT_GUARD=1 git rebase` manually if you need it.
- Does not run typecheck. The merge commit is mechanical; subsequent commits to fix any issues go through `/commit`.
- Does not open a PR. Use `/open-pr` after the branch is current.
- Does not merge the PR to main. That's `/merge`.

## Cross-reference

- handbook §4.6 (catchup workflow) — full design walkthrough.
- gitflow-cheatsheet — troubleshooting entry for "PR mergeable=CONFLICTING".
- `.claude/rules/git.md` — git operation policy.
