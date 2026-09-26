# Development Guidelines

Critical rules in `constitution.md`. Language-specific patterns in `typescript-rules.md` and `python-rules.md`, auto-loaded via path targeting.

## Documentation

Location, first match wins:

1. An explicit instruction in the prompt.
2. The predefined home for a special file — `changelog.md`, `README.md`, `CLAUDE.md`.
3. `project-documentation/temporary` for a disposable document.
4. `project-documentation` for a permanent one.

Within that, follow the existing file structure and style, and check existing subfolders for a suitable location.

**Plans are temporary, with no exceptions.** A plan file goes in `project-documentation/temporary` and nowhere else. When the work is done, replace it: write the permanent doc in the present tense describing what now exists, file it under `project-documentation`, and delete the plan file. Git holds the history.

**`temporary/handoff.md` is the one permanent resident of that folder.** It is the session handoff — rewritten in full by `/handoff` at the end of a session and read by `/work` at the start of the next. It is replaced, never retired, and never swept as a spent plan. A `discussion-<slug>/` folder is likewise never swept: it is removed by the `/work --discussion` pull-back that consumes it.

Docs describe current state only. Scrub removed things to zero — never a "was deleted" or "this replaced" note (constitution §XV).

## Environment configuration

Check for existing `.env` files before creating one. Read current values first and add only new variables.

## Database query access

For read-only queries and exports, use psql directly:

```bash
DATABASE_URL=$(grep "^DATABASE_URL=" .env | cut -d'=' -f2- | cut -d'#' -f1 | xargs)
psql "$DATABASE_URL" -c "SELECT * FROM tablename;"
```

## Code health

Run language diagnostics before claiming work done — LSP is primary, see constitution §IX. Check for indirect usage before deleting code flagged as unused.
