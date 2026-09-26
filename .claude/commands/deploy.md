# /deploy

Cut a release: bump version + write changelog + push the bump directly to `main`, then tag and trigger the deploy workflow. Part of the gitflow subsystem. Invoked directly (`/deploy`) or via natural-language triggers ("deploy", "ship to prod", "release", "cut a release").

Bare `/deploy` ships the full fleet. `/deploy <service>` (e.g. `/deploy worker`, `/deploy worker rest`) ships only those services — a bare service name mirrors `/dev <workspace>` and maps to `deploy-<service>.yml`, validated before any bump.

$ARGUMENTS

## Design

`/deploy` is the **human-serialized release boundary**. Bump and deploy fire in the same invocation, in order — the source-of-truth version field and the deployed artifact built from that source match by construction. No skew, ever.

The bump commit pushes **directly to `main`** — no release branch, no PR, no admin-merge. It reuses the same direct-to-main mechanism as `/ship-main`. The bump commit + tag ARE the release record. This works because the pipeline uses no branch protection and `main` does not require a PR (pipeline.md §1.1); the diff has already passed full CI on the feature PRs that landed on main, so there is nothing for a release PR to gate on.

No command admin-merges — `/deploy` direct-pushes the bump and `/sync-dev-kit` does no git — so nothing depends on `enforce_admins`. See handbook §6.5.

## Procedure

### Step 1: State check (delegated to script via `--check-only`)

Run deploy.sh in check-only mode. This runs every state gate WITHOUT mutating anything (no bump, no commit, no push, no PR, no workflow trigger):

```bash
.claude/skills/gitflow/scripts/deploy.sh --check-only
```

If the script exits non-zero, surface the message and STOP. State gates are fail-loud and not overridable here. Common cases:
- exit 3: not on main → tell user to checkout main
- exit 4: dirty tree → tell user to /commit first (gitflow auto-branches)
- exit 5: out of sync → tell user to `git pull` or push pending work
- exit 6: HEAD has failed CI checks → surface which checks failed
- exit 7: no commits since last tag → nothing to deploy
- exit 8: required CLI missing (`gh`, or `aws` under the default `codebuild` backend)
- exit 21: AWS session not authenticated (`codebuild` backend) — the script prints the exact `aws login --profile <hub>` to run (resolved from `source_profile`, never the role profile itself — cli-utilities.md). This is caught here, before anything mutates; hand the login command to the user and wait, then re-run `/deploy` from the top

### Step 2: Determine bump level from commits since last tag

```bash
LAST_TAG=$(git describe --tags --abbrev=0 --match='v*.*.*' 2>/dev/null || echo "")
if [ -n "$LAST_TAG" ]; then
    git log "${LAST_TAG}..HEAD" --pretty=format:'%s'
else
    git log --pretty=format:'%s'
fi
```

Parse the SUBJECT LINES ONLY (one per commit). Apply this rule to the highest-severity match across all commits:

| Subject pattern | Bump |
|---|---|
| `<type>!:` or `BREAKING CHANGE:` footer | major |
| `feat(...):` or `✨ feat:` | minor |
| `fix(...):`, `perf(...):`, `refactor(...):` (with optional emoji) | patch |
| `chore(...):`, `docs(...):`, `test(...):`, `style(...):`, `ci(...):`, `build(...):` | patch (Option B — chore counts as patch) |
| Anything else | patch |

Highest wins (major > minor > patch). NEVER skip — if there are commits to deploy, there's a version to bump. "Deploy + skip version = lie."

Prior `🚀 release: v...` commits are by definition tag boundaries — they should never appear in the unbumped window because the last tag is created at that commit. If one shows up, the previous /deploy didn't tag-push cleanly; investigate before re-bumping.

### Step 3: Generate changelog entry

For each commit since last tag, compose a user-facing bullet in the existing changelog style (see top of `changelog.md`). Pattern:

```
- **<emoji> <Short Title Case>** - <one-line user-impact description>
```

Group related commits where it reads naturally (multiple fixes to the same surface = one bullet). Skip pure infra commits (e.g., `🔧 chore: bump deps` doesn't need a customer-facing line — but DO bump version since deps did change). For dep-only releases, write a single line like `- **♻️ Dependency Updates** - Routine package updates`.

Write the entry to a tempfile:

```bash
cat > /tmp/deploy-changelog-<random>.md <<'EOF'
- **✨ Feature Name** - Description
- **🐛 Bug Fix** - Description
EOF
```

NOTE on tempfile content: deploy.sh's changelog-insertion `awk` reads the entry file via `getline` (not `-v entry=...`) precisely because BSD awk on macOS rejects newlines in `-v` values. If a future edit re-introduces the `-v entry=` pattern, multi-bullet changelogs will fail mid-deploy on macOS hosts with `awk: newline in string`. See bash-rules §V (BSD awk vs gawk portability).

### Step 4: Show the plan, then run

Present to the user (no prompt — this is the human-in-the-loop step, /deploy invocation IS the confirmation):

```
Deploying v<CURRENT> → v<NEW> (<level>)
Changelog entries (<count>):
  - ...
  - ...
Pattern: bump + changelog commit on main → push main → tag → trigger workflow(s) from DEPLOY_WORKFLOWS
```

Then run:

```bash
.claude/skills/gitflow/scripts/deploy.sh \
    --level <level> \
    --changelog-file /tmp/deploy-changelog-<random>.md
```

If the invocation named a service subset (e.g. `/deploy worker`, or `/deploy worker rest`), forward those bare service names as trailing positional args (`… --changelog-file <file> worker rest`); the script maps each to `deploy-<service>.yml` and validates it before the bump. Adjust the plan's last line to name the targeted workflow(s) instead of the full `DEPLOY_WORKFLOWS`. A raw `--workflow <file>` from the invocation forwards unchanged. With no service named, omit both — the full fleet ships.

The script bumps, commits bump + changelog on `main` as `🚀 release: v<NEW>`, pushes `main` directly to origin (rebasing onto `origin/main` if it advanced), tags `v<NEW>` at the bump SHA, pushes the tag, then — **if `MIGRATE_WORKFLOW` is set — runs the migration workflow first and watches it to completion, aborting the whole deploy (exit 18/19) if it fails before any app deploy fires** — and finally triggers each workflow listed in `DEPLOY_WORKFLOWS` (resolved from `.claude/sync-substitutions.json`; falls back to `deploy.yml` if unset AND no `MIGRATE_WORKFLOW`), watching each run sequentially. A migrate-only repo (`MIGRATE_WORKFLOW` set, `DEPLOY_WORKFLOWS` empty) stops after the migration — see handbook §6.5 "Migration phase."

The direct push to `main` requires require-PR to be OFF on the consumer repo's `main` (the default — see pipeline.md §1.1). With require-PR set, GitHub rejects the push. `/deploy` no longer admin-merges or needs `enforce_admins: false`.

### Step 5: Report

| Outcome | Action |
|---|---|
| Success | Report `v<NEW>` deployed; link to the build (CodeBuild console, or the workflow run under `github`) |
| Push to main rejected | Usually require-PR is still ON on `main` — turn it off (pipeline.md §1.1) then retry. Other cause: `origin/main` advanced and the rebase hit a conflict; resolve and re-push. |
| Exit 21 (AWS session not authenticated) | Caught as a state gate before any mutation — nothing bumped, committed, or tagged. Hand the user the exact `aws login --profile <hub>` the script printed, wait for it to complete, then re-run `/deploy` from Step 1. |
| Exit 17 (tag push failed) | Tag-protection rules may be present; check `gh api repos/{owner}/{repo}/tags/protection` |
| Exit 18 (migration trigger failed) | The migration dispatch failed — under `codebuild`, check the project named by `CODEBUILD_MIGRATE_PROJECT` (or the prefix-derived name) exists and the role can start it; under `github`, check the workflow exists, has `workflow_dispatch:`, and is on main. Tag is already pushed; re-run the migrate + deploys manually (see Recovery) or fix and re-invoke. |
| Exit 19 (migration run failed) | The migration workflow ran and failed (or its run id couldn't be resolved) — deploy aborted BEFORE any app deploy. Surface the run URL; fix the migration, then trigger `MIGRATE_WORKFLOW` + the `DEPLOY_WORKFLOWS` manually (Recovery) — do NOT deploy apps against a failed migration. |
| Exit 13 (deploy run failed) | Surface the build URL; user investigates in the CodeBuild console (Actions UI under `github`). Every build's status is reported, so one broken service does not hide the others. |

If the script fails AFTER the bump commit pushed to `main` but BEFORE the tag / dispatch, the bump is already live on main. Recovery:

```bash
git checkout main && git pull --ff-only
git tag v<NEW> $(git rev-parse HEAD) && git push origin v<NEW>

# DEPLOY_BACKEND=codebuild — start each project by name:
PREFIX=$(jq -r .CODEBUILD_PROJECT_PREFIX .claude/sync-substitutions.json)
REGION=$(jq -r .AWS_REGION .claude/sync-substitutions.json)
PROFILE=$(jq -r .AWS_PROFILE .claude/sync-substitutions.json)
for wf in $(jq -r '.DEPLOY_WORKFLOWS // ""' .claude/sync-substitutions.json); do
    svc=${wf#deploy-}; svc=${svc%.yml}
    aws codebuild start-build --project-name "${PREFIX}${svc}" --profile "$PROFILE" --region "$REGION"
done

# DEPLOY_BACKEND=github (fallback) — trigger each workflow:
for wf in $(jq -r '.DEPLOY_WORKFLOWS // "deploy.yml"' .claude/sync-substitutions.json); do
    gh workflow run "$wf" --ref main
done
```

## What this command does

- Runs **no build gate**. `/merge` owns it, and builds while the PR is still open so a failure is fixed on the branch that caused it. A `/ship-main` commit reaches `/deploy` without a PR by design — re-adding a gate here would defeat the point of `/ship-main`.
- Commits the bump + changelog on `main` and pushes `main` directly (require-PR off, the default) — no release branch, no PR
- Tags after the bump commit lands on main (the tag lives on the bump SHA on main)
- Runs a **gated migration phase first** if `MIGRATE_WORKFLOW` is set (per-project sync-substitution, runtime-read; `--migrate-workflow <file>` overrides). Migration is deploy step 1 — watched to completion, real failure aborts before any app deploy. The migrate workflow's body owns no-op-as-success / trap-real-failures semantics (handbook §6.5). Migration is never invoked standalone. **Skipped entirely** when `MIGRATE_PATHS` (per-project sync-substitution, runtime-read; `--migrate-paths <path>...` overrides, space-separated) is set and nothing under those paths changed since the last deploy's tag — no runner is spun up (that's where the ~2 min goes: runner boot + `npm ci` to reach a no-op). Empty/missing `MIGRATE_PATHS` → the migration always fires (prior behavior). The reference is the previous deploy's tag, so a failed-then-recovered migration is unaffected (handbook §6.5).
- Dispatches every service in `DEPLOY_WORKFLOWS` (per-project sync-substitution, runtime-read; falls back to `deploy.yml` if unset AND no `MIGRATE_WORKFLOW`) to the compute named by `DEPLOY_BACKEND` (`codebuild`, `github`, `custom` or `none`). Under `codebuild` — the default — each name maps to a CodeBuild project via `CODEBUILD_PROJECT_PREFIX` and the fleet is dispatched concurrently and polled together; under `github` each is a `workflow_dispatch:`-only workflow watched in turn. A migrate-only repo (`MIGRATE_WORKFLOW` set + `DEPLOY_WORKFLOWS` empty) ships no app artifact. Under `custom` or `none` nothing is dispatched and nothing is bumped — see "Repo and account requirements".
- **Targets a subset with bare service names** — `/deploy worker` (or `/deploy worker rest`) ships only those services, mirroring `/dev <workspace>`. A bare positional maps to `deploy-<service>.yml` and is validated against `DEPLOY_WORKFLOWS` before any bump, so a typo fails loud (exit 2, nothing mutated) with the valid names rather than half-deploying. `--workflow <file>` remains the raw-filename escape hatch for a workflow not in the set; positional services and `--workflow` accumulate. Bare `/deploy` with neither still ships the full fleet.

## What this command does NOT do

- Does NOT open a release PR or admin-merge anything — the bump commit pushes straight to `main` (require-PR off, the default). No command admin-merges, so nothing needs `enforce_admins: false` (`/sync-dev-kit` does no git at all).
- Does NOT auto-bump on every feature-PR merge — auto-bump-on-merge causes version-skew between source and deployed artifact. NEVER restore it (see handbook §11.2).
- Does NOT generate the changelog from PR descriptions — uses commit subjects since last tag

## Blocking conditions

All come from deploy.sh state gates. See exit codes in the script header.

Additional cases specific to the direct-push flow:

- Push to `main` rejected: require-PR is still ON on `main`. Turn it off (pipeline.md §1.1) and retry. With require-PR set, GitHub rejects every direct push to main.
- `origin/main` advanced between the state-gate check and the push: the script rebases the bump commit onto the new main and re-pushes. On rebase conflict it stops; resolve and `git push origin main`.

## Repo and account requirements

- Under `DEPLOY_BACKEND=codebuild` (the default, so this applies to an unset key too): the `aws` CLI installed and authed (exit 8 otherwise), `CODEBUILD_PROJECT_PREFIX` and `AWS_REGION` set (exit 2 otherwise), and a CodeBuild project existing for every name in `DEPLOY_WORKFLOWS` plus `MIGRATE_WORKFLOW`
- Under `DEPLOY_BACKEND=github`: every workflow listed in `DEPLOY_WORKFLOWS` (or `deploy.yml` if unset) MUST have `workflow_dispatch:` as a trigger (and ideally ONLY that — see handbook §11.4)
- Under `DEPLOY_BACKEND=custom` or `none`: nothing. The script stops at exit 2 before any bump, commit or tag — `custom` because the project deploys by its own procedure (its rule under `.claude/rules/project/` carries the steps), `none` because it does not deploy at all
- `gh` CLI installed and authed
- `main` must have **require-PR OFF** (the default — pipeline.md §1.1) so the bump commit can push directly. The pipeline uses no branch protection.
