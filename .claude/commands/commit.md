# /commit

Full conventional commit with AI-generated message. Part of the gitflow subsystem (layer 3). Invoked directly by the user (`/commit`) or by Claude in response to natural-language triggers ("commit this", "commit the changes") via the gitflow skill.

$ARGUMENTS

## Procedure

### Step 1: Analyze current changes

```bash
git status
git diff --stat
```

If nothing to commit, report and stop.

### Step 2: Categorize changes

Group related files. Identify distinct features, fixes, or chores. **Analyze ALL changes, not just what you worked on this session** — prior-session changes may still be uncommitted.

### Step 3: Build conventional commit message

Load `.claude/skills/gitflow/references/commit-types.md` for emoji/type mapping.

- Single feature: `<emoji> <type>: <description>`
- Multiple features: primary type on first line, bullet list in body
- Subject line: imperative mood, <72 chars
- Breaking change: use `!` after type (e.g., `✨ feat!:`) or `BREAKING CHANGE:` footer

### Step 4: Detect model name

Use the model you are currently running as (e.g., "Claude Opus 4.7", "Claude Sonnet 4.6"). Pass via `--model`.

### Step 5: Decide Gemini review trigger

Gemini Code Assist's auto-review on PR open is **disabled** (`.gemini/config.yaml: pull_request_opened.code_review: false`). Reviews fire only when a `/gemini review` comment is posted on the PR. `commit.sh` posts that comment after push **only when `--review` is passed**. This step decides which flag to pass.

Resolve in this order:

1. **User-specified flag in `$ARGUMENTS`.** If the user invoked `/commit --review` or `/commit --no-review`, honor it and skip the prompt.
2. **No open PR for the current branch.** Pass nothing — there's no PR to comment on. `commit.sh` short-circuits cleanly.
   ```bash
   PR_NUMBER=$(gh pr list --head "$(git branch --show-current)" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
   ```
3. **PR is open and the user did NOT specify a flag.** Ask in prose and wait: whether to trigger a Gemini review on this commit. Carry both consequences — reviewing posts `/gemini review` after the push, which earns its keep early in the PR or when fixes substantively change behavior; skipping it is right in late triage once the decision to ship is made, saving Gemini quota and letting `/merge` proceed on CI alone.

   Map the answer to the flag: review → `--review`, skip → `--no-review`.

`GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json` makes `--review` a no-op (script skips the post and logs it). The prompt still appears — the slash command doesn't read the substitution file. That's intentional: the flag is the contract; the runtime decides whether the contract is satisfiable.

### Step 6: Ask which linked issues are code complete

Code complete means finished and waiting for deployment — not "some of it is committed".
A complete issue moves to Staged on the project board; `/open-pr` later refuses to open
while any linked issue is not complete.

1. **User already said in `$ARGUMENTS`** — `/commit --complete 42,43`, or "commit, #42 is
   done". Honor it and skip the question.
2. **List the linked issues not yet complete:**
   ```bash
   bash -c 'source .claude/skills/gitflow/scripts/issue_helpers.sh && read_branch_incomplete_issues'
   ```
   Empty → no question, pass nothing.
3. **Otherwise ask, in prose, and wait** — one question naming them all, e.g. "Are any of
   #42, #43 code complete? Complete ones move to Staged." All, none, or a subset are all
   valid answers. Ask it on its own, before the Step 5 review question when both apply —
   one question at a time.

Map the answer to `--complete "<N,N>"`, or pass nothing for none.

**Then write the Staged comment for each of them that has not had one** — the issue's
author reviews against it. List the ones still needing it:

```bash
bash -c 'source .claude/skills/gitflow/scripts/issue_helpers.sh && issues_needing_notes "<N N>"'
```

Read `.claude/skills/gitflow/references/staged-comment.md` and the issue itself
(`gh issue view <N>`), then write one file per issue, `<notes_dir>/<N>.md`, in a scratch
directory outside the repo (`mktemp -d`). Pass it as `--notes <notes_dir>`. Write it and
move on — never put the wording to the human for approval. The script refuses before
committing (exit 2) when one is missing, and posts each once the board has moved.

### Step 7: Invoke the script

```bash
.claude/skills/gitflow/scripts/commit.sh \
  --message "<full conventional message>" \
  --model "<model name>" \
  <--review | --no-review | (nothing if no open PR)> \
  [--complete "<N,N>" --notes <notes_dir>]
```

Pass `--skip-typecheck` ONLY if the user explicitly requested bypassing typecheck (rare).

### Step 8: Report result

- Commit succeeded: report the commit hash and branch, and any issues moved to Staged
- `main has moved` in the output: relay the commits behind and the files changed on both
  sides, and recommend `/catchup` — before any further work when files overlap. It is a
  warning; the commit still landed. On `main` it fires BEFORE the branch is cut, so the new
  branch starts from a copy of `main` the user now knows is stale.
- Script exited non-zero: surface the exit code and stderr. Do NOT retry without direction.

## Branch behavior

The script resolves the target branch before committing:

| Current branch | Action |
|----------------|--------|
| `main` / `master` | Derive `<type>/<slug>` from the commit message, create and switch. Any issue links parked on `main` by `/work <issue#>`, and which of them are complete, are carried onto the new branch and cleared from `main`. Any `/checkpoint` commits move with it, and local `main` is reset to where they started. |
| Any other branch | Commit in place |

Collisions on the target name are resolved by appending `-2`, `-3`, etc.

Unpushed `/checkpoint` commits are folded into this one: once every gate has passed, the script soft-resets to the commit they sit on and commits once. The gates scan everything the checkpoints saved, since checkpoints skip them.

## What this command does NOT do

- Does not update `CHANGELOG.md` — per-PR draft handled by `/open-pr`; consolidated release entry handled by `/deploy`
- Does not bump version — handled by `/deploy` (local, human-in-the-loop)
- Does not create a tag — same
- Does not open a PR — separate step via `/open-pr`

## Blocking conditions

The script will exit non-zero if:

- TypeScript or Python typecheck fails
- Biome lint reports an error, or `biome.json` is present and `@biomejs/biome` is not installed
- Semgrep reports a finding in a file this commit touches, or CI declares a `semgrep` job and semgrep is not installed locally
- Nothing is staged (empty diff)
- `git commit` itself fails for any reason
- `--review` and `--no-review` both passed (mutually exclusive — exit 2)
- `--review` passed and the `/gemini review` comment failed to post (exit 10 — fail-loud so the user knows Gemini is NOT coming; downstream `wait-for-pr-ready.sh` would otherwise silently proceed CI-only)
- `--complete` names an issue not linked on the branch (exit 2, before anything is committed)
- The commit and push landed but the board update failed (exit 11 — the issues are marked complete locally; `/open-pr` sets every linked issue to Staged again)
- An issue reaching Staged has no comment in `--notes` (exit 2, before anything is committed)
- The commit, push and board update landed but a Staged comment did not post (exit 13 — the script prints the exact `gh issue comment` to run)

When the script blocks, surface the reason to the user. Fix underlying issues per constitution section XVI (own all errors). Do not bypass.

## Recovery: `--push-only` mode

If a prior `/commit` succeeded at the commit step but failed at push (typical cause: a branch left tracking `origin/main` rather than its own remote ref — plain `git push` then fails under `push.default=simple`), re-trigger the push without re-running typecheck or staging:

```bash
.claude/skills/gitflow/scripts/commit.sh --push-only
```

Push-only:
- Refuses if the working tree has uncommitted changes (use the regular flow instead).
- Refuses on detached HEAD.
- Invokes `safe_push` which sets/corrects upstream to `origin/<branch>` on first push.
- No-op behavior when HEAD is already at the remote (git push reports "Everything up-to-date").

Use this when picking up a half-shipped /commit from a previous session.
