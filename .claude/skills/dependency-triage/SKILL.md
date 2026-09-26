---
name: dependency-triage
description: The weekly dependency and vulnerability pass for kit-pipeline projects — clear dependency PRs by blast-radius tier, handle security advisories including ones with no fix, and check Node LTS, without re-deciding from scratch each time. Executes the procedure in project-documentation/dependency-policy.md. Assumes the kit pipeline (gitflow + /deploy + CI-does-NOT-build). Use when the user asks to "triage dependabot", "dependency triage", "clear the dependabot PRs", "do the weekly dependency cleanup", "weekly deps", "check vulnerabilities", or works through open Dependabot PRs or security advisories. Triggers: "triage dependabot", "dependency triage", "weekly deps", "clear dep PRs", "check advisories".
allowed-tools: Bash(gh:*), Bash(git pull:*), Bash(git status:*), Bash(git log:*), Bash(git fetch:*), Bash(npm:*), Bash(docker:*), Bash(lsof:*), Bash(curl:*), Bash(jq:*), Bash(grep:*), Read, Glob, Grep
---

# dependency-triage — the weekly dependency + vulnerability pass

The repeatable process for clearing dependency PRs and security advisories without re-deciding from scratch each time. Run ~weekly. Claude does the analysis + verification; **the human authorizes every main-landing merge** (merging a Dependabot PR squashes to `main`).

**Read `project-documentation/dependency-policy.md` first.** It holds this project's timelines, who owns the pass, and where an exception is recorded. This skill executes that policy; it does not define it. If the file is missing, say so — the project has not decided its timelines yet.

**Pipeline assumption.** This skill assumes the project is on the **kit pipeline**: gitflow tooling, `/deploy` as the release boundary, and CI that does **not** build the app. A project that broke from that pipeline owns the subtraction — this skill's gating logic won't fit it (and such projects don't run dependabot triage anyway).

## The one fact that drives everything

**PR-CI does not build the app.** `ci.yml` runs `dep-alignment` + `check-types` + `biome` + `vitest` (+ `semgrep`) — never the production build. The only automated build gate is in `/merge`, and **Dependabot PRs never touch it** — they land via `gh pr merge` (step 3–5 below), not through gitflow. So a dep PR reaches `main` with nothing having built it. So:

- **Green Dependabot CI ≠ build-safe** for anything in the bundler/SSR graph.
- A toolchain bump that breaks the build can merge on green CI and **poisons `main`** — every subsequent `/merge` on any branch then fails its build gate on damage it did not cause, until someone fixes it.
- Therefore: **toolchain bumps get a local prod build + app smoke before merge.** Leaf bumps don't.

## Tiers — triage by blast radius, NOT CI color

| Tier | What | Gate before merge |
|---|---|---|
| **1 — CI/infra** | `github-actions`, `docker` (non-Node), `chore(ci)` | Green CI. Cannot touch the app build. |
| **2 — Leaf libs** | runtime/util libs NOT in the bundler/SSR graph | Green CI (rebase first if stale). |
| **3 — Toolchain** | bundler / React / framework / SSR adapter | Green CI **+ local prod build + app smoke**. One PR at a time, never batched. |

**The Tier-3 set is exactly the `npm-toolchain` group in `.github/dependabot.yml`** (kept separate from `npm-patch` for precisely this reason). **Read that group to know what's Tier 3 in THIS project — do not hardcode a package list.** `postcss` and anything else in the CSS/build pipeline is Tier 3 even if it arrives in a leaf group.

## Weekly procedure

1. **List + status.**
   ```bash
   gh pr list --author "app/dependabot" --state open \
     --json number,title,mergeable --jq '.[] | "#\(.number) \(.mergeable) \(.title)"'
   gh pr view <N> --json statusCheckRollup \
     --jq '.statusCheckRollup[] | select(.conclusion=="FAILURE") | .name'
   ```
   Old PRs failing on `check-types`/`biome` are almost always **stale base, not a broken dep** — rebase before trusting red.

2. **Baseline.** Confirm `main` builds clean first: `git pull --ff-only origin main` then the project's build command (discover it from `package.json` scripts — typically `npm run build --workspaces --if-present`). If main is already red, fix that before touching deps.

3. **Tier 1 — merge on green.** `gh pr merge <N> --squash --delete-branch`.

4. **Tier 2 — rebase → merge green.** `gh pr comment <N> --body "@dependabot rebase"`, then merge when green. No build needed.

5. **Tier 3 — apply to CURRENT MAIN, deploy-image verified, human-authorized.** NEVER test the PR's own branch (it's often weeks stale, missing current files; only the version bump matters, applied onto today's main). On clean main: `npm install <pkg>@<ver>` the target versions (regenerates the lockfile = current-main + bump), then **build + run the real deploy Docker image** and verify in a browser. **Discover the exact build/run commands and ports from the project's `Dockerfile.*` + deploy workflows** — do not assume. Verify the **heaviest / most-divergent app** (and any app whose config diverges, separately). Human authorizes commit+push to main; broken → fix or close.

6. **Close superseded.** When a group PR already contains a package that also has a standalone PR, close the standalone with a note once the group lands.

## Advisories — the other half of the pass

Dependabot PRs cover what CAN be fixed by a version bump. Advisories cover what is
KNOWN to be vulnerable. They overlap but are not the same list, and the gap between
them is where the real risk sits.

```bash
gh api repos/:owner/:repo/dependabot/alerts --jq \
  '.[] | select(.state=="open") |
   "\(.security_advisory.severity)\t\(.dependency.package.name)\t\(.security_vulnerability.first_patched_version.identifier // "NO FIX")"'
```

If that call 403s, read the repo's Security tab in a browser instead — the API is
restricted on org-owned private repos, the web UI is not.

For each open advisory, exactly one of:

- **A patched version exists and a Dependabot PR is already open** — it is not a
  separate piece of work. Handle it as the PR, by tier, above. Do not track it twice.
- **A patched version exists but no PR opened** — usually a transitive dependency.
  Bump the DIRECT dependency that pulls it in, not the transitive one; forcing a
  transitive to a version its parent was not built against is how you destabilise an
  app to fix a finding. `npm why <pkg>` shows what pulls it in.
- **No patched version exists** — nobody can fix this, including us. Record an
  exception per the policy: what it is, why it can't be fixed, who approved it, and
  the date it gets reviewed again. Then move on. An advisory with no fix is not a
  failure to remediate; leaving it unrecorded is.

**Security PRs skip the cooldown.** Dependabot delays version updates (3d patch / 7d
minor / 30d major) to sit out the window where a compromised release gets yanked —
but security updates open immediately. So a security PR has had *less* soak than a
routine one, not more. Read what actually changed before merging it; do not treat
"security" as a reason to merge faster.

## Node LTS — part of every pass

`dependabot.yml` blocks Node major bumps because Dependabot cannot tell an LTS major
from a non-LTS one, so nothing else will ever surface the transition. Two commands —
run them every pass rather than making anyone remember a separate cadence:

```bash
curl -s https://nodejs.org/download/release/index.json | \
  jq -r '[.[] | select(.lts != false)][0].version'
grep -hE '^FROM (public\.ecr\.aws/docker/library/)?node:' Dockerfile.* 2>/dev/null | \
  sed -E 's#^FROM (public\.ecr\.aws/docker/library/)?node:([0-9]+).*#\2#' | sort -u
```

Empty output while `Dockerfile.*` exist means a `FROM` the pattern does not cover — read
the Dockerfiles for the Node major rather than concluding there is none.

Almost every week this matches and there is nothing to do. When it doesn't, that is
planned work — a tracked task, not a merge. Bump the Dockerfile `FROM` and the `node-version:` in
`.github/workflows/*.yml` together, or CI and prod drift apart.

## Verification standard (Tier 3)

"Solid" means **build the real prod image, run it on the app's native port, and complete a real login** — NOT "200 on a route" and NOT "server ready" in the log (crypto/auth often loads lazily per request, so a boot can succeed while every request 500s). Full standard: the kit's **`project-documentation/dependency-management.md` §5**.

## Dependency discipline (read alongside)

- **One version per shared dependency** is CI-gated by `dep-alignment` (`npm run check:deps`). When a shared dep updates, bump it to the same version in every workspace that declares it.
- The deeper discipline — trust-but-verify on old workarounds/pins, solid-version philosophy, accepted-residuals handling — lives in the kit's **`project-documentation/dependency-management.md`**.

## Guardrails

- **Never `/deploy` or `/ship-main` as part of triage** — those are the human's to trigger.
- **Merges land on `main`** — the human authorizes each (or the batch) explicitly.
- **Never merge a Tier-3 PR on green CI alone.** The build gate is the whole point.
- **Never override the Node major ignore rule** in `dependabot.yml`. LTS transitions are handled by the quarterly check above.
- `dependabot.yml` group definitions (the toolchain/leaf split) are kit-standard; cooldown / limits / ignore lists and pattern *extensions* are per-project tunables in its header.
