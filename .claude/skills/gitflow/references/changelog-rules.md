# Changelog Rules

## Public-Facing Document

**Changelogs are always public-facing.** Write every entry as if a customer, end user, or non-technical stakeholder will read it.

| Forbidden | Why | Write Instead |
|-----------|-----|---------------|
| Technical jargon (API routes, function names, internal modules) | Meaningless to users | Describe the user-visible outcome |
| Infrastructure details (server config, deployment pipeline, CI changes) | Exposes internals | Omit entirely or describe the user benefit |
| Security-sensitive info (auth mechanisms, vulnerability details, secret names) | Security risk | Generic description ("improved security") |
| Internal file paths, database table names, schema changes | Implementation detail | Describe what changed for the user |

**Rule of thumb**: If an entry only makes sense to someone reading the source code, it doesn't belong in the changelog.

## What Goes in Changelog

**INCLUDE** (user-facing impact):
- ✨ feat: New features, capabilities, UI additions
- 🐛 fix: Bug fixes that affected users
- ⚡ perf: Performance improvements users would notice
- 💥 BREAKING: Any breaking changes

**EXCLUDE** (internal/dev only):
- ♻️ refactor: Code restructuring without behavior change
- 🎨 style: Formatting, whitespace, naming
- 🧪 test: Test additions/changes
- 📚 docs: Documentation changes
- 🔧 chore: Build, deps, tooling (unless user-facing)

## Entry Format

```
- **✨ Feature Name** - Brief user-visible description of what it does
- **🐛 Fix Issue** - What was broken and now works
```

## Section Header Format

Entries group under a date header:

```markdown
### April 16, 2026

- **✨ Feature A** - Description
- **🐛 Fix B** - Description
```

Today's header already exists when multiple PRs merge in one day — append entries underneath it. New date headers sort most-recent-first.

## Multiple Features in One PR

When a PR includes multiple distinct user-facing changes, list ALL in the changelog entry:

```
- **✨ Feature A** - Description
- **✨ Feature B** - Description
- **🐛 Fix C** - Description
```

## Who writes the changelog

`/deploy` is the only writer. Claude composes the consolidated release entry locally during `/deploy` from commit subjects since the last `v*.*.*` tag, applying this file to filter and rewrite them. `deploy.sh` inserts that entry under today's date header as part of the bump commit.

Feature-PR scripts (`commit.sh`, `open-pr.sh`, `merge.sh`) never touch `changelog.md`. A single writer is what keeps duplicate bullets from landing under one date header.

One release entry covers every commit since the last tag — typically several merged PRs grouped together.
