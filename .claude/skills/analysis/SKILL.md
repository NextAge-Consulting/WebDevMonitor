---
name: analysis
description: Produce a written analysis the human asked for — an audit, assessment, investigation, proposal or deep-dive — and package it to share and discuss. Use when asked to analyze / audit / assess / investigate something and write it up, OR when the output is "to share", "to discuss", "for stakeholders", "for approval", or "for review". Covers the format decision, the shared self-contained HTML generator, publishing the page as a claude.ai Artifact, and the discussion folder that `/work --discussion` later pulls back into an action plan.
user-invocable: false
---

# Producing Analysis

When the human asks you to analyze, audit, assess, or investigate something and
write it up — especially to share, for stakeholders, for approval, or for review —
this is how you package it.

## Step 1: Pick the format

| Output | Use for |
|--------|---------|
| **Markdown in-repo** | working docs beside the code, read only by the team — `project-documentation/` (or `…/temporary/` if throwaway) |
| **Discussion page** (the default for anything shared) | an analysis someone will respond to: questions to answer, options to choose between, a proposal to approve, or simply comments |
| **Report page** | a page to read, not to answer — a changelog, a status summary, an information-only write-up |

Sharing intent decides markdown vs a page; if unsure, ask. Between the two pages,
discussion is the default — choose report only when nothing on the page invites a
response.

## Step 2: Build the page with the shared generator, never hand-rolled

**Do NOT write the HTML / `<head>` / CSS by hand.** Hand-rolled report HTML forgets
`charset` + `viewport` every time — invisible until someone opens it on a phone and
gets mojibake and unreadable zoom. The shared generator guarantees them, and the
theme handling the artifact viewer needs.

Build a data JSON, then run the kit tool from the repository root — the `.` is that
root, and `imageBase` and every image path resolve under it:
```bash
node "$CLAUDE_PROJECT_DIR"/.claude/lib/gen-report.mjs . <data>.json <out>.html
```

Data shape:
```json
{
  "title": "Session Timeout Review", "subtitle": "discussion document · for the product owner · 2026-09-24",
  "lang": "en",
  "note": "<b>TL;DR</b> …",
  "stats": [ { "value": "2", "label": "decisions we need" }, { "value": "1", "label": "blocker", "color": "fail" } ],
  "imageBase": ".",
  "sections": [
    { "heading": "Current state", "html": "<p>prose, tables, <code>inline</code> …</p>",
      "images": [ ["path/to/fig.svg", "caption"] ] },
    { "id": "option-1", "heading": "Option 1 — shorter sessions", "html": "…" }
  ],
  "asks": [
    { "id": "D1", "html": "<b>Which option?</b> We recommend option 1 because …" },
    { "id": "Q1", "html": "<b>Does the scenario above match how you work?</b>" }
  ]
}
```

- `title` names the page in the artifact gallery: a short noun phrase specific to the
  subject, two to four words, with no explainer after a dash or colon. The explainer
  goes in the subtitle.
- `html` is arbitrary self-contained content — prose, `<table>`, **inline SVG** (charts).
  No `<script>`, no external stylesheets or images: the page must work unchanged both
  in the artifact viewer and as a plain file.
- `images` are embedded as base64 by the generator and open in a lightbox.
- `lang` defaults to `en` — **set it for a report written in another language**, or a
  screen reader reads Dutch in an English voice and the browser offers to translate it
  into the language it is already in. The discussion copy follows `lang` (English and
  Dutch built in; `asksHeading` and `respondHtml` override it).
- `mode` defaults to `"discussion"`; set `"report"` for a page nobody answers.

**Discussion mode.** Every section gets a stable id — the explicit `id`, otherwise the
heading's slug — and the page ends in `asks`: each numbered decision (`D1`) or question
(`Q1`) the reader should answer, rendered with its id visible so a response can name
it. Put the asks there rather than scattered through the prose. A page with no asks
ends in a general Comments section instead. Either way the generator adds a note on
how to respond: comment on the page when it is open in the artifact viewer, reply to
whoever sent it anywhere else.

## Step 3: Hand it off

**Report page** — write it into `project-documentation/` (durable) or `…/temporary/`
(throwaway), publish it as an Artifact when it is for someone outside the session,
and deliver the link. Recipients need a Claude account; a free one is enough.

**Discussion page** — everything lives in one folder, removed whole when the
discussion is pulled back:

```
project-documentation/temporary/discussion-<slug>/
  <slug>-discussion.md    pointer: front matter + the asks
  <slug>.json             generator input
  <slug>.html             the page — the published copy, and the file for anyone without a Claude account
  feedback-<who>.md       responses that arrived outside the page (optional, any time)
```

`<slug>` is short and names the subject (`session-timeout`). If that folder already
exists, choose a different slug; never write into another discussion's folder.

1. Write the JSON and generate the HTML into the folder.
2. Publish `<slug>.html` with the Artifact tool — `icon: "document"`, a one-sentence
   `description`. Load the `artifact-design` skill first, as the tool requires; the
   generator already meets its page contract, so the page is published as generated.
   The Artifact publishes private; the human sets who can see and comment from the
   page's Share menu.
3. Write the pointer with the URL the publish returned and today's local date:

   ```markdown
   ---
   slug: session-timeout
   artifact: https://claude.ai/…
   published: 2026-09-24
   ---
   # Session Timeout Review

   - D1 — Which option?
   - Q1 — Does the scenario match how you work?
   ```

4. Give the human the link — they share it from the page's Share menu, with comment
   access — and the pull-back command they will run when the discussion ends:
   `/work --discussion <slug>` (the artifact URL works too). Tell them to leave
   "Send to Claude" unchecked when they comment: the pull-back reads every thread.

Revising the page mid-discussion: regenerate, then republish to the same URL (the
Artifact tool's `url`), so existing comments stay with it.

Someone without a Claude account cannot comment. Sending them the file, or a copy
hosted elsewhere, is the human's own step. What they reply goes into
`feedback-<who>.md` in the folder — first line naming the sender and how it arrived
(email, chat), then their words as received — or is pasted into the pull-back session.

## What this skill is not

App/UI reporting features — that's product code. This is analysis *you* author when asked.
