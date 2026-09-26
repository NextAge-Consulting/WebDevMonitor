# Dependency & Vulnerability Policy

> Kit starting point — **this project owns this file from here.** The timelines
> table is the dial: tune it to this client's risk appetite. Nothing else needs to
> change when you do.

The doctrine behind this pass — one version per shared dependency, one shared build
config, the verification standard, how a security residual is accepted — lives in the
kit's `project-documentation/dependency-management.md`. Read it there; it is
deliberately not copied into consumer projects, so there is one copy to keep true.
This file holds only what that document cannot know about a given project: its
owners, its timelines, and the project-specific facts a maintainer adds below.

## Who owns this

| | |
|---|---|
| Runs the weekly pass | *(name)* |
| Approves an exception | *(name)* |
| Escalate to | *(name)* |

## Timelines

How long a known issue may remain unresolved, from the day it appears.

| Severity | Act within | If it can't be met |
|---|---|---|
| Critical | 7 days | Escalate immediately — do not let it lapse silently |
| High | 14 days | Record an exception |
| Medium | 30 days | Record an exception |
| Low | Next routine pass | — |
| No fix published | Record within 7 days | Review every 90 days until fixed |

## Exceptions

An issue that can't be resolved inside its window is written down, not forgotten.
Record it where this project tracks work, with: what it is, why it can't be fixed
now, who approved it, and **the date it gets looked at again**. An exception with no
review date is not an exception.

## The weekly pass

Run it weekly. It takes minutes when there's nothing to do, and doing it on a fixed
day is what makes it happen at all. Nothing enforces this.

Ask Claude to **"dependency triage"** — the `dependency-triage` skill walks the steps
below, explains what each change is, and recommends a decision. Do not merge
dependency PRs without going through it.

**1. Routine updates** — leaf libraries, dev dependencies, patch bumps.
Green CI plus the cooldown that already elapsed is sufficient. Merge them.

**2. Build-graph updates** — the bundler, framework, router, server adapter.
Never merge on CI alone: CI does not build the app. Build locally and click through
the app before merging. Expect these to occasionally cost hours. If it turns into a
fight, stop and escalate rather than forcing it through — a half-migrated build graph
is worse than a stale one.

**3. Security fixes** — treat these as *less* soaked, not more urgent to merge blind.
Security PRs skip the cooldown that protects routine updates, so they can arrive the
same day a version publishes. Read what changed before merging.

**4. Nothing to fix** — an advisory in a package you don't control, with no patched
version. You cannot fix these by bumping them; the fix comes from whatever pulls them
in. Record an exception with a review date and move on.

**5. Node LTS** — the pass also checks whether Node's Active LTS has moved past what
the Dockerfiles and CI pin. Almost always nothing. When it has moved, that's planned
work, not a merge.

## When to stop and escalate

- A critical issue can't be resolved inside its window.
- A build-graph update breaks the app and the fix isn't obvious within an hour.
- An advisory affects something handling customer data and you can't tell whether
  it's exploitable here.
- You don't understand what a change does. That is a legitimate reason to stop —
  merging it anyway is the failure this document exists to prevent.
