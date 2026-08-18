---
name: ama-team-meeting-notes
description: Update the "AMA Current Tasks" section of the latest <titleWords> meeting-notes Confluence page (space/title pattern in harness-config.json's atlassian.confluenceSpaceKey/teamMeetingNotes.titleWords) -- Last week gets a prose summary + every completed AMA APP ticket (grouped by epic), This week gets a pace-based estimate in the same format. NEVER touches AMA ETL or any other section on the page. Use when the user says "update team meeting notes".
---

# AMA team meeting notes

Weekly Confluence update, AMA APP subsection only. AMA ETL is a separate, unrelated
Python/data-pipeline system (Aggregation API, EMR/Snowflake/Parquet work) -- never touch it,
never touch anything outside "AMA Current Tasks" on this page.

**Never hardcode a page ID or date.** Find the latest page fresh, every run.

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
2. **Date window** = `[previous.created, latest.created)`. This is "last week" for ticket
   completion purposes -- NOT a fixed 7 days (can be 4+ weeks when meetings get
   skipped).
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
     to last week's actual pace (ticket count / active epic count) -- explicitly judgment,
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
   - Sign every edit: end the Last week AMA APP prose with a trailing line/bullet noting
     it was drafted by Claude (e.g. "— updated by Claude") so it's clear which weeks were
     automated vs hand-written.
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
     tickets are raised at **Open** (see [[commit-ticket]]'s creation-status rule), promoted
     to **To Do** specifically here when selected for the current week, and a different
     session asked to "pick up tasks" fetches exactly the **To Do** queue (see
     [[commit-ticket]]) -- not Open, not anything else. Getting this step right is what
     makes that hand-off actually work.
9. **Always draft to a file, never write Confluence directly.** Standing user
   preference -- overrides any per-run ask. Reason: relaying the page's
   entire ~55-60K-character body through model output to splice a live shared page
   (Confluence has no partial-patch API) is token-heavy and carries a real corruption
   risk. Write the two approved blocks (prose summary + epic-grouped ticket list, both
   weeks) to the **fixed path** `~/.claude/update for team meeting notes.md` (overwrite
   each run, not date-stamped) -- plain markdown, ticket links as plain
   `https://<atlassian.cloudId>/browse/<atlassian.jiraProjectKey>-XXXXX` URLs (Confluence
   auto-converts a pasted Jira URL into a smart link on paste, no HTML needed). Also print
   the same content in the CLI reply -- don't make the user open the file to see it.
   Tell the user pasting it into the existing "AMA APP" bullet under each of Last
   week/This week (replacing just that bullet's contents) reproduces the page structure.
   Give the page's `webUrl` too, **with `#AMA-Current-Tasks` appended** (the page's own
   heading anchor -- jumps straight to the right section, not just the top of the page;
   confirmed no deeper bullet-level anchor exists in Confluence). Skip steps 10-12 --
   they're Option-B-only, dormant unless the user explicitly asks for a direct write on
   some future run.
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
    - Check `getConfluencePageInlineComments` (resolutionStatus=open) first -- if any exist
      inside the spliced region, warn rather than silently discarding (regenerating
      wholesale drops old `data-local-id`s, which would orphan an inline comment anchor).
    - Re-read the page fresh immediately before writing (not from an earlier-in-session
      read) -- confirm the version number and that nothing changed since your last read,
      to avoid clobbering a concurrent human edit.
12. **(Option B only) Write**: `updateConfluencePage`, full spliced body,
    `contentFormat="html"`. **Verify immediately after**: re-fetch the page and confirm the
    AMA APP ticket sets match what you intended, and AMA ETL / every other section is
    unchanged -- don't just trust the write call succeeded silently. Report a summary + the
    page link to the user.

## Gotchas confirmed the hard way

- Page-body reads/writes: MCP tools only -- `BITBUCKET_API_KEY` 401s against Confluence
  REST; `$ATLASSIAN_API_TOKEN` works for direct REST (attachments/images/archiving) --
  see [[ama-confluence-api]] for both.
- **`updateConfluencePage` is whole-body replacement only (no partial patch), body is a
  literal string.** Every edit relays the ENTIRE ~55-60K-char body through your output
  twice (in, then out) -- real token cost, and a single dropped char/attribute
  (`data-local-id`, mention `data-user-id`, status macro) corrupts a live shared page
  silently. Step 12's post-write verification is mandatory, not optional. Reading the
  giant single-line body: split-then-Read-verbatim -- see [[ama-confluence-api]]'s
  "Reading a large page body".
- **Bulk `searchJiraIssuesUsingJql` blows the tool-result token cap** -- workaround in
  [[ama-jira-api]]'s "Response-shape gotchas" (or use its `jira-search.sh` directly).
