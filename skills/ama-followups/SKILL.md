---
name: ama-followups
description: Works a durable ledger of multi-week Slack-reply escalation chains ("ask X, remind at +1wk, escalate to Y at +2wk, act at +4wk if still silent") -- ~/.claude/.pending-followups. Use when hooks/followup-check.sh's nudge fires (a row's due-date has passed), or to seed a new chain when the user describes an escalation ladder for a Slack question.
---

# Follow-up escalation ledger

`CronCreate` is session-only and auto-expires after 7 days -- it cannot carry a 4-week
ladder. This ledger is the durable substitute: on-disk state, checked by a pure-bash
hook sourced from `on-prompt.sh` (same shape as `ama-embs-reminders`'s coverage file).

## Ledger file

`~/.claude/.pending-followups` -- tab-separated, one row per chain:

```
id \t due-date(YYYY-MM-DD) \t stage \t slack-user-id \t jira-key \t description
```

`stage` is a free-form label for where the chain is (`asked`, `reminded`, `escalated`,
...) -- it exists so the row's next action is legible without re-reading the whole
chain plan; keep the chain plan itself in the seeding session's plan file or reply, not
in the ledger row.

## When `hooks/followup-check.sh` nudges (due-date passed)

1. Read the row's Slack DM thread (`slack_read_thread`/`slack_search_public_and_private`
   on the `slack-user-id`) since the last action -- did they reply?
2. **Replied** -- act on the answer per that chain's original plan (e.g. "closed" ->
   transition the ticket; "not yet" -> just note it), then delete the row from the
   ledger.
3. **No reply** -- advance to the next stage in that chain's plan: send the next Slack
   message (reminder, or escalate to a different person), rewrite the row's `due-date`
   and `stage` to the next step, or if this was the terminal stage, take the chain's
   final action (e.g. cancel the ticket with an explanatory comment, or promote it to a
   backlog page) and delete the row.
4. Report what happened -- which chain, which action -- don't silently swallow it.

## Seeding a new chain

When the user describes an escalation ladder ("ask X, if no reply in a week ask Y,
mentioning X didn't reply, ..."), append one row per *pending* step is wrong -- append
ONE row at the current stage; each time it fires, this skill rewrites that same row to
the next stage rather than adding new rows. Send the T0 message yourself (this skill
doesn't backfill it), then append the row with `due-date` = today + the first interval.
