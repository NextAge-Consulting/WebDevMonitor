# Memory Discipline

Route it before writing anything to auto-memory.

1. **Applies to more than one project, or to anyone on the team?** → a shared rule in the dev kit's `.claude/rules/`. Every project picks it up on the next `/sync-dev-kit`.
2. **Specific to THIS project?** → `.claude/rules/project/**` if it governs how work is done here; `project-documentation/` if it is a fact about the system.
3. **Neither** — an ephemeral scratch note, or a personal or machine-specific fact that must not be shared? → memory. That is rare. When in doubt, it is a rule.

Auto-memory is machine-local: a teammate's AI on the same project never sees it. Anything that should govern how work gets done goes in a rule instead.

**Never cite auto-memory from a file in the repo.** A rule, skill or doc that points at a memory is broken for everyone but the machine that wrote it — the reader cannot open it. Cite the committed source instead, or move the fact into the repo.
