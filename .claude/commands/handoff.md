# /handoff

Write the session handoff at `project-documentation/temporary/handoff.md`, and sweep the temporary folder while you are there.

This command only WRITES. The next session's `/work` reads the file — there is no read mode here.

$ARGUMENTS

## What the document is

One page, written for the next session's AI. It is **rewritten in full every time** — never appended to, never a running log, never a changelog. The human gets a TLDR in the conversation and can open the file if they want more.

It carries no git state and no machine state.

**No git state** — no branch name, no file counts, no last commit. That information is stale the moment the next `/commit` runs, and `git log` / `git status` give it back for free.

**No machine state** — no port numbers, no process ids, no "the server is hung", no "nothing is listening on that port". A handoff is about the WORK, not about the machine the work was last run on. Servers get started, killed and restarted between sessions, so a handoff opening with a wedged process sends the next session chasing a condition that no longer exists — and the reader trusts it, because it is written in the same voice as the parts that are real.

The test for both: **if the next session can get the answer by running one command, it does not go in the document.** Say what needs doing and what it needs in order to run; never what the machine happened to be doing when the last session stopped.

## Procedure

### Step 1: Read the outgoing handoff

Before writing anything, read the existing `project-documentation/temporary/handoff.md` if there is one. Every open item in it gets classified in Step 3.

**Building the new document blind to the old one is the failure this command exists to prevent.** A session that worked three of four outstanding items must not drop the fourth by never mentioning it.

### Step 2: Sweep the temporary folder

List every file in `project-documentation/temporary/`. For each one other than `handoff.md`, decide spent or live:

- **Spent** — the work it describes has landed. Follow `rules/development-guidelines.md`: write the durable facts present-tense into the right permanent doc under `project-documentation/`, then delete the file. Not everything needs promoting; a fact the code states plainly needs no doc. Never write what something *was*, what replaced it, or that it was removed (constitution §XV).
- **Live** — leave it. If its own state header no longer matches what actually happened, correct the header.

The outgoing handoff from Step 1 gets the same treatment before it is overwritten. It is the file most likely to hold a durable fact that was never written down anywhere else.

`handoff.md` itself is never swept and never retired. It lives in `temporary/` permanently and is replaced each session.

A `discussion-<slug>/` folder is live until `/work --discussion` pulls it back — the analysis skill wrote it, and it is waiting on other people's comments. Never sweep one.

### Step 3: Classify every open item from the outgoing handoff

Three resolutions. There is no fourth, and silence is not one of them.

| Resolution | Requires | Carry-over |
|---|---|---|
| **Done** | Evidence from this session — the work happened, or it is visible in the tree. Not "it looks finished." | None. Documented per Step 2 where durable. |
| **Carried** | Nothing. This is the default. | The item, with any completed portion recorded and the remainder stated as what is left. |
| **Dropped** | A stated reason — superseded by X, overtaken, no longer wanted. If you cannot justify it in a clause, you cannot drop it. | None. |

**An item carried unchanged into a third consecutive handoff gets flagged IN THE DOCUMENT**, as `open since <date>, unmoved across N handoffs`. `/work` reads it at the start of the next session and raises it there, when there is a session to spend on the answer.

**Never put the question in the TLDR.** The human is shutting down — that is the worst moment to ask them anything, and an answer given while closing the laptop is a rushed one. The handoff's job is to carry the question to the START of the next session, not to interrogate at the end of this one.

**First check the item is a question at all.** If the human could not answer it off the top of their head, it is misclassified, and re-asking will not fix it:

| It is really… | Tell |
|---|---|
| A **settled default** | The item already says "default applied: X". That is a decision, not an open question. State it as settled and stop carrying it. |
| **Unfinished investigation** | The answer is in the code, the schema or the legacy source — nobody's preference. It belongs under Next steps as work, not under Open questions. |
| A **genuine question** | It needs a preference, a priority call, or an authorization. Only these are carried as questions. |

Applying that test is the real trimming pressure. A backlog of questions nobody can answer is what makes the document stop being read.

### Step 4: Write the file

Replace `project-documentation/temporary/handoff.md` entirely.

Three sections are mandatory — the date stamp, what happened, and the document index. Everything else is present only when it has real content.

```markdown
# Handoff — YYYY-MM-DD

*Written YYYY-MM-DD HH:MM Area/City (ABBR, UTC±HHMM) · YYYY-MM-DD HH:MM UTC*

## What happened last session

<Prose. What was done and where it landed. Not a commit list.>

## Open questions

<Each marked blocking or not. If not blocking, name the default already applied.>

## Next steps

<The first concrete action, not a backlog.>

## Blockers

<Each with exactly what unblocks it, and who holds it.>

## Assumptions taken

<Anything decided without asking, so a wrong one is a one-line correction.>

## Documents, and when to read them

| Document | Read it when |
|---|---|
| `<path>` | `<the situation that sends you there>` |
```

**Stamp both zones, and name the local one.** A handoff written in one timezone and
compared against a git log in another reads as a gap that is not there. The local zone
also cannot be inferred — not from the project's language, not from the client's country,
not from the codebase. So the H1 carries the local date for reading, and the line beneath
it carries the full local time with its IANA zone name alongside the same instant in UTC.
A human compares against the local stamp; anything comparing against git, GitHub or CI
compares against the UTC one.

Generate the whole header rather than hand-typing any part of it:

```bash
TZNAME=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||'); TZNAME=${TZNAME:-${TZ:-unknown}}
printf '# Handoff — %s\n\n*Written %s %s (%s) · %s*\n' \
  "$(date +%F)" "$(date +'%F %H:%M')" "$TZNAME" "$(date +'%Z, UTC%z')" "$(date -u +'%F %H:%M UTC')"
```

**Never manufacture content to fill a heading.** A session can finish its work with nothing outstanding, and that is a complete handoff: a date, a paragraph on what was done, and the index. If there are no blockers, the Blockers heading is absent — not present and empty. An invented next step is worse than a missing section, because the next session will act on it.

**An open item is one the HUMAN acknowledged during the session. Nothing else qualifies.** Two things are not open items, and both keep reaching handoffs because they wear the clothes of diligence:

- **A decision already settled.** Record it once, where the decision lives, and stop. Re-raising it as "may need revisiting" reopens it every session — the next `/work` hands the human back a question they already answered, and answering it again is the only way to make it go away.
- **A guess about what the human did or did not verify.** You cannot observe their testing and nobody asked you to track it. "This has not been exercised" is speculation typed as a gap.

A session with one real open item writes one. Padding to three spends the human's attention on invented work and costs the trust that any of the three is real.

The index is the highest-value section. The handoff points at the durable docs rather than restating them; that is what keeps it from decaying into a history.

### Step 5: TLDR to the human

A few lines: what the document now says, what the sweep promoted and deleted, and any item flagged as unmoved. Not a recital of the file.

**State, never ask.** `/handoff` is a shutdown command, so the TLDR ends the session — it does not open a conversation. An unmoved item is reported as a fact ("`packages/web` is unmoved across three handoffs; `/work` will raise it next session"), never as a question. If a question genuinely needed asking, the moment for it was during the work.

## Blocking conditions

- No `project-documentation/` directory — this project has not adopted the convention. Say so rather than creating one silently.

## Related

- `rules/development-guidelines.md` — where documents live, and the rule that a spent plan is rewritten present-tense and deleted.
- `constitution.md` §XV — present-tense documentation.
- `/work` — reads this file at session start.
- `/autonomous` — ends by running this command.
