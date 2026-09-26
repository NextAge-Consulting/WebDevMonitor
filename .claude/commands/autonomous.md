# /autonomous

Enter autonomous mode for a body of work. `rules/autonomous-sessions.md` defines the mode — read it before running this command.

$ARGUMENTS

## Supported invocations

The argument is natural language naming the body of work. Any phrasing is valid; these are the shapes it arrives in.

| Input | Where scope comes from |
|-------|------------------------|
| `/autonomous execute plan @project-documentation/temporary/foo-plan.md` | The named plan file. |
| `/autonomous I'm stepping away — finish what you can of what we've been discussing` | The work agreed in this conversation. |
| `/autonomous fix the failing integration tests and open a PR` | The argument itself. |

## Procedure

### Step 1: Resolve scope

Decide which shape the argument is and derive the body of work. Where it is ambiguous, take the widest reading the argument supports, state that reading, and proceed. Never ask — the human has left.

### Step 2: Get the scope into a plan document

A plan file was named, or one already exists for this work: use it.

Otherwise write one at `project-documentation/temporary/<slug>-plan.md` enumerating the deliverables. One deliverable per entry — a line joining two artifacts with "and" is two entries.

### Step 3: Stamp the mode into that document

Insert immediately below the plan's title:

```markdown
> **Autonomous run — YYYY-MM-DD.** Entered via `/autonomous`. No check-ins until the final report; see `.claude/rules/autonomous-sessions.md`.
```

Substitute today's date from `date +%F`. This line is what survives compaction; the conversation sentence that set the mode does not.

### Step 4: Restate and run

State the deliverable list back in one pass, then work it to completion. No check-in, no confirmation of approach, no offer of a choice you could make yourself.

A blocker stops that deliverable, not the turn: record it in the plan document, move to the next item that does not depend on it.

Run `/checkpoint` as each deliverable finishes. The mode authorizes that and no other git operation — no commit, PR, merge, ship or deploy.

### Step 5: Finish

Delete the stamp line from the plan document.

Then run `/handoff`. It sweeps the temporary folder — promoting the durable content of a spent plan present-tense and deleting the plan file, per `rules/development-guidelines.md` — and writes the handoff for the next session. Do not do that work inline here; one owner, one procedure.

Then produce the final report per `rules/autonomous-sessions.md`: what was completed, what was verified and with which commands, every blocker together, every assumption taken. Derive the list from the plan document deliverable by deliverable.

The report and the handoff are not the same artifact. The report is the account of this run, delivered in the conversation. The handoff is the next session's starting context, on disk, where compaction cannot reach it.

## Blocking conditions

- `$ARGUMENTS` is empty — there is no body of work to resolve. Ask what to work on.
- A named plan file does not exist at the given path.

## Related

- `rules/autonomous-sessions.md` — the definition of the mode. This command enters it; the rule governs it.
- `rules/testing-verification.md` — in this mode you verify your own work rather than handing off.
- `/handoff` — invoked at Step 5 to sweep the temporary folder and write the next session's context.
