#!/bin/bash
# gitflow deploy: bump version + write changelog + ship through the same
# protected-main PR gate as every other change, then tag + trigger deploy.
#
# Usage: deploy.sh --level <patch|minor|major> --changelog-file <path>
#                  [<service>...] [--workflow <file>]... [--migrate-workflow <file>]
#                  [--migrate-paths <path>...] [--no-watch] [--timeout-min <minutes>]
#        deploy.sh --check-only
#
# A bare positional <service> (e.g. `worker`, `rest`) is sugar for the workflow
# `deploy-<service>.yml` and mirrors /dev's bare-workspace form — e.g.
# `deploy.sh --level patch --changelog-file f worker` ships worker only.
# Repeatable (`... worker rest`). Each name is VALIDATED against the known
# DEPLOY_WORKFLOWS set before any bump, so a typo fails loud rather than
# half-deploying. `--workflow <file>` is the raw-filename escape hatch for a
# workflow not in that set; positional services and --workflow accumulate.
#
# --workflow is repeatable. If BOTH it and positional services are omitted, the
# script reads `DEPLOY_WORKFLOWS` (space-separated) from
# `.claude/sync-substitutions.json`. If that's also absent AND no migration
# workflow is configured, falls back to `deploy.yml`. Each app workflow is
# triggered + watched in sequence.
#
# --migrate-workflow (single file) is deploy STEP 1: a DB-migration workflow
# run ONCE, BEFORE any app deploy, and watched to completion (gated — a real
# migration failure aborts the deploy before any app ships). If omitted, the
# script reads `MIGRATE_WORKFLOW` from `.claude/sync-substitutions.json`.
# When set with an empty DEPLOY_WORKFLOWS, the deploy is migration-only (a
# repo that maintains a database but ships no app artifact — no deploy.yml
# fallback is injected). Migration is never invoked on its own; it exists
# only as deploy's first phase.
#
# --migrate-paths (space-separated pathspecs) is the migration-skip optimization:
# before firing the migration workflow, deploy.sh diffs these paths across
# `<last-tag>..HEAD`. If NOTHING under them changed since the last deploy, the
# migration workflow is SKIPPED entirely — no runner spun up (which is where the
# ~2 min goes: runner boot + `npm ci` just to reach a drizzle-kit no-op). If
# omitted, the script reads `MIGRATE_PATHS` from `.claude/sync-substitutions.json`;
# if that is also empty the workflow ALWAYS fires (prior behavior). The reference
# is the PREVIOUS deploy's tag (LAST_TAG), so a failed-then-recovered migration is
# unaffected — see the skip block at step 10 and handbook §6.5.
#
# ─── Design ─────────────────────────────────────────────────────────────
# /deploy is a HUMAN-SERIALIZED release boundary, not an auto-bump-on-merge.
# Bump and deploy fire in the same invocation, in order. The source of
# truth (version field) and the deployed artifact (built from that source
# the moment after the bump lands on main) match by construction. No skew.
#
# The bump commit is pushed DIRECTLY to main (the pipeline uses no branch
# protection; require-PR is off — see pipeline.md §1.1 / handbook §6.5). No
# release branch, no PR, no admin-merge — the bump commit + the tag ARE the
# release record. This is the same direct-to-main mechanism as ship-main.sh.
#
# ─── State gates (all enforced before any mutation) ──────────────────────
#   - DEPLOY_BACKEND is codebuild, github, custom or none. custom and none stop
#     the run at exit 2 before any mutation — they are not failures, they are the
#     project saying /deploy is not its release path.
#   - DEPLOY_BACKEND=codebuild (the default): AWS CLI installed, region/prefix
#     configured, DEPLOY_AWS_ACCESS_KEY_ID/DEPLOY_AWS_SECRET_ACCESS_KEY present in
#     .env, and `aws sts get-caller-identity` succeeds against them — a revoked
#     or mistyped key is caught HERE, not at the migration/deploy dispatch step
#     after the tag is already pushed. This is a dedicated, narrowly-scoped
#     credential (new-project-setup.md §7c) — separate from AWS_PROFILE and the
#     personal admin hub-and-role chain (cli-utilities.md); the two never mix.
#   - On main branch
#   - Working tree clean
#   - Local main == origin/main (no stale local; nothing un-pushed)
#   - HEAD's required check-runs are not 'failure' (read-only snapshot,
#     not a wait — see /merge for pre-merge wait logic)
#   - Commits exist since the last v* tag (nothing to deploy otherwise)
#
# --check-only: runs all gates without mutating, exits 0 if clean.
#
# ─── Flow (without --check-only) ────────────────────────────────────────
#   0. NO build gate. `/merge` owns it — it builds while the PR is still OPEN,
#      so a failure is fixed on the branch that caused it. Deploying a
#      `/ship-main` commit deliberately skips every gate; that is what
#      `/ship-main` is for, and re-adding a gate here would defeat it.
#   1. Bump version in the appropriate manifest (pyproject.toml or package.json
#      via `npm version`).
#   2. Apply changelog file under today's `### Month Day, Year` header.
#   3. Commit bump + changelog DIRECTLY on main, subject `🚀 release: v<NEW>`.
#   4. Push the commit straight to main (clean fast-forward — the state gate
#      guaranteed local main == origin/main). No branch, no PR, no admin-merge.
#   5. Tag v<NEW> at that commit, push tag (tags aren't behind branch
#      protection on `branches/*` rules; tag-protection rules are separate).
#  10. If MIGRATE_WORKFLOW is set: unless MIGRATE_PATHS shows no migration files
#      changed since the last deploy (in which case the migration is skipped
#      entirely), dispatch it — `aws codebuild start-build` under codebuild,
#      `gh workflow run` under github — and watch it to completion FIRST. A real
#      migration failure aborts here (exit 19) before any app deploy. No-op
#      migrations are the project migration's job to report as success.
#  11. Dispatch each service in DEPLOY_WORKFLOWS the same way and, unless
#      --no-watch, watch them (see the backend section below). Migrate-only
#      repos (no DEPLOY_WORKFLOWS) stop after step 10.
#
# ─── Dispatch backend (DEPLOY_BACKEND) ───────────────────────────────────
# Four values, and the only question the key answers is what else must be set.
# `codebuild` (the default) starts AWS CodeBuild projects: everything that
# touches AWS runs on AWS compute, so no workflow holds an AWS credential and
# the only remaining GitHub dependency is the git clone. `github` fires GitHub
# Actions workflows instead, and is correct for a repo that deploys somewhere
# with no AWS account behind it. `custom` means the project DOES deploy, by a procedure
# this script does not dispatch — /deploy stops before any bump and the
# project's own rule under rules/project/ carries the steps. `none` means the
# project does not deploy at all.
#
# custom and none are deliberately NOT a taxonomy of deploy mechanisms. An SSH
# push, a container registry, a hand-run script and a hosting provider's own CLI
# all say `custom`; the shape of that deploy lives in the project's deploy
# script and rule, which is where it can actually be executed.
#
# Under codebuild the fleet is dispatched CONCURRENTLY and polled together,
# where github watches each run in turn — a six-service release costs the
# slowest service rather than the sum of all six.
#
# DEPLOY_WORKFLOWS remains the single service list. A workflow filename maps to
# a project by CODEBUILD_PROJECT_PREFIX (deploy-worker.yml → <prefix>worker), so
# there is no second list to drift. CODEBUILD_MIGRATE_PROJECT names the
# migration project when it does not follow that pattern.
#
# The migrate gate is identical on both dispatching backends: watched to completion, a real
# failure aborts with exit 19 before any app ships.
#
# ─── Exit codes ──────────────────────────────────────────────────────────
#   2  bad args; also DEPLOY_BACKEND=custom/none (this script does not deploy
#      this project) or an unrecognized DEPLOY_BACKEND value — all raised
#      before any bump, commit or tag
#   3  not on main
#   4  dirty working tree
#   5  out of sync with origin
#   6  HEAD has failed required check-runs
#   7  no commits since last tag (nothing to deploy)
#   8  required CLI not available (gh; also aws under the default codebuild backend)
#   9  npm/python3 not available
#  10  bump failed
#  11  push failed
#  12  workflow trigger failed
#  13  deploy workflow run failed
#  17  tag push failed
#  18  migration workflow failed to trigger
#  19  migration run failed (or its run id could not be resolved) — deploy
#      aborted before any app workflow fired
#  20  git diff for the migration-path skip check failed
#  21  deploy-trigger AWS credential missing from .env or invalid (codebuild
#      backend) — checked as a state gate before any mutation, so this never
#      fires after the bump/tag
#
# ─── Recovery ────────────────────────────────────────────────────────────
# The bump commit and the push to main happen together (steps 3–4). If the
# push fails, nothing landed remotely; the local bump commit sits one ahead of
# origin/main — pull --ff-only (or undo the local commit yourself) and re-run
# /deploy. If the push SUCCEEDED but the TAG push failed (exit 17), the release
# commit is already on main — just tag + dispatch deploys manually:
#   git tag v<NEW> $(git rev-parse origin/main) && git push origin v<NEW>
#   codebuild: aws codebuild start-build --project-name <prefix><service>
#   github:    gh workflow run <deploy-wf> --ref main
# (one per service in DEPLOY_WORKFLOWS; the migration first, if it has not run).
# A build that failed for a reason outside the code — a registry rate limit, a
# transient network error — is recovered the same way: re-dispatch it, with no
# new bump and no second migration.

set -e

# Resolve script dir so we can source siblings without an LSP-style
# bootstrap dance later in the file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

LEVEL=""
CHANGELOG_FILE=""
# WORKFLOWS: empty after arg parse means "read DEPLOY_WORKFLOWS from
# .claude/sync-substitutions.json at runtime; fall back to deploy.yml if
# unset". --workflow flags accumulate (repeatable) and override the
# substitution. See handbook §6.5 for split-deploy consumer pattern.
WORKFLOWS=()
# Bare positional service names (e.g. `worker`) → deploy-<name>.yml, resolved +
# validated against DEPLOY_WORKFLOWS after arg parse. Accumulate with --workflow.
SERVICES=()
MIGRATE_WF=""
# MIGRATE_PATHS: space-separated pathspecs. Empty after arg parse means "read
# MIGRATE_PATHS from .claude/sync-substitutions.json at runtime; if still empty,
# the migration workflow always fires (no skip)." See the step-10 skip block.
MIGRATE_PATHS=""
WATCH=1
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --level)             LEVEL="$2"; shift 2 ;;
        --changelog-file)    CHANGELOG_FILE="$2"; shift 2 ;;
        --workflow)          WORKFLOWS+=("$2"); shift 2 ;;
        --migrate-workflow)  MIGRATE_WF="$2"; shift 2 ;;
        --migrate-paths)     MIGRATE_PATHS="$2"; shift 2 ;;
        --no-watch)          WATCH=0; shift 1 ;;
        --check-only)        CHECK_ONLY=1; shift 1 ;;
        --timeout-min)       shift 2 ;;  # accepted-but-ignored; removed under E66 admin-merge (no CI wait)
        --*) echo "deploy.sh: unknown option: $1" >&2; exit 2 ;;
        # Bare positional = service name → deploy-<name>.yml (mirrors /dev's
        # bare-workspace convention). Validated against DEPLOY_WORKFLOWS below.
        *) SERVICES+=("$1"); shift 1 ;;
    esac
done

# Resolve WORKFLOWS + MIGRATE_WF. Read DEPLOY_WORKFLOWS (space-separated) and
# MIGRATE_WORKFLOW (single file) from .claude/sync-substitutions.json when we
# need them: to supply the DEFAULT fleet (no --workflow AND no positional
# service), to VALIDATE positional service names against the known set, or when
# --migrate-workflow wasn't passed. jq is required only when a read is needed.
SUBS_FILE=".claude/sync-substitutions.json"
DEPLOY_WORKFLOWS_VAL=""
NEED_LIST=0
[ ${#WORKFLOWS[@]} -eq 0 ] && [ ${#SERVICES[@]} -eq 0 ] && NEED_LIST=1  # default fleet
[ ${#SERVICES[@]} -gt 0 ] && NEED_LIST=1                                # validate services
NEED_MIG=0
[ -z "$MIGRATE_WF" ] && NEED_MIG=1
NEED_MIG_PATHS=0
[ -z "$MIGRATE_PATHS" ] && NEED_MIG_PATHS=1
if { [ "$NEED_LIST" -eq 1 ] || [ "$NEED_MIG" -eq 1 ] || [ "$NEED_MIG_PATHS" -eq 1 ]; } && [ -f "$SUBS_FILE" ]; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "deploy.sh: $SUBS_FILE present but jq is missing. Install jq or pass --workflow/--migrate-workflow explicitly." >&2
        exit 8
    fi
    [ "$NEED_LIST" -eq 1 ] && DEPLOY_WORKFLOWS_VAL=$(jq -r '.DEPLOY_WORKFLOWS // ""' "$SUBS_FILE")
    [ "$NEED_MIG" -eq 1 ] && MIGRATE_WF=$(jq -r '.MIGRATE_WORKFLOW // ""' "$SUBS_FILE")
    [ "$NEED_MIG_PATHS" -eq 1 ] && MIGRATE_PATHS=$(jq -r '.MIGRATE_PATHS // ""' "$SUBS_FILE")
fi

# ─── Dispatch backend ────────────────────────────────────────────────────
# `codebuild` (the default) starts AWS CodeBuild projects; `github` triggers
# GitHub Actions workflows, and stays because a repo deploying somewhere with
# no AWS account behind it has nowhere to put a build project.
#
# Read from a per-consumer substitution, never sniffed from the repo: a release
# boundary must not guess where it is shipping from. An unset key therefore
# lands on the default and fails loud below if the project has not provisioned
# for it, rather than silently shipping through the other one.
#
# DEPLOY_WORKFLOWS stays the single service list either way. Under codebuild a
# workflow filename maps to a project by prefix — deploy-worker.yml with prefix
# "acme-deploy-" is project acme-deploy-worker — so there is no second list to
# drift out of step with the first.
DEPLOY_BACKEND="codebuild"
CODEBUILD_PROJECT_PREFIX=""
CODEBUILD_MIGRATE_PROJECT=""
CB_AWS_REGION=""
if [ -f "$SUBS_FILE" ] && command -v jq >/dev/null 2>&1; then
    DEPLOY_BACKEND=$(jq -r '.DEPLOY_BACKEND // ""' "$SUBS_FILE")
    # Empty is the kit's "intentionally disabled" state for a substitution key,
    # and jq's // only falls back on a MISSING key — so normalize it here rather
    # than failing every deploy on a consumer that left the key blank.
    [ -n "$DEPLOY_BACKEND" ] || DEPLOY_BACKEND="codebuild"
    CODEBUILD_PROJECT_PREFIX=$(jq -r '.CODEBUILD_PROJECT_PREFIX // ""' "$SUBS_FILE")
    CODEBUILD_MIGRATE_PROJECT=$(jq -r '.CODEBUILD_MIGRATE_PROJECT // ""' "$SUBS_FILE")
    CB_AWS_REGION=$(jq -r '.AWS_REGION // ""' "$SUBS_FILE")
fi
case "$DEPLOY_BACKEND" in
    github) ;;
    custom)
        # The project DOES deploy — just not through a dispatcher this script
        # owns. Its own procedure lives in rules/project/, so the honest thing
        # is to stop here rather than bump a version for a release nobody ships.
        echo "deploy.sh: DEPLOY_BACKEND=custom — this project deploys by its own procedure, not through /deploy." >&2
        echo "  Follow the project's own deploy rule under .claude/rules/project/. Nothing was bumped or tagged." >&2
        exit 2 ;;
    none)
        echo "deploy.sh: DEPLOY_BACKEND=none — this project does not deploy." >&2
        echo "  If that is wrong, set DEPLOY_BACKEND in $SUBS_FILE. Nothing was bumped or tagged." >&2
        exit 2 ;;
    codebuild)
        command -v aws >/dev/null 2>&1 || {
            echo "deploy.sh: DEPLOY_BACKEND=codebuild but the aws CLI is not installed" >&2; exit 8; }
        [ -n "$CODEBUILD_PROJECT_PREFIX" ] || {
            echo "deploy.sh: DEPLOY_BACKEND=codebuild requires CODEBUILD_PROJECT_PREFIX in $SUBS_FILE" >&2
            echo "  codebuild is the default. If this project deploys via GitHub Actions instead, set DEPLOY_BACKEND=github." >&2
            exit 2; }
        # Never rely on ambient AWS config. A shell with no default region makes
        # every aws call exit 253 before it reaches the service, which reads as a
        # deploy that started nothing — after the tag has already been pushed.
        [ -n "$CB_AWS_REGION" ] || {
            echo "deploy.sh: DEPLOY_BACKEND=codebuild requires AWS_REGION in $SUBS_FILE" >&2; exit 2; }
        # deploy.sh authenticates with its OWN narrowly-scoped credential —
        # codebuild:StartBuild + codebuild:BatchGetBuilds on the named project ARNs
        # only, created directly in the target account (new-project-setup.md §7c).
        # It is DELIBERATELY separate from AWS_PROFILE / the admin hub-and-role
        # chain (cli-utilities.md): that chain solves a different problem (one
        # consultant, many client accounts) and has no bearing on this repo's own
        # recurring deploy trigger. A long-lived static key is the right shape here
        # (infrastructure.md's "long-lived credential" carve-out) because the IAM
        # policy — not the key's age — is what bounds the risk: it can start these
        # named builds and read their status, nothing else, ever.
        #
        # Read from .env, never from sync-substitutions.json (that file is
        # committed; this is a secret) — same grep|cut|xargs convention as every
        # other .env read in this repo (development-guidelines.md).
        DEPLOY_AWS_ACCESS_KEY_ID=$(grep "^DEPLOY_AWS_ACCESS_KEY_ID=" .env 2>/dev/null | cut -d'=' -f2- | cut -d'#' -f1 | xargs || true)
        DEPLOY_AWS_SECRET_ACCESS_KEY=$(grep "^DEPLOY_AWS_SECRET_ACCESS_KEY=" .env 2>/dev/null | cut -d'=' -f2- | cut -d'#' -f1 | xargs || true)
        if [ -z "$DEPLOY_AWS_ACCESS_KEY_ID" ] || [ -z "$DEPLOY_AWS_SECRET_ACCESS_KEY" ]; then
            echo "deploy.sh: DEPLOY_AWS_ACCESS_KEY_ID / DEPLOY_AWS_SECRET_ACCESS_KEY not set in .env" >&2
            echo "  This is a separate, narrowly-scoped credential from your personal AWS_PROFILE —" >&2
            echo "  provision it per new-project-setup.md §7c (\"Deploy trigger credential\")." >&2
            exit 21
        fi
        export AWS_ACCESS_KEY_ID="$DEPLOY_AWS_ACCESS_KEY_ID"
        export AWS_SECRET_ACCESS_KEY="$DEPLOY_AWS_SECRET_ACCESS_KEY"
        CB_AWS_ARGS="--region $CB_AWS_REGION"
        # Fail loud on a revoked/wrong key HERE — before the bump, the commit, or
        # the tag — not when the migration/deploy dispatch tries to use it.
        # Discovering this at exit 18/19 leaves the tag already pushed and the
        # release record half-true for a fact that was knowable up front.
        # --check-only hits this too, since it's a state gate.
        # shellcheck disable=SC2086 # intentional word-splitting on the aws flag list
        if ! aws $CB_AWS_ARGS sts get-caller-identity >/dev/null 2>&1; then
            echo "deploy.sh: the deploy-trigger AWS key in .env is not valid (DEPLOY_BACKEND=codebuild)" >&2
            echo "  It does not expire on a schedule — a failure here means it was revoked or mistyped." >&2
            echo "  Re-provision per new-project-setup.md §7c, or check .env for a typo." >&2
            exit 21
        fi
        ;;
    *) echo "deploy.sh: DEPLOY_BACKEND must be codebuild, github, custom or none (got: '$DEPLOY_BACKEND')" >&2; exit 2 ;;
esac

# deploy-<service>.yml → <prefix><service>
cb_project_for() { _s=${1#deploy-}; _s=${_s%.yml}; printf '%s%s' "$CODEBUILD_PROJECT_PREFIX" "$_s"; }

# Start one build; echoes its id. On failure the aws error goes to stderr and the
# non-zero status propagates — the caller MUST use `if ! id=$(cb_start ...)`, since
# a bare `id=$(cb_start ...)` under `set -e` aborts the script before any guard on
# the following line can run.
# shellcheck disable=SC2086 # intentional word-splitting on the aws flag list
cb_start() { aws $CB_AWS_ARGS codebuild start-build --project-name "$1" --query 'build.id' --output text; }

# Poll a set of build ids until none is IN_PROGRESS, then echo "<id> <status>"
# per line. Polling them TOGETHER is what makes a fleet release take as long as
# its slowest service instead of the sum of all of them.
cb_wait() {
    _ids="$*"
    while :; do
        # shellcheck disable=SC2086 # intentional word-splitting on the id list
        _out=$(aws $CB_AWS_ARGS codebuild batch-get-builds --ids $_ids --query 'builds[].[id,buildStatus]' --output text) || _out=""
        if [ -z "$_out" ]; then
            echo "deploy.sh: batch-get-builds returned nothing for [$_ids] — cannot confirm the deploy (fail-loud, §X)" >&2
            return 1
        fi
        printf '%s\n' "$_out" | grep -q 'IN_PROGRESS' || { printf '%s\n' "$_out"; return 0; }
        sleep 10
    done
}

# Map positional service names → deploy-<name>.yml, each validated against the
# known DEPLOY_WORKFLOWS set. A typo fails loud HERE (before any bump/tag) with
# the valid names, instead of bumping + tagging and then failing to trigger a
# non-existent workflow. Validated names accumulate into WORKFLOWS alongside any
# --workflow filenames.
if [ ${#SERVICES[@]} -gt 0 ]; then
    for svc in "${SERVICES[@]}"; do
        wf="deploy-$svc.yml"
        found=0
        # shellcheck disable=SC2086 # intentional word-splitting on space-separated list
        for known in $DEPLOY_WORKFLOWS_VAL; do
            [ "$known" = "$wf" ] && { found=1; break; }
        done
        if [ "$found" -eq 0 ]; then
            valid=""
            # shellcheck disable=SC2086 # intentional word-splitting on space-separated list
            for known in $DEPLOY_WORKFLOWS_VAL; do
                s=${known#deploy-}; s=${s%.yml}; valid="$valid $s"
            done
            echo "deploy.sh: unknown service '$svc' — valid services:${valid:- (none configured in DEPLOY_WORKFLOWS)}" >&2
            exit 2
        fi
        WORKFLOWS+=("$wf")
    done
fi

# Default fleet: neither --workflow nor a positional service was given → the
# full DEPLOY_WORKFLOWS list.
if [ ${#WORKFLOWS[@]} -eq 0 ] && [ -n "$DEPLOY_WORKFLOWS_VAL" ]; then
    # shellcheck disable=SC2086 # intentional word-splitting on space-separated workflow list
    for w in $DEPLOY_WORKFLOWS_VAL; do WORKFLOWS+=("$w"); done
fi
# Fallback to deploy.yml ONLY when there is no app-deploy list AND no migration
# phase. A migrate-only repo (MIGRATE_WORKFLOW set, DEPLOY_WORKFLOWS empty)
# deliberately ships no app artifact — do NOT inject the deploy.yml default.
if [ ${#WORKFLOWS[@]} -eq 0 ] && [ -z "$MIGRATE_WF" ]; then
    WORKFLOWS=("deploy.yml")
fi

if [ "$CHECK_ONLY" -eq 0 ]; then
    case "$LEVEL" in
        patch|minor|major) ;;
        *) echo "deploy.sh: --level must be patch|minor|major (got: '$LEVEL')" >&2; exit 2 ;;
    esac

    if [ -z "$CHANGELOG_FILE" ] || [ ! -f "$CHANGELOG_FILE" ]; then
        echo "deploy.sh: --changelog-file must point to an existing file" >&2
        exit 2
    fi
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "deploy.sh: gh CLI required. brew install gh && gh auth login" >&2
    exit 8
fi

if [ -f "package.json" ] && ! command -v npm >/dev/null 2>&1; then
    echo "deploy.sh: npm required for Node projects" >&2
    exit 9
fi

# --- State gates --------------------------------------------------------

CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "deploy.sh: must be on main (currently on '$CURRENT_BRANCH')" >&2
    exit 3
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "deploy.sh: working tree is dirty. Commit or stash before deploying." >&2
    git status --short >&2
    exit 4
fi

git fetch origin main --quiet
LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse origin/main)
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    echo "deploy.sh: local main ($LOCAL_SHA) is not in sync with origin/main ($REMOTE_SHA)" >&2
    echo "  Pull or push before deploying." >&2
    exit 5
fi

# Check-runs gate: refuse if any non-Dependabot check on HEAD failed.
# Empty (no checks configured) passes — fresh repos with no CI yet.
# Excludes the "Dependabot" check-run (GitHub's "Dependabot Updates" workflow):
# it re-fires on every push to main as version-bump housekeeping and can fail
# for reasons unrelated to deployability (e.g. it can't open a bump PR). It is
# NOT a code-quality/deployability gate, so a failed Dependabot update must not
# block a release. Real CI checks (check-types, biome, vitest, semgrep, lint)
# are still enforced.
# Explicit error check (bash-rules §III: command-sub failure in an assignment
# does not reliably trip `set -e` on bash 3.2). A gh API failure must fail loud,
# not default to 0 and let an unverified gate pass (Constitution §X).
if ! FAILED=$(gh api "repos/{owner}/{repo}/commits/${LOCAL_SHA}/check-runs" \
    --jq '[.check_runs[] | select((.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled") and .name != "Dependabot")] | length' 2>&1); then
    echo "deploy.sh: failed to fetch check-runs from the GitHub API — refusing to deploy (fail-loud, §X):" >&2
    printf '  %s\n' "$FAILED" >&2
    exit 6
fi
if [ "$FAILED" -gt 0 ]; then
    echo "deploy.sh: HEAD has $FAILED failed check-run(s). Refusing to deploy." >&2
    gh api "repos/{owner}/{repo}/commits/${LOCAL_SHA}/check-runs" \
        --jq '.check_runs[] | select((.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled") and .name != "Dependabot") | "  - \(.name): \(.conclusion)"' >&2
    exit 6
fi

# --- Sanity: are there commits since the last tag? ----------------------

LAST_TAG=$(git describe --tags --abbrev=0 --match='v*.*.*' 2>/dev/null || echo "")
if [ -n "$LAST_TAG" ]; then
    COMMITS_SINCE=$(git rev-list --count "${LAST_TAG}..HEAD")
    if [ "$COMMITS_SINCE" -eq 0 ]; then
        echo "deploy.sh: no commits since $LAST_TAG. Nothing to deploy." >&2
        exit 7
    fi
fi

# --- Check-only: state gates pass, exit without mutating ----------------

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "deploy.sh: state gates OK (on main, clean, in-sync, checks green, ${COMMITS_SINCE:-?} commits since ${LAST_TAG:-no-tag})" >&2
    exit 0
fi

# --- Bump ----------------------------------------------------------------
# Detect project type and bump version in the appropriate manifest.
# Node:   package.json — use `npm version` (handles package-lock.json too).
# Python: pyproject.toml — sed-rewrite the `version = "X.Y.Z"` line. uv.lock
#         is regenerated by `uv sync` post-deploy if the consumer uses uv;
#         we don't try to do that in-script (varies by tool: uv/poetry/pip).
#
# Refuses if BOTH manifests are present without explicit disambiguation —
# polyglot repos need a per-project override (not in scope here).

if [ -f "package.json" ] && [ -f "pyproject.toml" ]; then
    echo "deploy.sh: both package.json and pyproject.toml present — polyglot repo not supported." >&2
    echo "  Remove one or open a kit issue to add a per-project manifest selector." >&2
    exit 10
fi

if [ -f "package.json" ]; then
    # Do NOT parse npm's stdout for the version. `npm version` runs the project's
    # `version` lifecycle script, whose output lands on stdout ahead of the version
    # itself — a project that syncs a sibling manifest or rebuilds an artifact there
    # will bury it. Read the manifest back instead; it is the source of truth anyway.
    # (The previous form also used `tr -d 'v'`, which deletes EVERY v — turning
    # "version" into "ersion" and any package name containing a v into nonsense.)
    if ! npm version "$LEVEL" --no-git-tag-version --allow-same-version >/dev/null; then
        echo "deploy.sh: npm version $LEVEL failed" >&2
        exit 10
    fi
    NEW=$(jq -r '.version' package.json) || {
        echo "deploy.sh: could not read version back from package.json" >&2
        exit 10
    }
    PROJECT_TYPE="node"
elif [ -f "pyproject.toml" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
        echo "deploy.sh: python3 required to bump pyproject.toml" >&2
        exit 9
    fi
    NEW=$(python3 - "$LEVEL" <<'PYEOF'
import sys, re, pathlib
level = sys.argv[1]
path = pathlib.Path("pyproject.toml")
text = path.read_text()
m = re.search(r'^(version\s*=\s*")(\d+)\.(\d+)\.(\d+)(")', text, re.MULTILINE)
if not m:
    sys.exit("cannot find `version = \"X.Y.Z\"` line in pyproject.toml")
prefix, major, minor, patch, suffix = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)), m.group(5)
if level == "major":   major, minor, patch = major + 1, 0, 0
elif level == "minor": minor, patch = minor + 1, 0
elif level == "patch": patch = patch + 1
else: sys.exit(f"invalid level: {level}")
new = f"{major}.{minor}.{patch}"
new_text = text[:m.start()] + f'{prefix}{new}{suffix}' + text[m.end():]
path.write_text(new_text)
print(new)
PYEOF
) || {
        echo "deploy.sh: pyproject.toml version bump failed: $NEW" >&2
        exit 10
    }
    PROJECT_TYPE="python"
else
    echo "deploy.sh: neither package.json nor pyproject.toml found — cannot determine version manifest." >&2
    exit 10
fi
echo "deploy.sh: bumped to $NEW ($PROJECT_TYPE)" >&2

# --- Apply changelog ----------------------------------------------------

TODAY=$(date "+%B %-d, %Y")
HEADER="### $TODAY"

CHANGELOG_PATH="changelog.md"
[ -f "CHANGELOG.md" ] && [ ! -f "changelog.md" ] && CHANGELOG_PATH="CHANGELOG.md"

if [ ! -f "$CHANGELOG_PATH" ]; then
    echo "deploy.sh: $CHANGELOG_PATH not found; creating." >&2
    printf '# Changelog\n\nAll notable changes to this project will be documented in this file.\n\n' > "$CHANGELOG_PATH"
fi

if grep -qF "$HEADER" "$CHANGELOG_PATH"; then
    # Header exists — insert entry under it.
    # Read entry via getline (file path), not -v entry= (string). BSD awk on
    # macOS rejects newlines in -v values; gawk on Linux does not. See
    # bash-rules §V.
    awk -v hdr="$HEADER" -v entry_file="$CHANGELOG_FILE" '
        BEGIN {
            entry = ""
            while ((getline line < entry_file) > 0) {
                entry = entry (entry == "" ? "" : "\n") line
            }
            close(entry_file)
        }
        $0 == hdr { print; print ""; print entry; next }
        { print }
    ' "$CHANGELOG_PATH" > "${CHANGELOG_PATH}.tmp"
else
    # New header — insert at top after the file preamble (line 4 in canonical).
    # Same getline pattern as above (BSD awk -v newline trap).
    awk -v hdr="$HEADER" -v entry_file="$CHANGELOG_FILE" '
        BEGIN {
            entry = ""
            while ((getline line < entry_file) > 0) {
                entry = entry (entry == "" ? "" : "\n") line
            }
            close(entry_file)
        }
        NR==4 && !inserted { print; print ""; print hdr; print ""; print entry; inserted=1; next }
        { print }
        END { if (!inserted) { print ""; print hdr; print ""; print entry } }
    ' "$CHANGELOG_PATH" > "${CHANGELOG_PATH}.tmp"
fi
mv "${CHANGELOG_PATH}.tmp" "$CHANGELOG_PATH"

# --- Commit bump + changelog directly on main ---------------------------
# No branch protection (pipeline.md §1.1): main requires no PR and accepts
# direct pushes, so the release bump lands STRAIGHT on main — no release branch, no PR, no
# admin-merge. The state gates above already guarantee local main ==
# origin/main, so this push is a clean fast-forward. The bump commit + the
# tag ARE the release record (main's history is the trail). This reuses the
# same direct-to-main mechanism as /ship-main.

if [ "$PROJECT_TYPE" = "node" ]; then
    git add package.json
    [ -f package-lock.json ] && git add package-lock.json
else
    git add pyproject.toml
    [ -f uv.lock ] && git add uv.lock 2>/dev/null || true
    [ -f poetry.lock ] && git add poetry.lock 2>/dev/null || true
fi
git add "$CHANGELOG_PATH"
git commit --no-verify -m "🚀 release: v${NEW}" >&2

if ! git push origin main; then
    echo "deploy.sh: push of the release commit to main failed." >&2
    echo "  Likely origin/main advanced since the state gate, OR main still requires a PR." >&2
    echo "  Fix: git pull --ff-only origin main (then re-run /deploy), or turn require-PR off (pipeline.md §1.1)." >&2
    exit 11
fi

NEW_SHA=$(git rev-parse HEAD)
echo "deploy.sh: release commit v${NEW} pushed to main at ${NEW_SHA:0:8}" >&2

# --- Tag + push tag -----------------------------------------------------

git tag "v${NEW}" "$NEW_SHA"
if ! git push origin "v${NEW}"; then
    echo "deploy.sh: tag push failed" >&2
    exit 17
fi
echo "deploy.sh: tagged v${NEW} at ${NEW_SHA:0:8}" >&2

# --- Move shipped issues to the deploy status on the project board ------
# Tag is pushed = point of no return for this release. Enumerate every
# issue named by a closing keyword in this release window (commits between
# the prior tag and this one) and move it to GITFLOW_STATUS_DEPLOYED_ID —
# whatever the project calls that column. Source: squash-merge commit bodies,
# which merge.sh sets to the PR body whatever the repository's squash setting —
# and the PR body carries the `Closes #N` line /open-pr writes — and
# /ship-main writes the same line for the issues it marked complete. Whether
# the issue is CLOSED is GitHub configuration, not this script's: the
# repository's auto-close setting and the board's "Auto-close issue"
# workflow (github-project-board-setup.md).
#
# Recognize the full set of GitHub closure keywords (close[sd]?, fix(es|ed)?,
# resolve[sd]?) so consumer PRs that use any of them are caught.
#
# Helper is fail-loud: if PROJECT_ID is set but DEPLOYED_ID is empty or the
# board misconfigured or scope missing, the script exits non-zero AFTER
# tag push — release artifact is already tagged, recovery is to fix the
# cause and re-invoke /deploy (which exits at the "no commits since tag"
# gate, leaving you to invoke the transition manually or re-run after
# adding the next bump's commits).
# Resolve the git-log range first, then run the extraction pipeline once.
# Earlier versions duplicated the pipeline across the if/else branches; if
# the regex ever drifts between branches the bug is silent (only first-
# release deploys miss closures, or vice versa).
if [ -n "$LAST_TAG" ]; then
    LOG_RANGE="${LAST_TAG}..HEAD"
else
    # No prior tag — first release. Walk every commit reachable from HEAD.
    LOG_RANGE="HEAD"
fi

# First regex matches the full closure clause including comma-separated
# continuations (e.g. "Closes #1, #2, #3"). The trailing `(,[[:space:]]*#N)*`
# group is what catches the additional issue numbers — without it, only the
# first #N would be captured and downstream #N's silently dropped from the
# board transition. Second grep extracts every #N from the captured clause.
CLOSED_ISSUES=$(git log "$LOG_RANGE" --pretty=%B \
    | grep -ohiE '(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*' \
    | grep -oE '#[0-9]+' \
    | grep -oE '[0-9]+' \
    | sort -u)

if [ -n "$CLOSED_ISSUES" ]; then
    # Check whether board integration is on before announcing — if PROJECT_ID
    # is empty, move_issue_to_deployed silently no-ops, and announcing the
    # transition would look like a hang. load_gitflow_project_config sourced
    # via issue_helpers.sh.
    load_gitflow_project_config
    if [ -n "${GITFLOW_PROJECT_ID:-}" ]; then
        echo "deploy.sh: moving shipped issues to the deploy status on the project board: $(echo "$CLOSED_ISSUES" | tr '\n' ' ')" >&2
        for num in $CLOSED_ISSUES; do
            move_issue_to_deployed "$num"
        done
    fi
fi

# --- Step 10: Run database migration first (gated) ----------------------
# Migration is deploy's first phase: it runs once, before any app deploy, and
# must fully succeed before app code that depends on the new schema ships.
# ALWAYS watched to completion regardless of --no-watch (--no-watch only
# governs the app-deploy watch below); shipping app images against a failed or
# half-applied migration is precisely the failure mode this gate prevents.
#
# No-op semantics are the migrate workflow BODY's responsibility: it MUST exit
# 0 when there are no pending migrations and non-zero only on a genuine error
# (drizzle-kit can emit error-shaped output on a clean no-op — the workflow
# traps that and exits 0). The orchestrator here gates purely on the run's
# conclusion as reported by `gh run watch --exit-status`.
if [ -n "$MIGRATE_WF" ]; then
    # Skip the migration workflow when no migration files changed since the last
    # deploy. Firing it costs ~2 min of runner boot + `npm ci` just to reach a
    # drizzle-kit no-op; when MIGRATE_PATHS is configured and nothing under it
    # changed since LAST_TAG, that entire cost is avoidable.
    #
    # The reference is LAST_TAG — the PREVIOUS deploy's tag, captured at the
    # state-gate ("commits since last tag") BEFORE this run created its own tag.
    # A fresh `git describe` here would return THIS run's just-pushed tag and the
    # diff would be empty EVERY time → always-skip. Never recompute it here.
    #
    # Forced-run guards (no skip): MIGRATE_PATHS empty (deploy.sh can't know what
    # a migration file is → run, preserving prior behavior) or LAST_TAG empty
    # (first-ever deploy → no baseline → run). A migration that failed on a prior
    # deploy is unaffected: that deploy's tag exists, so re-running /deploy hits
    # the "no commits since tag" gate and stops — the operator's documented manual
    # recovery applies the migration, and the migration workflow stays idempotent
    # as the backstop. See handbook §6.5.
    SKIP_MIGRATE=0
    if [ -n "$MIGRATE_PATHS" ] && [ -n "$LAST_TAG" ]; then
        # shellcheck disable=SC2086 # intentional word-splitting: MIGRATE_PATHS is a space-separated pathspec list
        if ! MIG_CHANGED=$(git diff --name-only "${LAST_TAG}..HEAD" -- $MIGRATE_PATHS 2>&1); then
            echo "deploy.sh: git diff for the migration-path skip check failed — refusing to guess (fail-loud, §X):" >&2
            printf '  %s\n' "$MIG_CHANGED" >&2
            exit 20
        fi
        [ -z "$MIG_CHANGED" ] && SKIP_MIGRATE=1
    fi

    if [ "$SKIP_MIGRATE" -eq 1 ]; then
        echo "deploy.sh: no migration files changed under [$MIGRATE_PATHS] since $LAST_TAG — skipping $MIGRATE_WF (nothing to apply)." >&2
    elif [ "$DEPLOY_BACKEND" = "codebuild" ]; then
        MIG_PROJECT="${CODEBUILD_MIGRATE_PROJECT:-$(cb_project_for "$MIGRATE_WF")}"
        MIG_BUILD_ID=""
        cb_start "$MIG_PROJECT" >/tmp/cb_mig_id.$$ 2>/tmp/cb_mig_err.$$ && MIG_BUILD_ID=$(cat /tmp/cb_mig_id.$$)
        [ -s /tmp/cb_mig_err.$$ ] && sed 's/^/deploy.sh:   aws: /' /tmp/cb_mig_err.$$ >&2
        rm -f /tmp/cb_mig_id.$$ /tmp/cb_mig_err.$$
        if [ -z "$MIG_BUILD_ID" ] || [ "$MIG_BUILD_ID" = "None" ]; then
            echo "deploy.sh: could not start CodeBuild project $MIG_PROJECT (migration)" >&2
            exit 18
        fi
        echo "deploy.sh: started migration $MIG_PROJECT ($MIG_BUILD_ID); waiting before deploying..." >&2
        MIG_RESULT=$(cb_wait "$MIG_BUILD_ID") || exit 19
        MIG_STATUS=$(printf '%s\n' "$MIG_RESULT" | awk '{print $2}')
        if [ "$MIG_STATUS" != "SUCCEEDED" ]; then
            echo "deploy.sh: migration $MIG_PROJECT finished $MIG_STATUS — aborting before any app deploy" >&2
            exit 19
        fi
        echo "deploy.sh: migration $MIG_PROJECT succeeded; proceeding to app deploy(s)" >&2
    else
        if ! gh workflow run "$MIGRATE_WF" --ref main >&2; then
            echo "deploy.sh: gh workflow run $MIGRATE_WF (migration) failed to trigger" >&2
            exit 18
        fi
        echo "deploy.sh: triggered migration $MIGRATE_WF on main; waiting for it to finish before deploying..." >&2
        sleep 3
        MIG_RUN_ID=$(gh run list --workflow="$MIGRATE_WF" --branch=main --limit=1 --json databaseId --jq '.[0].databaseId')
        if [ -z "$MIG_RUN_ID" ]; then
            echo "deploy.sh: could not resolve a run id for migration $MIGRATE_WF — refusing to deploy against an unverified migration (fail-loud, §X)" >&2
            exit 19
        fi
        echo "deploy.sh: watching migration $MIGRATE_WF run $MIG_RUN_ID..." >&2
        if ! gh run watch "$MIG_RUN_ID" --exit-status; then
            echo "deploy.sh: migration run $MIG_RUN_ID ($MIGRATE_WF) failed — aborting before any app deploy" >&2
            exit 19
        fi
        echo "deploy.sh: migration $MIGRATE_WF succeeded; proceeding to app deploy(s)" >&2
    fi
fi

# --- Step 11: Trigger deploy workflow(s) --------------------------------

if [ ${#WORKFLOWS[@]} -eq 0 ]; then
    # Migrate-only deploy (MIGRATE_WORKFLOW set, no DEPLOY_WORKFLOWS): a repo
    # that maintains a database but ships no app artifact. The migration above
    # WAS the deploy — nothing further to trigger.
    echo "deploy.sh: v${NEW} — migration-only deploy (no app workflows configured)." >&2
elif [ "$DEPLOY_BACKEND" = "codebuild" ]; then
    # Fire the whole fleet, THEN poll it together. The github branch below
    # watches each run to completion in turn, which costs the sum of every
    # service; this costs the slowest one.
    CB_IDS=""
    for WF in "${WORKFLOWS[@]}"; do
        PROJECT=$(cb_project_for "$WF")
        BUILD_ID=""
        cb_start "$PROJECT" >/tmp/cb_id.$$ 2>/tmp/cb_err.$$ && BUILD_ID=$(cat /tmp/cb_id.$$)
        [ -s /tmp/cb_err.$$ ] && sed 's/^/deploy.sh:   aws: /' /tmp/cb_err.$$ >&2
        rm -f /tmp/cb_id.$$ /tmp/cb_err.$$
        if [ -z "$BUILD_ID" ] || [ "$BUILD_ID" = "None" ]; then
            echo "deploy.sh: could not start CodeBuild project $PROJECT" >&2
            exit 12
        fi
        CB_IDS="$CB_IDS $BUILD_ID"
        echo "deploy.sh: started $PROJECT ($BUILD_ID)" >&2
    done

    if [ "$WATCH" -eq 1 ]; then
        echo "deploy.sh: waiting on ${#WORKFLOWS[@]} build(s)..." >&2
        # shellcheck disable=SC2086 # intentional word-splitting on the id list
        CB_RESULT=$(cb_wait $CB_IDS) || exit 13
        printf '%s\n' "$CB_RESULT" | while read -r _id _status; do
            echo "deploy.sh:   $_id $_status" >&2
        done
        # A single non-SUCCEEDED build fails the release. Every id is reported
        # above first, so one broken service does not hide the others' state.
        if printf '%s\n' "$CB_RESULT" | awk '{print $2}' | grep -qv '^SUCCEEDED$'; then
            echo "deploy.sh: at least one deploy build did not succeed" >&2
            exit 13
        fi
        echo "deploy.sh: v${NEW} deployed across ${#WORKFLOWS[@]} project(s)." >&2
    fi
else
    for WF in "${WORKFLOWS[@]}"; do
        if ! gh workflow run "$WF" --ref main >&2; then
            echo "deploy.sh: gh workflow run $WF failed" >&2
            exit 12
        fi
        echo "deploy.sh: triggered $WF on main" >&2
    done

    # Watch the most recent run of each workflow
    if [ "$WATCH" -eq 1 ]; then
        sleep 3
        for WF in "${WORKFLOWS[@]}"; do
            RUN_ID=$(gh run list --workflow="$WF" --branch=main --limit=1 --json databaseId --jq '.[0].databaseId')
            if [ -n "$RUN_ID" ]; then
                echo "deploy.sh: watching $WF run $RUN_ID..." >&2
                gh run watch "$RUN_ID" --exit-status || {
                    echo "deploy.sh: deploy run $RUN_ID ($WF) failed" >&2
                    exit 13
                }
            fi
        done
        echo "deploy.sh: v${NEW} deployed across ${#WORKFLOWS[@]} workflow(s)." >&2
    fi
fi
