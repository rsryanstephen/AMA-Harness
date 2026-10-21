# Picking up tasks / what's in column X

Reference for [[commit-ticket]] -- loaded on demand, not at task start.

## Picking up tasks in a new session

User says "pick up tasks" / "what should I work on" / similar → query **To Do**
specifically, not Open:
```jql
project = PROJ AND assignee = "<user.jiraAccountId from harness-config.json>" AND status = "To Do"
```
Run via [[ama-jira-api]]'s `jira-search.sh`, fields `key,summary` — just enough to
list and pick from.

**Drop `atlassian.harnessTestTicketKey` from the results** (<harnessTestTicketKey>, "Harness test
fixture") — a parked Task that exists only as a Jira write target for harness smoke tests.
Never work it, never close it. It sits at Open so this To Do query won't normally see it,
but a round-trip test can leave it mid-hop — recognize it by key and skip, don't offer it. Only To Do tickets are "ready to start now" — don't also pull in
Open ones (see the Open-vs-To-Do rule in [[commit-ticket-jira]]'s "Creating a new ticket").

**"UI tasks" = exporterplus/admin** (the two S3-hosted frontend repos, per user
instruction) — filter the To Do query to those two by project/component/summary.

**"Non-UI tasks" is the logical complement, resolve it the same way, don't ask.**

**"Remaining"/"all" UI tasks means ALL of them, worked one after another — not just the
first, and not silently dropping one you judge lower-priority.** Triage which qualify,
list ALL of them to the user up front, then work the full list — SAY SO AND ASK before
dropping any, don't decide unilaterally.

**"ETL work"/"the ETL tickets" = assigned to `ama.etlAssigneeAccountId`** (Reviewer One) — filter
by assignee, don't inspect ticket content. Same assignee-based split as
[[ama-team-meeting-notes]] Step 5.


## "What tickets are in column/status X?" — default to the user's own, don't ask

A bare `project = PROJ AND status = X` search reliably includes noise a real
board never shows. Default `assignee = currentUser()` on every bare column/status query — don't
ask first, don't present the unscoped result as the board's truth. Only drop that
filter if explicitly asked for everyone's/the whole team's/all devs' tickets.

[[ama-deploy-release]]'s Step 0b layers a `fixVersion` filter on top of this for the
release-specific follow-up question ("are this release's tickets done?") — a further
refinement, not a substitute for the default assignee scope above.

The [[jira-ticket-fields-gate]] hook (assignee required at ticket creation, see
[[commit-ticket-jira]]'s "Creating a new ticket") is what keeps this scoping question answerable at all —
an unassigned ticket can't be excluded by any scope filter.

