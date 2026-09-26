---
name: rule-authoring
description: Use when writing or editing any rule, skill, output style, or CLAUDE.md — `.claude/rules/**`, `.claude/skills/**`, `.claude/output-styles/**`, or a project's own `rules/project/**`. Also use when auditing existing rules for size or overlap. Covers how a rule is written so that it binds.
user-invocable: false
---

# Rule Authoring

A rule is an instruction to a competent actor. It is not an explanation, an argument, or a case for itself.

Written as explanation it reads as background and gets skimmed. Written as instruction it binds. Everything here follows from that.

## Writing one

**Say what to do, not what to avoid.** Keep prohibitions for hard boundaries only: destructive commands, secrets, schema changes, never-touch paths.

**One or two sentences.** A rule that needs a table is usually several rules, or an essay wearing a table.

**A register is not a rule — do not compress one.** Some files under `rules/project/**` are
reference data wearing a rule's clothes: an inventory of what exists, a register of columns
awaiting truth, a catalog of legacy quirks. Their rows ARE the content, enumerated rather
than remembered, and cutting them destroys the thing. Tell them apart by asking what a row
is: an instruction, or a fact about this system. Compress the instructions around a register;
leave the register alone.

**State it once.** Search before adding. The same rule in three files is two deletions, not three cross-references.

**Never count a list.** Write "the recipes below", not "R1–R6"; "these options",
not "these four options". The count tells the reader nothing they cannot see, and it
goes stale silently the moment someone appends — the new entries simply fall outside
the instruction.

**Put the reasoning in the commit message.** It did its work while you were deciding. In the file it competes with the instruction for attention, and costs context on every load.

**Leave out what the repo already says.** Anything learnable by reading the code does not need restating.

**Verify every reference as you write it.** A rule that names a file, command, flag, script, section or skill is asserting it exists — so check. This is the single biggest defect class: instructions to read documents never written, to run scripts absent since the first commit, to pass a flag no script implements, to obey a hook that does not exist. None of it fails loudly; it just quietly cannot be followed.

## Cutting one

**Compression drops scaffolding, restatement, and derivation — never a requirement.** A behavior required before the edit is required after it.

**Removing a rule outright is the human's call.** Bring it with the rule quoted, what it was buying, and what covers it now.

## Before it ships

Has violating this actually cost someone something? A rule with no incident behind it is a preference, and preferences do not earn always-loaded context.

**Have a fresh agent read it and say what it requires.** Give them the file alone — no context, no explanation of intent, no yardstick — and one question: what does this require you to do? What they cannot state back, you have not written. You cannot run this check on yourself; the meaning is already in your head.
