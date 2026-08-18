---
name: ama-standup-notes
description: Generate stand-up notes across EVERY Claude Code session (any repo, not just the current one) — Yesterday = work done since the previous working day's start (Mon → since Fri), Today = forecast of what will be done by tomorrow's standup — then invite the user to add anything done outside Claude. Use when the user says "generate stand-up notes", "standup notes", "what did I do yesterday/today", or similar.
---

# AMA stand-up notes

Primary source of truth: Jira ticket movements (Step 2). Sessions (Step 3) only explain
movements + surface unticketed work. Session artifacts patchy — never the skeleton.
`away_summary` entries = Claude Code's own idle-recap feature, read-only, nothing here
writes them.

## Step 1 — Resolve the window

`windowStart` = local midnight of previous WORKING day (Tue–Fri → yesterday 00:00;
Monday → Friday 00:00, weekend folds in); `windowEnd` = now. Standard — NEVER ask the
user to confirm it; state it in the draft header, that's the only place it appears.

Timezone rule: transcript timestamps = UTC (`Z` suffix) → compare with `windowStartUTC`.
Jira changelog `.created` = LOCAL offset format (see [[ama-jira-api]]'s response-shape
gotchas) → compare with local `windowStartLocal` (`2026-08-03T00:00:00`). Never mix the
two. Bucket output by LOCAL calendar day.

## Step 2 — PRIMARY: Jira ticket movements

Via [[ama-jira-api]]:

```bash
bash ~/.claude/skills/ama-jira-api/scripts/jira-search.sh \
  'assignee = currentUser() AND (status changed DURING ("<yyyy-MM-dd HH:mm>", "<yyyy-MM-dd HH:mm>") OR updated >= "<yyyy-MM-dd>")' \
  "summary,status"
```

(`DURING` bounds = local time in Jira's `yyyy-MM-dd HH:mm` format. `status changed`
catches moves by anyone — QA send-backs count. `updated` catches touched-no-transition.)

Verified live: the `updated` arm overselects heavily (bulk edits, fixVersion tagging).
Pull changelog only for the `status changed` subset + any `updated`-only ticket a
session actually mentions — not all matches. Bulk moves (N tickets, same transition,
same time) → ONE movement, not N.

Per matched ticket, in-window changelog (same auth/HOST pattern as jira-search.sh —
`lib-harness-repos.sh` config + `ATLASSIAN_API_TOKEN`):

```bash
curl -s -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  "https://${HOST}/rest/api/3/issue/<KEY>/changelog" |
  jq -r --arg ws "$windowStartLocal" '.values[] | select(.created >= $ws) |
    .created + " " + .author.displayName + ": " +
    ([.items[] | select(.field=="status") | .fromString + " -> " + .toString] | join(", "))' |
  grep -v ': $'
```

Result: per ticket, in-window from→to transitions, who, when. Movements = the notes'
skeleton, one bullet each.

## Step 3 — Sessions: explanation source only

Purpose: explain WHY/HOW each Step-2 movement happened + catch unticketed work
(harness etc.). Not a detail mine. Also CAPTURE forward signals for Step 4's Today
forecast — "Next:" trailers in away_summary recaps, open threads in chat logs — don't
discard them.

Enumerate candidates from `~/.claude/sessions.txt` (no per-line timestamp — line
position = recency, top newest; not a reliable window cutoff). Extract each `sid` via
`grep -oP -- 'claude -r \K\S+'` (idiom from `hooks/log-session-start.sh`).

Per `sid`:

1. Transcript: `find "$HOME/.claude/projects" -name "$sid.jsonl" -not -path "*/subagents/*" | head -1`
   (never reconstruct project-dir name from cwd — case-inconsistent). None → step 6.
2. Pre-filter mtime `>= windowStart` (`stat -c %Y`), THEN confirm real in-window work:
   ≥1 `user`/`assistant` entry with `.timestamp >= $windowStartUTC`. Mtime alone lies —
   metadata-only touches (session reopened, null-timestamp entries) pass mtime with zero
   new work. No confirmed entry → drop session, silently.
3. `away_summary` entries in-window:
   ```jq
   [.[] | select(.type=="system" and .subtype=="away_summary" and .timestamp >= $windowStartUTC) |
     {content, timestamp, cwd}]
   ```
   Strip trailing `" (disable recaps in /config)"`. Use entry's own `.cwd` for repo
   attribution (cwd drifts within a session). Entry timestamp = recap GENERATION time,
   not work time — described work happened BEFORE it; bucket by the session's real
   activity timestamps around it, not the recap's.
4. Chat-log scan (path in `~/.claude/.session-chatfiles/<sid>`): scan ALL blocks via
   [[chat-log-reads]] idioms, not just the last — last block can be an unrelated pivot
   or a resume line while real completed work sits earlier. Extract completed-work
   statements from the in-window portion.
5. `~/.claude/.session-chatfiles/<sid>.ticket` present → attach `(PROJ-XXXXX)`
   suffix to that session's contribution.
6. "Couldn't summarize" list ONLY from an ACTUAL sweep this run — walked the
   candidates, confirmed in-window activity (step 2 passed) but neither transcript nor
   chat log yielded extractable content. List topic name + sid — visible, not silently
   dropped. Not for "content unclear" — dig instead. Regenerating/reformatting an
   existing draft still means re-running this sweep, not reusing a prior run's list
   (or its absence).

## Step 4 — Compose, equal-weighted

- Bullet = movement line only: `**KEY** — <from → to>` (or theme name for unticketed
  work). Explanation goes UNDER it, not inline, not a footnote — blank line, 2-space
  indent, plain prose, not its own bullet. Keeps explanation visually tied to its
  ticket, no jumping to a footnote block.
- Explanation: 1–2 lines, from Step 3 (3 only when merging two distinct movements into
  one bullet). Say what changed — cut framing/why-it-matters clauses the what already
  implies. Concrete specifics welcome (versions, counts, file/script names, the actual
  gap found). Commit hash only when the commit itself is the point.
- **UNIFORM across sessions — current session gets zero extra detail over any other.**
  Thin source → thin explanation, don't pad to match a richer one.
- Unticketed work (harness etc.): same shape, grouped by theme.
- `Yesterday` = in-window work up to today 00:00 (bucket by LOCAL calendar day; extra
  day buckets if window spans a weekend). Merge same-thread entries (same ticket, or
  same repo/topic, no discontinuity) into ONE bullet. No invented detail beyond source
  (same bar as [[ama-team-meeting-notes]]'s "Last week" block).
- `Today` = FORECAST — what will have been done by tomorrow's standup, NOT a
  did-so-far log. Compose from:
  - Movements already made today (true by tomorrow — phrase as the day's work).
  - Active tickets expected to move: candidates via [[ama-jira-api]]'s jira-search.sh,
    `assignee = currentUser() AND status not in (Done, "Test Complete", Canceled)` —
    same negative-filter pattern as [[ama-team-meeting-notes]]'s This week. Narrow by
    judgment to a plausible day's work at yesterday's pace, not the full backlog.
  - Step 3's captured "Next:" hints.
  - Same bullet shape; explanation phrased as intent ("finish X", "continue Y",
    "start Z").

Shape:

```markdown
- **PROJ-15275** — `Open → Blocked`

  QA and staging DocumentDB clusters upgraded 4.0.0 → 5.0.1, both verified clean.
  Production deferred to ship with the PROJ-15178 driver bump under
  release/130.0.0 — documented on the ticket.
```

## Step 5 — Write the draft, invite manual additions

Write `~/.claude/standup-notes-<YYYY-MM-DD>.md`: day-bucketed bullets (movement +
indented explanation, per Step 4's shape). Nothing for Step 3.6 → OMIT the "Couldn't
summarize" heading entirely, no exceptions. Never write `None`/`N/A`/an empty list/the
bare heading — heading present means ≥1 real entry under it, full stop. Mechanically
gated too: `standup-empty-section-gate.sh` denies the Write if this slips through.

Reply: short summary first, then full file content verbatim in a fenced block (console
must show whole draft, not a recap). End with, and wait for an answer to, before
calling it final:

> Anything done outside Claude yesterday or today to add before this is final?

Local file only, no Confluence/Slack posting.
