# Autonomous Sessions

This file is the single definition of "autonomous" for the whole rule set. Other rules that change behaviour when nobody is watching point here.

## Autonomous is one turn

The mode begins when the human declares it and ends when you hand back. It does not persist across the conversation; the next turn is interactive again unless they say otherwise.

Its purpose is to extend that one turn until the work is finished. Every stop ends the turn, and ending the turn ends the mode — a session that halts at twenty minutes to report progress has finished an autonomous run twenty minutes in, with the work undone.

## The mode is asserted, never inferred

A turn is autonomous only when the launch was unattended (cron or scheduled), or the human said so in this conversation — handed over a body of work and stated they are stepping away.

`/autonomous <what to work on>` is how they say so: a plan to execute, work named outright, or continuing what the conversation has been building while they step away.

Everything else is interactive, including a long silence. A background job is not autonomous by virtue of being a background job; the human may be watching it live. Neither is a big task, an agreed plan, or a night-time timestamp.

Guessing wrong is costly both ways. Inferred autonomous when they were watching means they discover the divergence at the end. Inferred interactive when they had left costs every hour until they next look at the screen. If it genuinely matters and the mode was never stated, ask once, early, and proceed interactively until answered.

## Write the mode down

The mode is almost always declared mid-conversation, so nothing structural marks the turn — and a long turn gets summarized, taking the sentence that set the mode with it.

The moment a turn is declared autonomous, write a line into the plan or task document the work runs off: that it is autonomous, and the date. Then continue. A file survives compaction; a conversation does not. `/autonomous` writes that line as part of entering the mode; when the mode is declared in prose instead, write it by hand.

Clear that line as part of handing back. A document still claiming to be autonomous would suppress check-ins the human is waiting for.

If no plan document exists, write one. A body of work big enough to hand off unattended is big enough to write down.

## The shape of the turn

Deliver the whole agreed body of work, handed back ready for testing. `working-discipline.md` governs the rest: goals are fixed, judgment applies only to the how, and being unmonitored tightens the instructions.

**There is no check-in.** Do not stop to say a phase is done, to confirm the approach, to ask whether to continue, or to offer a choice you could make yourself. Narration in passing is fine; narration that ends the turn is the failure.

**A blocker stops that work, not the turn.** Record what is blocked and what you need, move to the next item that does not depend on it, and do every other piece of work in full. Present all blockers together in the final report — three surfaced one at a time cost three human round trips, hours apart.

Blocked means work cannot proceed under any assumption: a missing credential, an access you cannot grant, a decision where guessing wrong would be unsafe or waste the work. Where a reasonable default exists, take it, write down the assumption, and keep working.

**Checkpoint as you go.** Entering the mode authorizes `/checkpoint` for the length of the turn. Run it as each deliverable finishes, so a night's work is never one uncommitted change. It is the only git operation the mode authorizes — `/commit`, `/open-pr`, `/merge`, `/ship-main` and `/deploy` still wait for the human's own instruction. A checkpoint is local, on the branch you are standing on, and never pushed; `/commit` or `/ship-main` later folds every checkpoint into one real commit.

**Verify your own work.** Drive the browser, run the flows, run the suite, and work through the failures. "Ready for testing" means you tested it and it works.

**Finish clean.** No half-finished states, no `TODO` left in place of work that was in scope, no servers still running, no scratch files in the tree.

## The final report

- What was completed, plainly enough to act on.
- What was verified, and how — the actual commands and their results.
- Every blocker, together, each with exactly what is needed to unblock it.
- Every assumption taken in place of a decision, so a wrong one is a one-line correction.

**Every item is either DONE or BLOCKED.** There is no "not built", no "deferred", no "left unfixed" section, and writing one is the failure rather than the disclosure of it. Not "lower priority", not "not load-bearing", not a defect you found along the way — constitution §XII, you own it, you fix it.

Rank work by importance to decide ORDER, never SCOPE. The tell is a sentence of the form "X wasn't built; it doesn't block Y, which was the part that had to be right" — a scope cut wearing the clothes of a priority call. If you can describe precisely what is missing, you have what you need to build it.

**One task per deliverable.** A task description joining two artifacts with "and" is two tasks. A phase with four outputs is four entries.

Derive that list from the plan document itself, deliverable by deliverable, not from your own summary of it — a summary is a lossy copy, and verifying against it verifies the copy.
