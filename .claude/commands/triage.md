# /triage

Walk through open Gemini Code Assist review comments on the current PR, **one at a time**. Part of the gitflow subsystem. Invoked directly (`/triage`) or via natural-language triggers ("triage gemini", "work the review", "go through the review comments").

$ARGUMENTS

## Protocol

One item at a time. Never batch. Never auto-act.

### Step 1: Identify the PR

Resolve the open PR for the current branch:

```bash
gh pr list --head "$(git branch --show-current)" --json number,url,title --jq '.[0]'
```

If `$ARGUMENTS` is a number, use that instead. If no PR exists, stop and tell the user.

### Step 1.5: Ensure Gemini has reviewed current HEAD

Gemini reviews are comment-triggered (auto-review on PR open is OFF in `.gemini/config.yaml`). Before triaging, confirm a `/gemini review` was posted for the current HEAD and a review has been returned. Invoke the readiness wait:

```bash
.claude/skills/gitflow/scripts/wait-for-pr-ready.sh --pr <N>
```

The script reads the trigger-comment history. If a `/gemini review` comment exists for the current HEAD and a Gemini review has been posted against it, exits ready. If no trigger exists (e.g. last `/commit` was `--no-review`), it exits ready on CI alone — meaning there's no fresh Gemini review to triage. In that case, surface to the user: `Gemini has no review for the current HEAD — last commit was --no-review. Re-trigger with: gh pr comment <N> --body '/gemini review' and re-run /triage, or skip triage.`

Exit handling:
- `0` → Gemini posted (or skipped — see ready message). Proceed to Step 2 only if `findings=N > 0`.
- `2` → CI failed. Triage is pointless until CI is green. Surface the failure and stop.
- `3` → timeout. Surface the diagnostic; The user decides whether to extend, disable Gemini gating, or proceed manually.
- `5` → user interrupted. Stop cleanly.

If `GEMINI_NOT_INSTALLED="true"` (this repo doesn't have the Gemini App): the script returns immediately on `Gemini=skipped`, so this step is effectively a no-op + CI green check. No special-casing needed in this command.

### Step 2: Pull Gemini comments on current HEAD

Capture the current PR HEAD SHA, then fetch reviews and inline comments filtered to **Gemini's review of HEAD specifically**:

```bash
HEAD=$(gh pr view <N> --json headRefOid -q .headRefOid)
gh api "repos/{owner}/{repo}/pulls/{pr}/reviews" \
  --jq "[.[] | select(.user.login == \"gemini-code-assist[bot]\" and .commit_id == \"$HEAD\")]"
gh api "repos/{owner}/{repo}/pulls/{pr}/comments" --paginate \
  --jq "[.[] | select(.user.login == \"gemini-code-assist[bot]\" and .original_commit_id == \"$HEAD\")]"
```

**Why two different filter fields**: review objects and inline-comment objects expose different commit-tracking semantics in GitHub's API.

- **Reviews** carry an immutable `commit_id` — the commit the review was submitted against. Filtering on `commit_id == HEAD` correctly selects only the review Gemini submitted against the current HEAD.
- **Inline comments** carry TWO commit fields: `original_commit_id` (immutable — the commit Gemini wrote the comment against) and `commit_id` (mutable — GitHub auto-updates this as the comment is re-anchored to the latest diff where the line still resolves). Filtering inline comments on `commit_id == HEAD` is **wrong**: GitHub keeps surfacing stale comments by auto-bumping their `commit_id` to the current HEAD, even when the underlying concern has been addressed in a subsequent commit. The freshness filter must use `original_commit_id == HEAD` so only comments freshly posted against the current HEAD by Gemini's latest review pass are surfaced. (Observed in real life on PR #143: a "Fixed in upcoming commit" reply was acknowledged, the fix landed in the next commit, and the same comment id resurfaced on the next triage with auto-updated `commit_id` matching the new HEAD even though Gemini had not re-flagged it.)

Gemini reviews are comment-triggered (auto-review on PR open is OFF). `/open-pr` posts the first trigger; `/commit --review` posts one on subsequent pushes. When Gemini re-flags a concern that survived a fix, it posts a NEW comment object with a new id and `original_commit_id == new HEAD` — so the filter still catches genuine re-flags. Stale auto-re-anchored comments with `original_commit_id == old HEAD` are correctly omitted. The wait-for-pr-ready gate already confirmed a review was posted for HEAD before triage runs (or that no trigger exists, in which case there's nothing to triage).

From inline comments: `id`, `node_id`, `body`, `path`, `line`, `commit_id`, `original_commit_id`, `pull_request_review_id`. The `id` is required later to post threaded replies. The `original_commit_id` is the field used for the freshness filter above. From review bodies: the high-level summary that Gemini posts.

Exclude items the user explicitly marked resolved.

**Keep the order the API returns them in — do NOT re-sort.** Gemini posts its inline comments most-severe first, and GitHub preserves posting order, so the API order already IS severity order and it is what the human sees on the PR web view. Re-sorting by file and line produces item numbers that match nothing on their screen, so every decision costs a round trip to work out which finding you mean.

Gemini severity labels are `Critical | High | Medium | Low | security-critical` (the security-critical tag is composable with other severities). Read the label off each comment for display; do not derive the order from it — the API order is the authority, and a future Gemini that changes its posting order stays correct for free.

### Step 3: Present item 1

Format:

```text
Triaging PR #<N> — <M> Gemini items

Item 1 of <M> — <severity emoji> <Gemini severity label>
  Location: <file>:<line>
  Concern: <one-sentence summary of what Gemini is saying>
  Proposed fix (from Gemini): <brief — elide long snippets, link to PR thread>

Recommendation: <fix | skip | discuss> — <one-line reason>
```

**Then WAIT.** Do not proceed until the user responds.

### Step 4: Act on the user's decision

**HARD RULE 1 — NEVER COMMIT MID-TRIAGE.** When the end-of-triage `/commit` is invoked with `--review`, it triggers ONE Gemini re-review. If you commit mid-triage with `--review`, each commit posts a fresh `/gemini review` and you get N reviews for N commits = review flood + wasted quota. Even with `--no-review` mid-triage, fragmenting the fix history across multiple commits muddles the PR's narrative. Batch all fixes into ONE commit at the end of triage (Step 6).

**HARD RULE 2 — DECLINED FINDINGS MUST LAND AN INLINE SOURCE COMMENT.** When the user declines a finding (says "no", "skip", "not applicable", "false positive"), the workflow MUST also stage a one-to-three-line inline comment at the flagged source line stating the carve-out reason. Examples: `// §VI safe: absolute-instant audit timestamp, not user-facing`, `// nginx h2c rule: real fix is the map-based Upgrade allowlist (see top of file)`, `// rate-limit safe: this endpoint is admin-only, gated upstream by auth middleware`. The PR-thread reply alone is INSUFFICIENT — Gemini reviews are stateless across cycles, and PR-thread replies are not visible to the model on the next pass. Without the inline source comment, the next push triggers a fresh Gemini review and the same finding resurfaces verbatim, costing another triage cycle. The inline comment is the durable record; the PR reply is the audit trail. Both are required.

The inline comment lands as part of the single end-of-triage commit (Hard Rule 1). It does NOT trigger a separate commit.

**HARD RULE 3 — NEVER ASK THE USER TO APPROVE COMMENT WORDING.** Once a decision is made, the PR-thread reply and the inline source comment are yours to write and post. Do not draft them for review, do not ask "reply or silent skip?", do not paste the text back for sign-off. The user decides FIX or SKIP; everything downstream of that decision is execution.

These comments are a historical record, not a deliverable. A round trip to approve a sentence nobody will read again costs the user more than a mis-phrased comment ever will, and asking at every item turns a five-item triage into ten exchanges. Write it, post it, move to the next item.

A "silent skip" is not an option to offer. Hard Rule 2 requires the source comment unconditionally, and the thread reply is one API call on top of it — so every declined finding gets both, without being asked.

| User says | Action |
|---|---|
| "yes" / "fix" / "do it" | Implement the fix. **Stage the change locally only — DO NOT commit.** Post a one-line threaded reply on the Gemini comment: `Fixed in upcoming commit.` via `gh api --method POST "repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies" -f body='Fixed in upcoming commit.'` (uses the `id` captured in Step 2). The reply gives each finding a per-thread acknowledgment in the PR's paper trail. Move on to next item. |
| "no" / "skip" | Post a 1-2 sentence **threaded** reply on the specific Gemini comment stating the reason, via `gh api --method POST "repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies" -f body='...'`. Do NOT use `gh pr comment` — that posts at PR level and loses thread context. **THEN: land an inline source comment at the flagged line stating the carve-out reason** (Hard Rule 2 above). |
| questions / "discuss" | Answer. Loop back to step 3 until a clear decision. |

### Step 5: Advance

After acting, present item 2 in the same format. Continue until every item is processed.

### Step 6: Summary + single end-of-triage commit

After the last item:

- Items fixed: N (list each finding addressed)
- Items declined: N (each with its posted reply link and the source line the carve-out comment landed on)
- Final PR state: link to `gh pr view --web`

If any "fix" decisions were made, prompt the user: "Triage complete. N fixes staged. Ready to commit?" On user authorization, invoke `/commit` ONCE with a message bundling all fixes. The user (via the `/commit` prompt, or by passing `--review` / `--no-review` directly) decides whether the new HEAD triggers a fresh Gemini review. Per the no-auto-commit rule, do not invoke `/commit` without explicit user instruction.

## Constraints

- **One at a time.** Even if the user says "they all look similar," still present each one.
- **Never auto-act.** Every item requires an explicit user decision — FIX or SKIP. That is the ONLY thing the user is asked for; comment wording is never put to them (Hard Rule 3).
- **NEVER commit mid-triage.** Single end-of-triage commit only — see Step 4 Hard Rule 1. Multiple commits with `--review` would trigger multiple Gemini reviews.
- **DECLINED FINDINGS MUST GET AN INLINE SOURCE COMMENT.** Step 4 Hard Rule 2. PR-thread replies alone don't survive the next Gemini cycle.
- **Present items in the order the API returns them** (Step 2). That is Gemini's own severity order and the order the user sees on GitHub; re-sorting makes your item numbers disagree with their screen.
- **Gemini only (MVP).** Human reviewer comments and other bots are future scope.
- **Recommendation is a hint, not a filter.** Always present the item, even ones the recommendation would skip — the user decides.

## Blocking conditions

- Current branch has no open PR: run `/open-pr` first
- Branch is `main`: nothing to triage
- `gh` CLI not available: install gh
- Zero open Gemini items: report "no Gemini items to triage" and exit clean
