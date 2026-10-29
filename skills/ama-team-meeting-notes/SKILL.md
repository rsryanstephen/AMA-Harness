---
model: sonnet
name: ama-team-meeting-notes
description: Update the "AMA Current Tasks" section of the latest <one entry per line; this element only declares the type> meeting-notes Confluence page (space/title pattern in harness-config.json's atlassian.confluenceSpaceKey/teamMeetingNotes.titleWords) -- Last week gets a prose summary + every completed AMA APP ticket (grouped by epic), This week gets a pace-based estimate in the same format. NEVER touches AMA ETL or any other section on the page. Use when the user says "update team meeting notes".
---

# AMA team meeting notes

Weekly Confluence update, AMA APP subsection only. AMA ETL is a separate, unrelated
Python/data-pipeline system (Aggregation API, EMR/Snowflake/Parquet work) -- never touch it,
never touch anything outside "AMA Current Tasks" on this page.

**Never hardcode a page ID or date.** Find the latest page fresh, every run.

Wanting what was SAID or DECIDED at a meeting (action items, decisions, blockers) rather
than this Confluence section? That's Zoom, not here — recipe in [[ama-standup-notes]]
Step 3b: doc ids discovered from the Slack channel that carries them (never hardcoded, the
URL is a credential), fetched with `hub_get_file_content`.

## Confirmed page shape (verify still true before trusting blindly)

```
AMA Current Tasks
  Status Update:
  Last week
    AMA APP   <- this <li> is fully self-contained: label + its own nested ticket <ul>
    AMA ETL   <- separate content, sometimes a sibling <ol>, never nested inside AMA APP
  This week
    AMA APP
    AMA ETL
```
A ticket with an epic link is nested as a sub-bullet under its epic's bullet; the epic
bullet appears even if the epic itself is still open, whenever >=1 child qualifies. A
ticket with no epic link is a flat top-level bullet.

## Steps

1. **Find the page pair.** CQL (space key and title-match words from
   `atlassian.confluenceSpaceKey`/`atlassian.teamMeetingNotes.titleWords` in
   `harness-config.json`):
   `space = <confluenceSpaceKey> AND type = page AND title ~ "<word 1>" AND title ~ "<word 2>" ORDER BY created DESC`,
   `limit=2`. `latest` = result[0] (the page to update), `previous` = result[1]. Read each
   page's created date. If `latest`'s created date doesn't look like the current cycle
   (e.g. it's actually last week's page), stop and ask -- this week's page may not exist yet.
   - **Confirmed weekly habit: `latest` is created by copy-pasting `previous` verbatim.**
     Even minutes old, its AMA APP Last week/This week content is `previous`'s real data,
     untouched -- looks fully populated, real tickets, real prose. Stale, not done. A
     populated-looking block on read is NOT evidence the update already ran -- always do
     steps 2-7 fresh regardless.
   - **Unattended variant**: fetches a SINGLE reference page (same CQL, `limit=1`) purely
     to anchor the window start, skipping the pair/staleness checks entirely (both exist
     only to protect an in-place Confluence write, which this path never does).
     - **Confirmed 2026-09-07, 5 consecutive cycles: the premise "run fires BEFORE this
       week's page exists" is false in this environment.** Every page in the series is
       created 05:20-06:25Z on its own title date -- the human pre-creates it (copy-paste
       habit above) before the run's 07:00Z (9:00 SAST) fire time. Taking `limit=1`'s
       result as `referencePage` under that false premise anchors to THIS week's own page
       (created ~1.5h earlier), producing a ~2-hour window and an empty "last week" --
       every cycle, not an edge case.
     - **Fix: if the newest page's created date falls on the same calendar day as `now`,
       it IS this week's already-created page, not a usable reference -- fetch `limit=2`
       instead and anchor to result[1] (the previous cycle's page).** Otherwise (genuinely
       no same-day page yet) `limit=1`'s result is the reference as originally written.
       `windowStart = referencePage.created`, `windowEnd = now`. Steps 2-7 proceed
       unchanged.
2. **Date window** = `[previous.created, latest.created)` (or `[referencePage.created, now)`
   for the unattended variant above). This is "last week" for ticket
   completion purposes -- NOT a fixed 7 days (can be 4+ weeks when meetings get
   skipped).
   - **Skipped meeting needs no extra handling -- step 1's CQL already covers it.** A
     skipped week creates NO page (confirmed live 2026-09-21: series runs 08-17, 08-24,
     09-07, 09-21, no 09-14), so `result[1]` IS the last meeting actually held and the
     window stretches to match. Never date-arithmetic a 7-day window on top of this.
   - **Derive `windowWeeks = ceil(windowDays / 7)` here, carry it.** Everything
     downstream saying "last week's pace/count" means PER WEEK, not the window total --
     steps 7 and 8 both divide by it. 14-day window, 25 completions = pace ~13; sizing
     This week against the raw 25 doubles the estimate.
   - Window longer than a week -> say so: real dates + `N weeks` in step 9's file header
     and in the Last week prose. "Last week" is the page's label, not a window claim.
3. **Read `latest` with `contentFormat="html"`** (never `markdown` -- it flattens mentions/
   smartlinks/status badges to plain text, unsafe to write back). From the AMA Current
   Tasks section, extract which ticket keys are epic parents (nested `<ul>`) under Last
   week/This week's AMA APP. This is how epic identity is learned each run for the grouping
   step (6) -- never hardcode which tickets are epics, that changes over time. (Classifying
   APP vs ETL itself doesn't need this page read at all -- see step 5.)
4. **Jira query for the window, filtered by assignee** (the real signal, see below):
   ```jql
   project = PROJ AND status in (Done, "Test Complete")
     AND statusCategoryChangedDate >= "<windowStart>" AND statusCategoryChangedDate < "<windowEnd>"
     AND assignee = "<user.jiraAccountId from harness-config.json>"
   ORDER BY statusCategoryChangedDate DESC
   ```
   Fields: summary, status, issuetype, `<atlassian.epicLinkFieldId from harness-config.json>` (epic link), parent.
   Run via [[ama-jira-api]]'s `jira-search.sh`, not the MCP search tool.
   - **Real-movement filter (confirmed necessary 2026-08-24 — the query above alone
     overwhelmed a real run with ~140 tickets).** A candidate only counts if it moved INTO
     Ready to Test/Test Complete/Done FROM something else DURING the window — not if it
     was already sitting in one of those three at window start and got laterally
     shuffled. Per candidate, pull its changelog (same idiom as [[ama-standup-notes]] Step
     2 — `.values[] | select(.created >= $ws) | .items[] | select(.field=="status")`),
     find the FIRST in-window status change: `fromString` is Ready to Test/Test
     Complete/Done -> EXCLUDE (already there, nothing new happened); `fromString` is
     anything else -> INCLUDE; no in-window status change at all -> EXCLUDE. One
     changelog fetch per candidate — same per-ticket cost ama-standup-notes already
     accepts, for the same reason.
5. **Classification: assignee, not ticket content.** Confirmed with user; verified
   across a full 4-week window, no third assignee seen. AMA APP tickets are assigned to
   `user.jiraAccountId` (`harness-config.json`), AMA ETL tickets to
   `ama.etlAssigneeAccountId`. This is why the Step 4 query already filters by assignee --
   no separate classification pass needed for the common case.
   - **No other field is reliable.** Never classify on `components` -- genuine APP ticket
     PROJ-15169 has empty components, same as ETL.
   - A ticket assigned to neither of the two configured account IDs (rare -- none seen in
     a real 4-week sample, but plausible if a third teammate ever touches AMA work): fall
     back to judgment from summary/domain knowledge (`ama-architecture-notes`: .NET/C#/
     ECS/Lambda/Angular/NuGet/exporterplus/cohort/FieldTableMapper -> APP; Python/
     Aggregation-API/ETL_Extraction/EMR/Snowflake/Parquet -> ETL), and if still unclear,
     **ask the user** naming the ticket + summary + assignee.
   A sub-task whose epic link sits on its parent story rather than on itself: roll up to
   the parent's epic for grouping.
6. **Group by epic**: tickets with an epic nest under a top-level epic bullet (included
   whenever >=1 child qualifies, regardless of the epic's own status); tickets with no
   epic are flat top-level bullets. Don't also list an epic as its own flat bullet.
   - **No "no epic" bucket heading — ever.** Confirmed a mess live 2026-08-24: dumping
     ~75 raw ticket links under a flat "Tickets (no epic)" heading is not usable content.
     A ticket with no epic is just a standalone bullet, same level as an epic-summary
     line, no separating heading between the two kinds.
   - **Bulk-sweep collapse, ported from [[ama-standup-notes]] Step 2**: same transition
     (same fromString->toString), same day, 3+ tickets -> ONE line ("Release 129 deployed
     -- N tickets swept `Test Complete -> Done`"), never N bare links. Confirmed necessary
     live 2026-08-24 — a 43-ticket release sweep rendered as 43 separate lines.
   - **Cap the WHOLE Last week list at 12 items total, ranked by importance, not
     truncated arbitrarily.** Rank: production-impacting bug/hotfix > regression >
     epic-summary line (one line covers however many children) > routine task/CI/QA-only
     ticket. Same cap and ranking for This week. An epic-summary line still counts as ONE
     of the 12 regardless of how many children it covers — that's the point of
     summarizing rather than listing.
7. **Draft content, show the user before writing anything:**
   - Last week: a short **prose** bullet-point summary (plain text, no ticket links) of
     what got done, THEN the epic-grouped ticket list.
   - This week: same shape, but a realistic **estimate**. Candidate query -- ANY status
     other than Done/Test Complete, not a positive whitelist of named statuses:
     ```jql
     project = PROJ AND status not in (Done, "Test Complete")
       AND assignee = "<user.jiraAccountId from harness-config.json>"
       AND (<atlassian.epicLinkFieldId from harness-config.json> in (<active epic keys from step 3/6>) OR key in (<active epic keys>))
     ```
     Fields: same as step 4 -- summary, status, issuetype, epic link, parent. Run via
     [[ama-jira-api]]'s `jira-search.sh`, not the MCP search tool.
     **Use the negative filter, not a positive status whitelist** -- genuine active
     work (including epics, e.g. PROJ-15075) sits in the raw status literally
     named "Open", which a whitelist silently drops. From that candidate set, pick the ones sized
     to last week's actual pace -- `completedCount / windowWeeks` (step 2), NOT the raw
     window total -- over active epic count; explicitly judgment,
     not a mechanical 1:1 query result. **Always regenerate This week wholesale**, replacing
     whatever's currently there (even a populated, human-looking list) -- confirmed
     convention, not merge/leave-alone.
   - **Gotcha: the negative filter also lets "Canceled" through.** Its literal status name
     isn't "Done"/"Test Complete" but its statusCategory IS `done` -- it's dead work, not
     upcoming. Drop any candidate whose `status.statusCategory.key == "done"` regardless of
     literal name, don't just string-match the two named statuses.
   - Ticket list under each prose block: same **bulleted list of plain Jira URL links**
     format as the epic-grouped list elsewhere on this page (one `<a href>` per `<li>`) --
     not just prose, both together.
   - **ONE ticket URL per bullet line. Never two URLs on one line.** The draft is pasted
     into Confluence, which turns each `- ` line into its own bullet -- two URLs on a
     line collapse into one bullet holding two links, which is the whole defect (live
     2026-09-21 draft: `- <15387> <15392> <15402>` on one line, and epic children listed
     inline after the epic URL).
     - Epic group -> epic URL on its own `- ` line, each child on its own `  - ` line
       beneath it (2-space indent = the page's existing nested shape).
     - Grouping that used to share a line (the 3-in-1 exportproducer set, the
       bulk-sweep collapse line) keeps its shared EXPLANATION -- put that on the
       continuation line under the last of the group, tickets still one per bullet.
     - Indent-nesting on paste is unverified; flat-per-line is what the user asked for
       and is what survives either way, so never trade it away to keep a nest.
   - **A ticket gets 1-2 lines under its link ONLY when the summary alone doesn't say what
     happened** -- a bounced status, a hotfix, a defect found in review/deploy, QA
     back-and-forth, a decision made mid-implementation. Most tickets get NOTHING beneath
     the link; that's the expected, normal case, not a gap. Applies to both Last week and
     This week, whether run interactively or unattended.
     - Test: would a reader who only saw the ticket title learn anything new from this
       line? If no, omit it -- same shape as [[ama-standup-notes]] Step 6's no-bare-label
       rule, just inverted (there, every ticket needs a line; here, most don't).
     - Source, cheapest first: check that week's `~/.claude/scratch/standup/standup-notes-<date>.md` files
       (one per weekday in the window) for the ticket's own explanation under its movement
       bullet -- `ama-standup-notes` already wrote it that morning. Use it only if it
       signals a real complication, not routine "shipped, verified" text; trim to <=2
       lines. Touched on multiple days -> use the most complete/final entry, don't
       concatenate. Not covered by any daily note (pre-automation days, or work done
       outside a session) -> pull its Jira changelog directly and add a line only if the
       path itself is non-trivial (reopened, bounced back).
   - Sign every edit: end the Last week AMA APP prose with a trailing line/bullet noting
     it was drafted by Claude (e.g. "— updated by Claude") so it's clear which weeks were
     automated vs hand-written.
   - **Client mail, decisions, and outstanding action items — week-window variant of
     [[ama-standup-notes]]'s Steps 3a/3b/3b's Slack piggyback** (user instruction
     2026-08-25). Don't re-specify the rules here; reuse them with the window widened
     from a day to `[windowStart, windowEnd)` (step 2's window, not the standup's daily
     one):
     - *Client mail* — the same two extra Gmail queries (`clientMail.domains`), same
       one-bullet-per-thread shape, over the full week. **`search_threads` is discovery
       only — call `get_thread(threadId, "MINIMAL")` per candidate and judge state from
       ITS newest message, never `search_threads`'s** (it silently truncates to 5 oldest
       messages per thread, see [[ama-gmail-thread-reads]]). `get_thread` must be in this
       skill's unattended wrapper's `--allowedTools` — it was missing once
       (`team-meeting-notes-unattended-run.sh`), which would silently degrade the Monday
       run back to the buggy path. Also check the dismissal store
       (`~/.claude/harness-state/standup/.standup-dismissed.json`, [[ama-standup-notes]])
       before rendering `Client mail`/`Awaiting reply` items — same store, same rules.
     - *Decisions* / *Action items* — the SAME ledger
       (`~/.claude/harness-state/standup/.standup-action-items.json`), not a second store, since the Monday
       team-meeting run fires right after that morning's standup run and the ledger is
       already fresh. Render every currently-open/standing entry regardless of `firstSeen`
       — the ledger already carries the accumulation logic, this skill just reads it.
       Wrote to the ledger → run [[ama-standup-notes]]'s
       `scripts/standup-forms-mirror.sh` then `scripts/standup-confluence-mirror.sh` after,
       same degrade-never-abort rule, each independently. Slack canvas mirror
       (`standup-slack-canvas-mirror.sh`) runs from the unattended wrapper; interactive → run it last.
     - Three separate labelled blocks after the epic-grouped ticket lists (both weeks):
       `Client mail`, `Decisions`, `Action items` — same names, same order, as the
       stand-up notes use them. Empty block → omit its heading entirely, same rule as
       every other optional section on this page.
   - Get explicit user approval on both blocks before writing -- the prose and the estimate
     are the parts most likely to embarrass if wrong, more so than a misclassified ticket.
8. **After approval, promote the selected This week tickets to To Do in Jira** -- a real
   status transition, done once per ticket, separate from and prior to the Confluence write
   below. Only the LEAF tickets selected for This week, not the epic container bullets
   themselves (an epic's own status is long-running, not tied to a single week).
   - Skip a ticket already at To Do or further along -- idempotent, never move something
     backward, and a re-run of this skill shouldn't re-trigger a transition.
   - `getTransitionsForJiraIssue` first, don't hardcode a transition ID -- IDs aren't stable
     across tickets/workflows in this project (confirmed elsewhere in this harness). Then
     transition to "To Do".
   - This is the deliberate hand-off point in the raise -> plan -> pick-up workflow:
     tickets are raised at **Open** (see [[commit-ticket-jira]]'s creation-status rule), promoted
     to **To Do** specifically here when selected for the current week, and a different
     session asked to "pick up tasks" fetches exactly the **To Do** queue (see
     [[commit-ticket]]) -- not Open, not anything else. Getting this step right is what
     makes that hand-off actually work.
9. **Always draft to a file, never write Confluence directly.** Standing user
   preference -- overrides any per-run ask. Reason: relaying the page's
   entire ~55-60K-character body through model output to splice a live shared page
   (Confluence has no partial-patch API) is token-heavy and carries a real corruption
   risk. Write the two approved blocks (prose summary + epic-grouped ticket list, both
   weeks) to the **fixed path** `~/.claude/scratch/standup/update for team meeting notes.md` (overwrite
   each run, not date-stamped) -- plain markdown, ticket links as plain
   `https://<atlassian.cloudId>/browse/<atlassian.jiraProjectKey>-XXXXX` URLs (Confluence
   auto-converts a pasted Jira URL into a smart link on paste, no HTML needed), **one
   ticket URL per `- ` line, step 7's rule -- that's what makes the paste bullet each
   ticket separately**. Header line carries step 2's real window + `N weeks`. Also print
   the same content in the CLI reply -- don't make the user open the file to see it.
   Tell the user pasting it into the existing "AMA APP" bullet under each of Last
   week/This week (replacing just that bullet's contents) reproduces the page structure.
   Give the page's `webUrl` too, **with `#AMA-Current-Tasks` appended** (the page's own
   heading anchor -- jumps straight to the right section, not just the top of the page;
   confirmed no deeper bullet-level anchor exists in Confluence). Skip steps 10-12 --
   they're Option-B-only, dormant unless the user explicitly asks for a direct write on
   some future run.
   - **Then ALWAYS Slack-DM the same content to `user.slackUserId`** -- real send, not a
     draft, every run, interactive or unattended, no per-run ask (user instruction
     2026-09-07). The file + CLI print alone left the notes somewhere the user had to go
     look for; the DM is what actually notifies. Shape and gate rules: "Slack delivery
     (every run)" below.
10. **(Option B only) Splice, don't rewrite the page.** Build the new AMA-APP-block HTML for
   each of Last week/This week (flat tickets first, then epic-grouped blocks -- matches
   existing page order). Use `scripts/splice_ama_app_block.py <full_page_html>
   <last_week_block> <this_week_block> <output_html>` to do the actual replacement -- it
   locates each `<strong>AMA APP</strong>`, finds its enclosing `<li>` (start anchor) and
   the following `<strong>AMA ETL</strong>`'s enclosing `<li>` (end anchor, exclusive), and
   refuses (nonzero exit, explains why) if the marker pair isn't found exactly twice. Don't
   hand-edit the raw HTML string -- a single-line, tens-of-thousands-of-characters blob is
   exactly the kind of thing a manual edit silently corrupts.
   - Ticket HTML shape (confirmed from live markup, `<cloudId>`/`<projectKey>` from
     `atlassian.cloudId`/`atlassian.jiraProjectKey` in `harness-config.json`): `<p><a
     href="https://<cloudId>/browse/<projectKey>-KEY"
     data-card-appearance="inline">https://<cloudId>/browse/<projectKey>-KEY</a>
     </p>` (note the trailing space before `</p>`). **Omit `data-local-id` on every new
     node** -- Confluence assigns its own; reusing an existing id is the real corruption
     risk, an absent one is safe (confirmed via a spike test against a scratch page).
11. **(Option B only) Safety gates before writing:**
    - Diff-gate: outside the two spliced regions, old and new body must be byte-identical.
    - Check open inline comments first (`GET /wiki/api/v2/pages/<id>/inline-comments`,
      filter `resolutionStatus=open`; MCP retired) -- if any exist
      inside the spliced region, warn rather than silently discarding (regenerating
      wholesale drops old `data-local-id`s, which would orphan an inline comment anchor).
    - Re-read the page fresh immediately before writing (not from an earlier-in-session
      read) -- confirm the version number and that nothing changed since your last read,
      to avoid clobbering a concurrent human edit.
12. **(Option B only) Write**: [[ama-confluence-api]]'s `confluence-update-page.sh <page-id>
    <body-file> "<message>" storage` -- full spliced body, `storage` (XHTML) format, body
    from a FILE. Read side: `confluence-get-page.sh <page-id> <file> storage`.
    **Verify immediately after**: re-fetch the page and confirm the
    AMA APP ticket sets match what you intended, and AMA ETL / every other section is
    unchanged -- don't just trust the write call succeeded silently. Report a summary + the
    page link to the user.

## Slack delivery (every run)

**A REAL Slack send, not a draft** -- unlike every other Ping in this harness. Deliberate:
the point is "notify me before the meeting," and a draft sitting unsent generates no
notification. Safe specifically because the target is always the user's
own DM (`user.slackUserId`) -- the only reader is the person who then hand-copies it into
Confluence, so the risk a draft exists to manage elsewhere (a wrong message landing in front
of someone else) doesn't apply here. Message opens `<@slackUserId>` alone on its own line
(triggers the notification even in a self-DM), then a blank line, then the literal
`*Team meeting notes*` header on its own line -- required, it's what
`slack-brevity-gate.sh` keys its raised ceiling on. URLs stay bare `https://...`, never
Slack link-formatted (`<url|text>`) -- a bare URL still renders as a link for reading, but
"Copy text" on the message returns the literal URL, which Confluence needs to auto-convert
into a smart link on paste (same reasoning as Step 9's file). Ends with a `Promoted to To
Do:` line naming exactly which keys got transitioned (or "none") -- on the unattended path
that's the one write action with no human gate, so this line is the audit trail.

**`slack-brevity-gate.sh` denies past 480 prose words even with the raised team-meeting
ceiling** -- hit live 2026-09-07 at 746. URLs and the ticket lists are cheap; the prose
paragraphs and per-ticket explanation lines are what blows it. Trim by dropping per-ticket
lines (Step 7 already says most tickets get none) and tightening the two prose blocks --
never by cutting tickets. Compute the count the same way the gate does BEFORE sending, and
if a send is denied anyway put the gate's own deny reason verbatim in the reply, so the log
captures the real number without a second run.

## Unattended companion: Monday 9:00 SAST, Slack-delivered

`scripts/team-meeting-notes-unattended-run.sh`, run by the `AMA-Harness-Team-Meeting-Notes-Ping`
scheduled task (Monday only, `InteractiveToken` -- fires only while the machine is logged
on, same caveat as every other Ping; `WakeToRun` enabled 2026-08-25). Reuses Steps
1(unattended variant)-7 as-is, **including Step 7's client-mail/decisions/action-items
block** (the wrapper prompt names it explicitly, since it enumerates steps rather than
saying "follow the skill"), then Step 8 (auto-promote, no review pause -- user
instruction), then Step 9 (still drafts to the fixed file -- Confluence itself stays
entirely manual, standing preference unchanged).

**Delivery**: "Slack delivery (every run)" above -- same rule and shape as an
interactive run, nothing unattended-specific left here.

**Goes FIRST on Mondays (user instruction <YYYY-MM-DD: DM every run through this date, failures only after; blank = failures only>).** Does NOT wait for that Monday's standup
note any more -- it used to (up to 20 min), which put team notes behind standup. Now the reverse:
`standup-unattended-run.sh` waits for this run (its `.team-meeting-notes-lastrun` = today on
success, or `.team-meeting-notes-finished` = today on any exit, written by an EXIT trap here),
capped at 40 min. Cost accepted: Friday/weekend work has no daily-note explanation, so it falls
back to the Jira changelog (above); Tue-Fri notes of last week are still read. Also staggers the two
`claude -p` launches in `sessions.txt`.

**Step 8's over-promotion guard**: before promoting, compare the This-week pick count
against last week's completed count, **per week -- `completedCount / windowWeeks`, never
the raw window total** (a skipped meeting doubles the total and silently doubles this
threshold too). More than `perWeekCount * 1.5` (or `+3` for a small
week) -> still promote, the user's decision stands, but log a warning naming the excess --
that ratio is the shape a bad pace-guess takes, and it should be visible without having to
notice it by eye later.

No new "enabled" config key -- an empty `user.slackUserId` is the off switch, same
convention as every other Ping (standup's own is an empty `notifyTargets.$MODE`).

## Gotchas confirmed the hard way

- Page-body reads/writes: [[ama-confluence-api]] scripts (`storage` format), direct REST
  with `$ATLASSIAN_API_TOKEN` -- MCP retired 2026-08-31. `BITBUCKET_API_KEY` still 401s
  here, don't conflate.
- **Page update is whole-body replacement only (no partial patch), body is a
  literal string.** Every edit relays the ENTIRE ~55-60K-char body through your output
  twice (in, then out) -- real token cost, and a single dropped char/attribute
  (`data-local-id`, mention `data-user-id`, status macro) corrupts a live shared page
  silently. Step 12's post-write verification is mandatory, not optional. Reading the
  giant single-line body: split-then-Read-verbatim -- see [[ama-confluence-api]]'s
  "Reading a large page body".
- **Bulk `searchJiraIssuesUsingJql` blows the tool-result token cap** -- workaround in
  [[ama-jira-api]]'s "Response-shape gotchas" (or use its `jira-search.sh` directly).
