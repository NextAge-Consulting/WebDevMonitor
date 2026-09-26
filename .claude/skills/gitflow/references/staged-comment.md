# The Staged comment

When an issue reaches Staged, its author gets one comment saying what was built, what
they will see, and where it differs from what they asked for. They review against it, so
it is written for them — not for a developer, and not as a changelog.

`/commit`, `/open-pr` and `/ship-main` refuse to stage an issue until its comment exists
as `<notes_dir>/<N>.md`, and post it once the board has moved. One comment per issue,
ever: re-staging an issue that already has one posts nothing.

## The shape

```markdown
**Built — visible after the next deploy.** <one sentence: what now exists>

**What you'll see**
- <the observable result, in the screen's own words — its labels, buttons, columns>
- …

**<Per screen / per list>**  ← only when the result differs by where you look
- **<screen>:** <what it does there, and why if it differs>

**Different from the request**
- <every deviation, each with its reason in a clause>

**Caveat:** <a limit the reviewer would otherwise report as a bug>

**Question for you:** <only a genuine decision, with our recommendation>
```

Only the first line is fixed. Every other block appears only when it has content.

## Rules

- **The first line says when they can see it.** Staged means built, not deployed.
- **Write in the author's terms.** Screen names, labels, buttons — what they would point
  at. Never a file path, a function, a component, a flag or a table name.
- **Every deviation from the request is stated**, with its reason. A reviewer who finds an
  unannounced difference reports it as a defect; one who was told does not.
- **Name related issues by number** (`#14`) where one issue's result depends on another's.
- **Claim nothing you did not verify.** "Verified in the browser" only when it was.
- **A question is a real decision the author owns**, stated once with a recommendation —
  never a request to confirm what was already agreed.
- **Short.** Five to fifteen lines. The author reads every issue's comment; length is
  what makes the next one skimmed.
- **The issue's own language.** Reply in the language the issue was written in.
