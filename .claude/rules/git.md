# Git

## Every git operation needs an explicit request in the current message

Start a git operation only when the human asks for one in the message you are answering — the `gitflow` skill, a slash command, or direct git alike.

Explicit means they said commit / checkpoint / push / open pr / merge / ship it, asked you to save or preserve work via git, or handed you the timing outright ("commit whenever you hit a good point" — rare, and it lasts only for the work in front of you). It does not mean: you finished a task, they said "done" or "looks good", they approved commits earlier in this session, you judged this a good stopping point, or they said "do this in main" — that means edit files in the main checkout.

The human owns the timeline, and each operation needs its own fresh instruction.

The one standing exception: an autonomous turn authorizes `/checkpoint`, and nothing else, for its own length (`autonomous-sessions.md`).

## Change `.gitignore` only when asked

Gitignoring a file changes what the repo tracks and shares with the team. Propose the change and the reason; the human decides.

## Reset, checkout, revert, restore and clean need explicit instruction

`git checkout <file>`, `git reset`, `git revert`, `git restore` and `git clean` destroy work. Run one only when the human says to revert, checkout, or reset that specific thing.

To fix your own mistake in a file, edit it with Read/Edit/Write. If you are unsure what the human wants, ask. If they say stop, stop.

`git-guard.sh` blocks these five and the gitflow-routed commands below. `SKIP_GIT_GUARD=1` bypasses it and is for a human-authorized emergency only — when you use it, tell the human you bypassed the guard and why.

## Commit everything

On commit or checkpoint, commit ALL uncommitted changes — staged, unstaged and untracked. The gitflow scripts stage everything for you. Cherry-pick files only when the human says "only commit X".

## Route git through gitflow

Run these through gitflow, never directly: `git commit`, `git add`, `git push`, `git merge`, `git checkout -b` / `git switch -b`, `git branch -m`. The scripts under `.claude/skills/gitflow/scripts/` are authorized to run them internally; you are not.

| The human says | Invoke |
|---|---|
| "work on this", "open the project", "pick up where I left off", "start work" | `/work` |
| "start work on #N", "work issue N" | `/work <N>` |
| "retrieve branch", "pull a teammate's branch" | `/work --retrieve <branch>` |
| "the discussion is done", "pull the discussion in" | `/work --discussion <slug or URL>` |
| "commit", "commit this", "commit the changes" | `/commit` |
| "checkpoint", "save progress", "wip commit" | `/checkpoint` |
| "link issue", "also works on #N", "add #N to this branch" | `/work <N>` |
| "catch up with main", "pull main into my branch", "update my branch with main" | `/catchup` |
| "continue the merge", "finish catching up" | `/catchup --continue` |
| "abort the catchup", "bail on the merge" | `/catchup --abort` |
| "open pr", "open a pull request", "submit for review" | `/open-pr` |
| "triage", "work the review", "go through gemini", "walk the review" | `/triage` |
| "merge", "merge to main", "ship it" | `/merge` |
| "ship to main", "commit straight to main", "infra commit", "emergency commit to main" | `/ship-main` |

**Bare "commit" always routes to `/commit`,** which auto-branches off main — the safety for editing on main by accident. `/ship-main` is the deliberate direct-to-main exception and fires only on its own triggers above. Never infer it from the human being on `main`.

`/ship-main` and `/deploy` are human-triggered; never initiate either.

## Read-only git needs no gitflow

`git status`, `log`, `diff`, `show`, `branch` (no flags), `fetch`, `stash list`, `ls-files`, `config`, `remote`, `rev-parse`.
