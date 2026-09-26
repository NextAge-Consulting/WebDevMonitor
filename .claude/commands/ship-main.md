# /ship-main

Commit straight to `main` — no branch, no PR, no CI. The **conscious exception** for quick infra / emergency / "just get it in there and get back to clean" work. Part of the gitflow subsystem. Invoked via `/ship-main` or natural-language triggers: "ship to main", "commit straight to main", "commit this directly to main", "infra commit", "emergency commit to main", "quick commit to main".

$ARGUMENTS

## When to use this (and when NOT to)

| Use `/ship-main` | Use `/commit` (the default) |
|---|---|
| Conscious infra / config / emergency change you want on main NOW | Real feature work |
| You accept no PR, no CI, no review — main's history is the trail | You want branch → PR → CI → review → merge |
| You're sitting on dirty `main` and want back to clean | Anything that deserves review |

**This is never inferred.** Being on dirty `main` is often *accidental* — you started editing before `/work`. So a bare `/commit` on `main` still auto-branches — that's the safety. `/ship-main` is the opposite, on purpose, and only when you ask for it by name.

## Procedure

### Step 1: Confirm this is genuinely a direct-to-main change

If there's any doubt it's a deliberate exception (it looks like feature work, or the user said "commit" not "ship to main"), STOP and use `/commit` instead. Direct-to-main skips CI and review — only proceed when the user explicitly wants that.

### Step 2: Compose a conventional commit message

Same rules as `/commit` — `<emoji> <type>(<scope>): <subject>`. **Conventional format is required**, not optional: `/ship-main` commits land on `main` and are read by the next `/deploy` (commit subjects since the last tag) to compute the bump level + changelog, exactly like a merged-PR squash commit. A malformed subject mis-classifies the release.

### Step 3: Ask which linked issues are code complete

Same question as `/commit` Step 6, and it decides more here: only complete issues are
named in this commit's `Closes` line. An incomplete one stays parked on `main` for the work
that finishes it.

```bash
bash -c 'source .claude/skills/gitflow/scripts/issue_helpers.sh && read_branch_incomplete_issues'
```

Empty → no question. Otherwise ask in prose and wait — "Are any of #42, #43 code complete?
Complete ones are named as closed by this commit and move to Staged." Map the answer to
`--complete "<N,N>"`, or pass nothing.

**Then write the Staged comment for each issue reaching Staged** — those already complete
plus the ones just confirmed — that has not had one; the issue's author reviews against it.
List them:

```bash
bash -c 'source .claude/skills/gitflow/scripts/issue_helpers.sh && issues_needing_notes "$(read_branch_complete_issues) <N N>"'
```

Read `.claude/skills/gitflow/references/staged-comment.md` and the issue itself
(`gh issue view <N>`), then write one file per issue, `<notes_dir>/<N>.md`, in a scratch
directory outside the repo (`mktemp -d`). Pass it as `--notes <notes_dir>`. Write it and
move on — never put the wording to the human for approval. The script refuses before
committing (exit 2) when one is missing, and posts each once the board has moved.

### Step 4: Invoke the script

```bash
.claude/skills/gitflow/scripts/ship-main.sh --message "<conventional message>" [--skip-typecheck] [--complete "<N,N>" --notes <notes_dir>]
```

The script:
- Refuses unless on `main`/`master` — a body of work in progress is on its own branch and cannot trip it.
- Runs `check-types`, `biome lint`, and `semgrep` over the files the commit touches — the same gates `/commit` runs, mirroring CI so a failure costs a second here rather than landing on `main`. **`--skip-typecheck` skips the TYPECHECK only.** Biome and semgrep sit outside that guard and always run; there is no flag that bypasses them, which is deliberate on the one path that writes straight to the default branch.
- Stages all changes, commits directly on `main` with `--no-verify` (validation already ran).
- Pushes straight to `main`. If `origin/main` advanced, it rebases the commit onto it and re-pushes; on conflict it stops and tells you to resolve + push.

### Step 5: Report

- Success: confirm the commit is live on `main` (SHA + subject), and which issues it named and moved to Staged. No PR URL — there is none by design.
- `--complete` names an issue not linked on `main`: exit 2, nothing committed.
- Board update failed after the push: exit 11. The commit is live; the next `/deploy` still moves the named issues to the deploy status.
- An issue reaching Staged has no comment in `--notes`: exit 2, nothing committed.
- A Staged comment did not post after the push: exit 13. The commit is live and the board updated; the script prints the exact `gh issue comment` to run.
- Refused (not on main): tell the user they're on `<branch>`; use `/commit` for branch work.
- Typecheck failure: surface the command to run; offer `--skip-typecheck` only if the user explicitly accepts shipping unverified.
- Biome or semgrep failure: surface the finding. `--skip-typecheck` does not apply — fix it, or ship the change through `/commit` and a PR instead.
- Rebase conflict: surface the conflict; the user resolves then `git push origin main`.

## Naming issues without a PR

`/work <issue#>` parks its issue links on the branch you are standing on and cuts nothing, so on `main` those links are sitting right here. `ship-main.sh` writes a `Closes #N, #M` line for the issues marked code complete, moves them to Staged, and unlinks exactly those once the push lands. Incomplete issues stay linked on `main`.

The `Closes` line is how the next `/deploy` finds what shipped. Whether it closes the issue is GitHub configuration, not this command's: with the repository's "Auto-close issues with merged linked pull requests" setting on, GitHub closes the issue on this push; with it off, the issue stays open and the board decides (`github-project-board-setup.md`).

If the push fails the links stay put, so a retry names the same issues.

## What this does NOT do

- Does NOT open a PR or run CI — `pull_request` workflows don't fire on a push to `main`, and that's the point.
- Does NOT deploy — a deploy starts only when `/deploy` dispatches it; a main push triggers nothing. Run `/deploy` to ship.
- Does NOT bump version or write changelog — `/deploy` owns that; your ship-main commits get folded into the next release automatically.
- Does NOT auto-branch — that's `/commit`'s job and the whole reason `/ship-main` is separate.
- Does NOT push checkpoints — unpushed `/checkpoint` commits on `main` are folded into the one commit it makes, after every gate has passed, so no `🔖 wip:` subject reaches `main`.

## Prerequisite

`main` must NOT require a PR — the default on a new repo (the pipeline uses no branch protection; see `pipeline.md` §1.1). With require-PR set, GitHub rejects the direct push.
