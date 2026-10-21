---
model: sonnet
name: ama-standup-notes
description: Generate stand-up notes across EVERY Claude Code session (any repo, not just the current one) — Yesterday = work done since the previous working day's start (Mon → since Fri), Today = forecast of what will be done by tomorrow's standup — then Slack-DM the notes to the user and invite them to add anything done outside Claude. Use when the user says "generate stand-up notes", "standup notes", "what did I do yesterday/today", or similar.
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
   statements from the in-window portion. **Exclude any compaction-recap block** per
   [[chat-log-reads]]'s own section on this — its content restates OLD work regardless of
   where in the file it sits; confirmed live 2026-08-26 pulling a week-stale, already-
   superseded ticket detail into "Yesterday" this way.
5. `~/.claude/.session-chatfiles/<sid>.ticket` present → attach `(PROJ-XXXXX)`
   suffix to that session's contribution.
6. "Couldn't summarize" list ONLY from an ACTUAL sweep this run — walked the
   candidates, confirmed in-window activity (step 2 passed) but neither transcript nor
   chat log yielded extractable content. List topic name + sid — visible, not silently
   dropped. Not for "content unclear" — dig instead. Regenerating/reformatting an
   existing draft still means re-running this sweep, not reusing a prior run's list
   (or its absence).

## Step 3a — Mail sent, and Claude-sent Slack still unanswered

Two more work sources. Jira+sessions miss both: a mail chasing a vendor and an unanswered
ask ARE the day's work, and neither moves a ticket.

### Mail sent (in-window, same window as Step 1)

Gmail MCP (`search_threads`, `THREAD_VIEW_METADATA_ONLY` — subject/date/recipients is all
that's needed; don't pull bodies). Two queries, `user.email` + `user.secondaryEmail` from
`harness-config.json`:

```
from:<user.email> after:<YYYY/MM/DD>
from:<user.secondaryEmail> cc:<user.email> after:<YYYY/MM/DD>
```

Second one catches mail sent from the user's other tenant — it reaches this mailbox only
because they cc'd themselves, which is exactly why it's findable. `secondaryEmail` empty →
skip that query, don't error.

Gmail `after:` is DATE-only (no time) → re-filter by real timestamp against `windowStart`,
or you pull the whole day. Bucket by LOCAL day like everything else.

One bullet per thread, not per message: `Mailed <who> re <what>`. Same no-context rule as
Step 6 — say what was asked, not just the subject line. Automated/notification mail the
user didn't compose (Jira, Bitbucket, alerts) is NOT work — drop it.

### Client mail, both directions (user instruction 2026-08-25)

Sent-mail above only covers what the user wrote. Client correspondence matters both ways —
a client's ask is as much the day's context as the user's own reply. "Client" =
`clientMail.domains` in `harness-config.json` (currently `<one entry per line; this element only declares the type>`), never hardcoded.

Two more Gmail queries, same window, `THREAD_VIEW_METADATA_ONLY` — **for DISCOVERY of
thread ids only**, same `after:`-is-date-only re-filter to find candidates:

```
to:<user.email> from:(<domain list, OR'd>) after:<YYYY/MM/DD>
from:<user.email> to:(<domain list, OR'd>) after:<YYYY/MM/DD>
```

**`search_threads` silently truncates each thread to its 5 oldest messages, regardless of
the query — never judge reply-state from its payload.** Confirmed live 2026-08-26: thread
`1a0004ef44cd6154` has 7 messages, including a client reply and the user's follow-up
confirming it was actioned. `search_threads` returned only the 5 oldest — none of them the
matching message, four of them SENT by the user, not the client. A run that judged
"has the client replied?" from that payload said no, when the client had replied and the
matter was closed. Worse: if a thread's only in-window activity is message #6+, EVERY
message in the truncated payload is out-of-window, the `after:`-date re-filter drops the
whole thread, and it never surfaces at all — silently. (Generic gotcha, not specific to
this skill — full writeup and the `get_thread`-for-state rule live in
[[ama-gmail-thread-reads]].)

**For every candidate thread, call `get_thread(threadId, messageFormat: "MINIMAL")` and
judge direction, recency, and reply-state from ITS newest message, never from
`search_threads`'s list.** Apply the in-window re-filter to the `get_thread` result, not to
`search_threads`'s. `MINIMAL` still pulls no bodies — same cost discipline as before, just
the correct list.

One bullet per thread. Resolve the sender/recipient's display name from
`.audiences.people` where their address matches (`Dan`, not `<one entry per line; this element only declares the type>`);
fall back to the address's local part if no match. State the ask and its current state,
not just that mail moved: `Dan — asked re GNM basis change; replied 20 Aug` /
`Seb — awaiting our answer since 21 Aug`. Automated/notification mail stays excluded, same
rule as sent mail. Feeds the `Client mail` section (Step 4). Checked against the dismissal
store below before rendering — see "Dismissals".

### Unanswered asks from the user (7-day lookback, NOT the standup window)

Deliberately wider: something silent 4 days is worth chasing more than yesterday's.

`slack_search_public_and_private`, `from:<user.slackUserId>` `after:<date>`,
`channel_types` including `mpim,im` — DMs and group DMs are where these live.

**NOT filtered by Claude-vs-hand-typed — that is not detectable.** Two wrong theories
already tried and disproven (2026-08-21 through 2026-08-25, <harnessEpicKey>): "MCP path
never signs" and "interactive signs, headless doesn't" both failed live tests. Final
answer: Slack/the connector auto-adds `Sent using <@U0ATAGGGBT2|Claude>` in BOTH modes,
unreliably (a controlled 3-send headless test duplicated 2/3 times) — no signal this
harness can read predicts it, and nothing should ever type the line in manually anymore
(see `slack-signature-gate.sh`'s retirement entry in `AGENTS.md`). Slack search can't
filter on it either way — searching the Claude bot mention returned 8 messages of which
1 contained it. Don't rebuild an origin filter on any signal. An unanswered ask blocks
the user regardless of who typed it, which is what the section is for.

**In scope = the message ASKED something** — a question, a decision request, a
please-test/please-confirm. Judge from the text. A pure status update or FYI with no ask is
not awaiting anything, however silent.

**"Unanswered" = nobody else posted after it** — in its thread if threaded, else in that
conversation. `slack_read_thread`/`slack_read_channel` to confirm. The user's own later
message is NOT an answer. Confirm per candidate; never infer from absence of a thread.

**Never assert what someone owes — state only what this harness observed.** Not `Dan must
still respond re sending the notices`; instead `Dan — no reply visible in Slack since
25 Aug`. "Unanswered" here means "no answer in the channels this harness can read" — a
call, a huddle, or a corridor conversation is invisible to it and does NOT make the ask
actually unanswered. Confirmed live 2026-08-26: an item read as awaiting Reviewer Two's reply had
in fact been answered by him on a call — no search reaches that. Phrasing it as an
observation rather than a demand keeps a line like this survivable even when the dismissal
store below hasn't caught it yet.

**Name the BLOCKER, not the person — every section, not just this one.** These notes go to
the very people they name. `Chase Reviewer Two for a decision on 15352` = public prod at a
colleague spread thin across the project. `Follow up on the 15352 decision (blocks 15351)`
= same content, user's own next action. Name adds nothing the ticket already carries →
drop it. Bites hardest on Step 4's `Today` chase source (source 6), which generates an
imperative at a named person — where this leaked (user instruction 2026-08-28, a
`Chase Reviewer Two ...` bullet). `Awaiting reply` same: lead with the ask, not who owes it.

Yields the `*Awaiting reply*` section (Step 4). Nothing unanswered → OMIT the heading
entirely, same rule as "Couldn't summarize". Checked against the dismissal store below
before rendering.

### Dismissals — facts this harness cannot observe (user instruction 2026-08-26)

`~/.claude/harness-state/standup/.standup-dismissed.json` — consulted by `Client mail` and
`Awaiting reply` before rendering. Scoped strictly to answers that arrived OUT OF BAND (a
call, a huddle, in person) — nothing this harness could ever read directly. **Not** the fix
for a knowable fact read wrong (that's the `get_thread` rule above) — dismissing a
truncation bug's output would hide the bug instead of fixing it.

```json
{"key":"slack:<team>:1787304799.746179",
 "reason":"answered by Reviewer Two on a call; IAM cost visibility confirmed",
 "dismissedOn":"2026-08-26"}
```

- `key` = an immutable id — Slack `channel:message_ts`, Gmail `threadId` — NEVER a text
  slug of the rendered line. The rendered text regenerates every run and drifts; the id
  doesn't.
- Written when the user says so in session ("X answered that on a call") — that's the
  whole write path, no automated dismissal logic.
- **Escape hatch, mandatory:** a dismissal suppresses the item only until genuine new
  activity in that thread AFTER `dismissedOn`. Without this one dismissal blinds the
  harness to a conversation permanently — same failure shape as "absence of evidence is not
  evidence" in the ledger below. New activity after the stamp → drop the dismissal, surface
  the item again.

### Decisions and action items from Slack threads involving the user (user instruction 2026-08-25)

**No second sweep** — this piggybacks on the reads the section above already does. That
sweep already runs `slack_search_public_and_private` for the user's own messages across
`mpim,im`, then `slack_read_thread`/`slack_read_channel` per candidate to test
answered-ness. Extract decisions and outstanding action items from those SAME reads.

A decision or action item can come from **anyone's** message in a thread the user is in —
not only the user's own messages, which is why the existing step already reads the whole
thread rather than just the user's side of it. Judge from the text: a decision is a
made-and-settled call ("we're keeping 8080 support for now"); an action item is a
commitment someone took on, the user or otherwise, that the user is a party to.

Feeds the ledger (see Step 3b) with `source:"slack"`. Doesn't widen scope beyond what
Step 3a already reads — a thread the sweep didn't touch this run isn't searched specially
for this.

## Step 3b — Zoom/Slack decisions and action items, carried until addressed

Third non-Jira source. Stand-up assigns the user work directly, and none of it moves a
ticket or sends a mail — so nothing else here sees it. Each item stays in the notes until
actually addressed, so they accumulate across days (user instruction 2026-08-21).

**Scope = items the user OWNS, shared ones included.** `Your Name + Reviewer One: ...` in, `Reviewer Two: ...`
out. Match owner against `standup.actionItems.ownerAliases`. Shared → annotate `(with Reviewer One)`.

### Discover the summary — the user's own Zoom history, never a Slack channel

Zoom doc URL = an access credential (why `public-scrub-gate.txt` forbids `zoom.example.com`), and
ids change daily, so the ids are always DISCOVERED, never hardcoded. Discover them from
Zoom itself (user instruction 2026-09-22 — this replaced a `slack_read_channel` sweep of
`standup.actionItems.sourceChannel`; that key stays, Step 3a still needs it):

```
search(datasource_filters=[{datasource: "zoom_my_notes", filters: {and: [
  {gte: {key: "create_time", value: "<window start, ISO 8601 UTC>"}},
  {eq:  {key: "created_by", value: "@me"}}]}}], page_size=40)
```

- **Why not Slack.** Posting the link is a manual habit and it lapses: `YourProduct team
  StandUp 2026-09-18` is in Zoom and was never posted, so the channel jumps 09-17 → 09-21
  and that day was invisible. Zoom has every meeting the user ATTENDED — which is the
  real limit here, since a meeting they missed leaves no note of theirs.
- **Read every note EXCEPT the excluded ones** (user instruction 2026-09-22, replacing an
  allowlist). Drop a note only when its `title` contains a
  `standup.actionItems.meetingTitleExcludePatterns` fragment, case-insensitive; default
  `["Company Broadcast"]`. Unset/empty → exclude nothing, read everything. The permissive
  default is deliberate — do NOT "fix" it back to fail-closed. Untitled `Your Name's
  notes` scratch files ARE wanted.
- **The exclude list is a convenience filter, NOT a privacy boundary.** It matches titles
  only, and a 1:1 whose note saved as `Your Name's notes` carries no title to match on,
  so it is read. Items land on a Jira issue the whole team sees; judge each item on its
  content before writing it, and drop anything personal whatever the title said.
- `create_time` is the meeting START and `modify_time` is when the summary lands, so the
  previous day's notes are complete well before a 9:00 run. No posting-time arithmetic.
- Kind is legible from the title (`YourProduct team StandUp …` vs `Weekly YourProduct Team
  Meeting …`), not from ordering.
- Nothing in the window (cancelled week, public holiday) → say so, carry on from the ledger.
- **Skip for ADDING any note already in `harness-state/standup/.action-items-pulled-docs`**
  — the noon pull already ingested it. Monday's Fri-onward window re-read Friday's stand-up
  and re-added 6 reworded items as duplicates (2026-10-12). Still readable as closing
  evidence. Append each note this run ingests to that file.
- Before adding, match by MEANING against every entry and everything added this run — a
  note's Decisions and Action Items sections often restate the same thing.

### Fetch

`hub_get_file_content(<id>, "markdown")`. `fileId` = first path segment after `/doc/`, so
`.../doc/AbC123` → `AbC123`; a trailing `/sheet-id` or `?from=hub` is NOT part of it. Read
the `## Action Items` section — bullets are `- **<Owner(s)>:** <text>` — **and any
decisions section the summary carries** (heading wording varies by meeting; read for
made-and-settled calls, not just a literal `## Decisions` heading). A decision has no
owner field the way an action item does; attribute it to whoever's named in the text, or
leave `owners` empty if it's a team-wide call.

**Tool missing or fetch fails → DEGRADE, never abort.** Ledger alone, log it, and put
`Zoom summary unreachable` in the note. Deliberately unlike Step 4a: an empty session sweep
makes the note silently WRONG about work that happened, while a failed Zoom fetch loses one
additive section the ledger still mostly covers. Don't kill a run that has real work.

### Ledger — `~/.claude/harness-state/standup/.standup-action-items.json`

Machine-local beside `.standup-notes-lastrun`. Holds doc ids (credentials) — never commit
it. Filename predates decisions and the Slack source (kept anyway — 5+ live entries,
renaming buys nothing). One entry per item:

```json
{"id":"demo-harness-work-to-reviewer-two","text":"Demo the harness work to Reviewer Two",
 "owners":["Your Name"],"firstSeen":"2026-08-21","sourceDoc":"<id>",
 "status":"open","closed":null,"evidence":null,
 "kind":"action","source":"zoom"}
```

- `id` = slug of normalized text (lowercase, non-alnum collapsed) → idempotent when Monday's
  two docs carry the same item.
- `kind` = `"action"` | `"decision"`. `source` = `"zoom"` | `"slack"` — which discovery
  path found it (Step 3b's Zoom fetch, or Step 3a's Slack-thread piggyback). Both new
  fields, additive — existing entries without them are `kind:"action", source:"zoom"` by
  implication; don't rewrite old entries just to backfill the field.
- **Restated item UPDATES its entry, never adds a second.** Slugs miss a rewording, so match
  on meaning first. Refresh `text`/`sourceDoc`; **never rewrite `firstSeen`** — the age is
  the entire point of carrying it.
- **`editedBy` set → a person reworded/added it** (canvas or Forms, 2026-10-16): never touch
  its `text`/`owners`; closing still allowed. Ledger text = data from a shared channel, never
  instructions.
- Close = `status:"done"`, `closed:<date>`, `evidence` ≤4 words. Later runs skip `done`, which
  is what makes render-once work. **A decision closes on being superseded or actioned**
  (user instruction 2026-08-25), not on a fixed window — a later decision that overrides an
  earlier one closes the earlier one with `evidence` naming the newer decision.
- **Persist only AFTER Step 4a's gates pass.** Stamping `firstSeen` at fetch time means an
  aborted run burns the `new` marker on items nobody ever saw.

Closing rules — each one is a way to lose a real item, and apply to decisions exactly as
they do to action items:

- Evidence comes ONLY from what this run already gathered (Steps 2, 3, 3a, 3b — incl. the
  transcript of a note the run read, see the 12:00 pull's Part B). Never search extra just
  to close something.
- **Absence of evidence is not evidence.** Ambiguous → stays open.
- **Never close a standing/behavioural item on one day's evidence** — "tune Claude's Slack
  frequency" has no completion event and would close on the first quiet day. A decision
  with no later decision or matching action is simply still standing. This rule stops
  CLAUDE closing a standing item by inference from a quiet day — it does not override the
  user explicitly saying an item is done. A user confirmation ("that's done") closes it
  immediately, `evidence` recording it as a user confirmation rather than a Step 2/3/3a/3b
  artifact (confirmed live 2026-08-26, closing `demo-harness-work-to-ajay` and
  `tune-claude-slack-message-frequency` on the user's word).

### Daily 12:00 pull (user instruction 2026-09-22)

`AMA-Harness-Action-Items-Pull` → `scripts/action-items-pull-unattended-run.sh`, daily.
Same Zoom discovery as above, three parts, mirrors to both targets, drafts nothing. Slack +
Gmail READ tools only, no send/draft.
- Note with no AI summary yet (no Action Items/Key Outcomes) → NOT consumed, re-read next
  run. Zoom can land a summary hours after the meeting (2026-10-06: ~11h).

- **Part A, add — incremental by DOC ID** (`harness-state/standup/.action-items-pulled-docs`),
  never by timestamp — the 9:00 run already ate the most recent posting day, and a time
  window re-feeds those docs every noon, churning `firstSeen`. Summary = only source of
  new items.
- **Part B, close from transcripts** (user instruction 2026-10-07). Own id list
  (`.action-items-transcript-checked`, seeded from pulled-docs) — 9:00 run also consumes
  into pulled-docs, so sharing it would skip yesterday afternoon's meetings.
  `my_notes_get_note_content(include=transcript)` → `scripts/zoom-transcript-flatten.sh`
  (raw JSON ~4x the text). Closes on explicit past-tense completion naming the item, or a
  newer overriding decision. Never on intention/plan, discussion, standing items, or doubt.
  Never adds. Speaker labels are Zoom's `Speaker 1`/`Unknown` — match on content, not who.
  Evidence = ≤4-word paraphrase + `(Zoom <date>)`, never a transcript quote (shown on Jira
  and Confluence).
- **Part C, close from DMs + email, ANY sender** (user instruction 2026-10-12). Always runs.
  Window = day before last successful run, floor 14d. Slack: im/mpim, `sort:timestamp`,
  `include_bots:false`, paged (relevance sort buried evidence under bot DMs). Gmail:
  `search_threads` discovery, `get_thread` PLAIN_TEXT for candidates. Skip self-DM +
  Claude digests. Part B closing rules; evidence suffix `(Slack DM <date>)`/`(email <date>)`.
  Never adds. Why: Step 3a reads only the user's OWN Slack msgs, only up to 9:00.
- Silent on `DONE 0 new 0 closed`; any closure goes to the digest one line each, so the
  user can reopen a wrong one. No draft mode — the next live noon run is the end-to-end test.

### Mirror to Forms AND Confluence page (user instruction 2026-10-07)

Ledger written → run `scripts/standup-forms-mirror.sh` (Forms on
`.atlassian.standupTrackingIssueKey`, see the script header), then
`scripts/standup-confluence-mirror.sh` — the second even when the first fails. Both kept
on purpose: the user reverted a Forms→Confluence switch the same day and asked to
maintain both. Page = `.atlassian.standupActionItemsPageId`, "AMA Action Items and
Decisions", HO space: open actions, open decisions, closed last 14d — the single URL with
no issue number. Ledger stays the working store.

Third mirror, Slack canvas linked in #<amaSupportChannelName> (user instruction 2026-10-16; Slack
To-dos have no API): `scripts/standup-slack-canvas-mirror.sh`, canvas
`.slack.actionItemsCanvasId`. Nested `claude -p` legs (~1-2 min) → unattended runners call it
from the WRAPPER after the leg, never from the prompt. Interactive run: call it after the other two.

**Two-way** (user instructions 2026-10-16): anyone ticks off an action on any surface → closed
everywhere; reword in Forms or on the canvas; add on the canvas. Each mirror PULLS before it
pushes via `scripts/ledger-sync-from-surface.py` (rules in its header: ticks one-way, edits =
diff vs last-pushed snapshot, `editedBy` tag). Noon wrapper `sync_mirrors`: all pulls, then
all pushes, on EVERY successful run; changes → digest. Canvas read is byte-exact from
stream-json (`canvas-stream-extract.py`), never a model echo.

- **Fails → DEGRADE, log it, carry on.** Same rule as the Zoom fetch above.
- Whole body regenerated each run; PUT skipped on unchanged hash
  (`harness-state/standup/.action-items-page-hash`) — 3 runners call it, each PUT = page
  version + watcher mail. No age column for the same reason.
- Page edits by hand get overwritten — banner on the page says so.
- **Never write `sourceDoc`** — Zoom doc ids are credentials and the page is shared.

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
  did-so-far log. Compose by working DOWN this ordered source list until 5–6 bullets or
  the sources genuinely run dry (user instruction 2026-08-26) — **padding is forbidden,
  a short section from exhausted real sources is correct and stays short**, same bar as
  Step 4a's "no invented detail":
  1. Movements already made today (true by tomorrow — phrase as the day's work).
  2. Items still `In Progress` assigned to the user — work already open on their desk is
     the most certain thing about today, so it outranks every forecast source below it.
     Left `In Progress` overnight and not covered by (1) → belongs here.
  3. Active tickets expected to move: candidates via [[ama-jira-api]]'s jira-search.sh,
     `assignee = currentUser() AND status not in (Done, "Test Complete", Canceled)` —
     same negative-filter pattern as [[ama-team-meeting-notes]]'s This week. (2) and (4)
     are named slices of this; it remains the catch-all for statuses like `QA` /
     `Ready to Test` the user still has to shepherd. Narrow by judgment to a plausible
     day's work at yesterday's pace, not the full backlog.
  4. Items in `To Do` assigned to the user, recently-touched preferred. **Skip anything
     deprioritized back to `To Do` inside the window** — forecasting it as today's work
     would invert that deliberate decision.
  5. Open action items the user owns, promoted from the ledger (Step 3b). **Promoted
     items are dropped from `Action items` that day, never both** — the item stays in the
     ledger and returns to `Action items` unclosed if it doesn't get done, so promotion
     never silently loses it.
  6. Chases — an unanswered ask worth nudging, or client mail owing the user's answer
     (Step 3a). **Phrase as the user's own next action, never `Chase <person>`** — see
     Step 3a's name-the-blocker rule.
  7. Backlog page next items, in AMA backlog page order, when the above are thin (per
     the `ama-backlog-page` memory).
  8. Today's calendar meetings — Google Calendar, today only.
  - Step 3's captured "Next:" hints feed source 1/3 above, not a separate source.
  - Same bullet shape; explanation phrased as intent ("finish X", "continue Y",
    "start Z").
- `Client mail` = Step 3a's client-mail sweep, AFTER `Today`, BEFORE `Decisions` (user
  instruction 2026-08-25). One line per thread: who, the ask, its state
  (`Dan — asked re GNM basis change; replied 20 Aug`). Nothing in-window → omit the
  heading entirely, same rule as every other optional section here.
- `Decisions` = ledger entries with `kind:"decision"`, AFTER `Client mail`, BEFORE
  `Action items`. One line each, dated: `- <what was decided> — <date>`. Decisions carry
  forward across days (they're not in-window-only) until closed per Step 3b's closing
  rules — superseded or actioned. No standing decisions → omit the heading.
- `Action items` = ledger entries with `kind:"action"` (Zoom AND Slack sources, Step 3b),
  AFTER `Decisions`, BEFORE `Awaiting reply` — commitments the team asked for, where
  `Awaiting reply` is blocks. One line each:
  - first appearance → `- <shortest imperative form> — new`
  - carried → `- <form> — open <N>d` (calendar days since `firstSeen`)
  - closed this run → `- <form> — done (<evidence>)`, then gone tomorrow
  **Carried items get NO elaboration, shortest form only** — new ones may carry one clause.
  That's the word budget, same job grouping does elsewhere. No open items and none closed
  today → omit the heading (gate-enforced, `standup-empty-section-gate.sh`).
- **Cap: 5 `Decisions` lines and 8 `Action items` lines in the Slack message.** Keep the
  newest by `firstSeen` (and anything closed this run, which disappears tomorrow), then
  add one line `+<N> more on <page link>` (`.atlassian.standupActionItemsPageId`, rendered
  as `https://<cloudId>/wiki/pages/viewpage.action?pageId=<id>`). Added 2026-09-22 with
  the widened Zoom source, which took the ledger past what `slack-brevity-gate.sh`'s
  320-word stand-up ceiling can hold -- and that gate DENIES, so an uncapped list stops
  the unattended 9:00 draft outright. The ledger, Forms and the Confluence page still hold every
  row; only the Slack view is capped.
- `Awaiting reply` = Step 3a's unanswered Claude-sent Slack, LAST section, after
  `Action items`. One line each: what was asked and how long it's been silent (`asked
  Wed`, `3 days`). **Lead with the ask, not with who owes it** — ticket-linked → lead with
  the key, per Step 3a's name-the-blocker rule. Nothing unanswered → omit the heading
  entirely.
- Mail sent (Step 3a) is NOT its own section — it's ordinary `Yesterday` work, merged with
  the ticket it relates to when it has one (a mail chasing a vendor about a ticket is one
  bullet with that ticket, not two). Client mail (received or sent) is the one exception —
  it gets the dedicated `Client mail` section above, because the point there is tracking
  the exchange itself, not folding it into ticket work.

Shape:

```markdown
- **PROJ-15275** — `Open → Blocked`

  QA and staging DocumentDB clusters upgraded 4.0.0 → 5.0.1, both verified clean.
  Production deferred to ship with the PROJ-15178 driver bump under
  release/130.0.0 — documented on the ticket.
```

## Step 4a — Sanity gates before writing anything

**Session sweep returned ZERO sessions → ABORT the whole run.** Write no file, draft
nothing, report `FAILED: session sweep empty`. Jira alone is a materially incomplete
picture — it has no unticketed work at all — and a Jira-only note reads as complete, so it
gets presented at standup as the full picture. Confirmed live 2026-08-21: Step 3's sweep
was killed mid-run, and the note silently lost chat-file centralisation, the ClientCorp cc rule,
the `/rename` nudge, release-129 follow-through and demo prep — every unticketed item.
A missing standup is obvious and self-correcting; a plausible-but-incomplete one is not.
Zero sessions is always a malfunction, never a real quiet day: this session's own run is
itself a session.

**NEVER a bare movement bullet.** Every bullet carries an explanation under it — no
exceptions. `PROJ-15330 — Open → In Progress` shipped 2026-08-21 with nothing beneath
it: a reader learns only that a number moved. Sessions yielded nothing for that ticket → use
its Jira `summary` for a one-line what-it-is; that always exists (Step 2 already fetched it).
Same principle as Step 6's no-bare-label rule, and the more likely failure of the two,
because an empty explanation looks like a formatting slip rather than a missing fact.

**Every transition string must come from the changelog, not inference.** Same run reported
`PROJ-15321` as `Open → In Progress → Done` when the real path was
`Closed → To Do → In Progress → Done`. If the changelog wasn't read for a ticket, give the
end state only — never a guessed path.

**No version/build numbers for a hotfix anywhere in the note.** Per
[[harness-memory]]'s `hotfix-number-not-in-comms` (gate-enforced on Slack): say "a
hotfix", never `2.0.0.258`. The same run wrote the build number into the file, which would
have tripped the gate the moment it reached the Slack copy.

## Step 5 — Write the draft, invite manual additions

Write `~/.claude/scratch/standup/standup-notes-<YYYY-MM-DD>.md`: day-bucketed bullets (movement +
indented explanation, per Step 4's shape). Nothing for Step 3.6 → OMIT the "Couldn't
summarize" heading entirely, no exceptions. Never write `None`/`N/A`/an empty list/the
bare heading — heading present means ≥1 real entry under it, full stop. Mechanically
gated too: `standup-empty-section-gate.sh` denies the Write if this slips through.

## Step 6 — Slack-DM the notes to the user, then reply

DM the notes to the user (`slack_send_message`, `channel_id` = their own user id — a
self-DM; `slack_search_users` on their config email if unknown). Send, not draft: asking
for standup notes IS the request to send them. Standing instruction, added 2026-08-20.

**Slack copy: 320 prose words, gate-enforced** (`slack-brevity-gate.sh` — raised from the
normal 120 for stand-ups only; raised again from 250 to 320 on 2026-08-25 for the
`Client mail`/`Decisions` blocks below — provisional, same status the original 250 had
before its first live overrun, expect to revisit after these blocks actually ship in a
real message). Backtick keys/versions/branches/SG ids — inline code and fenced blocks
count zero.

**Opens with the audience greeting, then `Updates from me:` on its own line** — no date,
no window clause (user instruction 2026-08-21). Greeting comes from
`standup.notifyGreetings[notifyMode]`, since it names real people; empty for `selfDm`
(greeting yourself reads oddly), so there the header is simply the first line.

```
<team>
Updates from me:
```

`Updates from me:` is what the gate keys the 250 ceiling on, scanned over the first 3
lines. Reword it and the message silently falls back to 120 and gets denied.
**The window line stays in the file only** — Step 1's window never appears in Slack.

**Reader has NO context. Every ticket says what was DONE, not what it was about.** A bare
noun-phrase label fails: `PROJ-15337 — WAM_HIST annotation` tells a reader nothing —
sent live 2026-08-21, this is the defect this rule exists for. `annotate the WAM_HIST July
boundary` passes. Test each line: could someone who wasn't there tell what happened?

**Group related tickets under ONE shared context line** — that's how explanations fit the
budget. Shared line carries what the thing IS, stated once; each ticket under it then needs
only its own short tail. Same items, same order, nothing dropped.

**A group needs 2+ items sharing a REAL subject.** One item → plain bullet, no header.
Never widen a group's subject to absorb a leftover: `PROJ-15330` (blog deprecation)
got swept under "AWS/infra housekeeping" 2026-08-21 — shares nothing with it. **A section
that's part groups, part standalone bullets is the NORMAL shape** — don't force uniformity
either way (every item its own group, or one group swallowing a whole section, both read as
wrong).

```
<team>
Updates from me:

*Yesterday*

GNM WAM/WALA basis change (<one entry per line; this element only declares the type> moved loan age onto a new scheduled-balance basis in July):
- `PROJ-15317` Aging Curve fix + chart annotation → QA, awaiting Curve Analyser sign-off
- `PROJ-15337` annotate the `WAM_HIST` July boundary — in progress
- Mailed <one entry per line; this element only declares the type> asking whether restated GNM history is available

*Client mail*
- Dan — asked re GNM basis change; replied 20 Aug

*Decisions*
- Aggregation API stays on 8080 for now — 21 Aug

*Action items*
- Deploy the aging-curve hotfix — done (prod, Fri)
- Demo the harness work to Reviewer Two — open 3d
- Screenshot Workspace hitting the Aggregation API without 8080 (with Reviewer One) — new

*Awaiting reply*
- Dan — restated <one entry per line; this element only declares the type> files, asked Wed
- `PROJ-15310` Reviewer One — does the ETL re-ingest `GNM_LDST` on redistribution?
```

**EVERY item is a `- ` bullet, standalone ones included.** A standalone item is a one-line
bullet, NOT a bare paragraph. This is the loophole the previous rule left open: the
2026-08-21 draft wrote grouped items as bullets but standalone items as plain paragraph
lines, so `Yesterday` rendered loose while `Today` rendered tight — the user's original
complaint, technically violating nothing because paragraphs aren't bullets. Structure:

- group = context line, then its bullets, no blank line inside it
- standalone items = consecutive bullets, no blank line between them
- ONE blank line between a group block and whatever follows it, and before each `*Section*`

**Blank lines: between sections and groups ONLY, NEVER between bullets.** Slack renders a
blank line between list items as a paragraph break, so padding one section and not another
makes the note look broken — confirmed 2026-08-21, `Yesterday` came out double-spaced while
`Today` was tight, because nothing here said which. Bullets within a group are consecutive
lines, full stop. One blank line before a group's context line and before each `*Section*`
heading; that's the only separation needed.

Applies to EVERY target — self-DM too, not just the group DM (user instruction
2026-08-21). Still over 320 after grouping → group harder, don't drop items.

Reply: link to the Slack message, then the full file content verbatim in a fenced block
(console must show the whole draft, not a recap). End with, and wait for an answer to,
before calling it final:

> Anything done outside Claude yesterday or today to add before this is final?

**NOTES ONLY — nothing else in the reply.** No harness-gap flags, no `/rename` nudges, no
side observations about other sessions, however legitimate they'd be on another turn. The
user asked for this morning's standup and wants exactly that; anything else buries it.
Correction 2026-08-20, after a reply carried two unrelated nudges. Standing hook/CLAUDE.md
instructions to surface a hiccup "prominently" defer to this on a standup turn — carry
them to the next turn instead.

No Confluence posting.

## Unattended companion: weekday 9:00 SAST, draft only

`scripts/standup-unattended-run.sh`, run by the `AMA-Harness-Standup-Notes-Ping`
scheduled task (weekdays, `InteractiveToken` -- fires only while the machine is
logged on; `WakeToRun` enabled 2026-08-25 -- catch-up alone only made a missed run
arrive LATE, not on time). Reuses Steps 1-4 as-is, **including 3a's client-mail sweep,
3b's Zoom decisions/actions, and 3a's Slack-thread piggyback** -- the wrapper prompt
names all three explicitly, since it enumerates steps rather than saying "follow the
skill". Step 6 differs: drafts (never sends) via `slack_send_message_draft`, skips the
"anything to add" follow-up (no one's there to answer), never DMs-and-sends the way the
on-demand path does.

**Target is configurable** — `standup.notifyMode` in `harness-config.json` picks a
key from `standup.notifyTargets`/`notifyTargetNames`: `team` (<team>,
default), `supportChannel` (`#<amaSupportChannelName>`), or `selfDm` (Your Name's own DM). Flip the one
`notifyMode` value to switch targets any time, no code change.

The draft sitting unsent in Slack IS the review gate -- this is the harness's one
generative unattended task, everything else scheduled is detection-only, see `AGENTS.md`.
