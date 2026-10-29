---
name: ama-feedback-notices
description: Daily unattended monitor for AMA client-feedback form emails (no-reply@example-app.com, "Feedback from Advanced Mortgage Analytics Ref:NNN") — each new one becomes a Jira ticket under the feedback epic and a Slack DM with the link. Use when hooks/feedback-notices-check.sh surfaces its digest, when the user says "check the feedback emails"/"client feedback monitor"/"feedback ticket", or when a feedback mail arrived and no ticket exists for its Ref. Also when FIXING a feedback-epic ticket (hotfix-by-default route) and when its fix reaches QA/Staging/Production (prod watcher, reply draft to Dan with screenshot).
---

# AMA client-feedback monitor

Form mail → Jira ticket (epic `.feedbackNotices.epicKey`, PROJ-15420) → Slack DM to
`.feedbackNotices.reportTarget` with `<@you>` + ticket link. User rule 2026-10-21.

## Pieces

- Runner `scripts/feedback-notices-unattended-run.sh`, task **`AMA-Harness-Feedback-Notices`**
  daily 08:00 local (box is SAST). Registration: `PORTABILITY.md` "Daily client-feedback monitor".
- Leg A (sonnet, Gmail read only) → JSON per new mail. Wrapper → `jira-create-issue.sh`
  (Task, assignee you, Open, backlog Bugs/Features by `kind`). Leg B (haiku, Slack send only).
  No LLM leg holds a write tool — support-notices pattern, AGENTS.md "split the run".
- Ledger `harness-state/notices/.feedback-notices-seen` via `scripts/feedback-notices-record.sh`
  (`add|has|list`) — dedupe on Gmail id AND Ref. Failed create = not recorded = retried next day.
- Digest `notices/.feedback-notices-digest` → `hooks/feedback-notices-check.sh` (on-prompt, once).
  Log `logs/feedback-notices.log`. Task-ok stamp `notices/.task-ok-AMA-Harness-Feedback-Notices`.
- Clean day = silent (no all-clear DM). DM only on created/failed.

## Traps

- Same sender mails temporary passwords + verification codes → query is sender AND
  `subject:"<prefix>"`, never sender alone. A search result that lists them puts credentials in
  the transcript → `hooks/redact-secret.sh` at once (bit 2026-10-21).
- Ticket summary `Ref:NNN - <what the client wants>`, same as the hand-made ones (15421, 15458).
- Replying to the client is NOT this skill: Dan's team is client-facing — draft to Dan per
  [[gmail-drafting]] / [[ama-client-facing-notifications]] when fix is live — see Prod follow-up.

## Fix route — hotfix by default (user rule 2026-10-21)

Feedback-epic ticket fixed → ship as **hotfix** ([[ama-hotfix]]) so client hears back before next
release. Develop-only (next release) ONLY when regression risk HIGH. Claude decides: judge from
the diff per [[ama-hotfix]] Step 1a (shared libs, changed signatures/contracts, shared
queries/mappers/SQL, data rewrites, DI wiring). Additive, optional, UI-confined, verified e2e → low.
Comment on ticket: which route + why. Already on develop → cherry-pick its commits onto
`hotfix/X` off master (patch-id must match), never re-implement.
Mechanical: `git-push-ticket-reminder.sh` names the route on a develop push of a feedback ticket.

## Prod follow-up — watcher + reply to Dan (user rule 2026-10-21)

Fix on QA/Staging → start temporary watcher, detached, one `repo=Projects-N` per repo touched:
```bash
nohup bash ~/.claude/skills/ama-feedback-notices/scripts/feedback-prod-watch.sh <TICKET> <repo>=<Projects-N> [...] --sid <sid> >/dev/null 2>&1 &
```
`git-push-ticket-reminder.sh` nudges this on every develop/release/hotfix/master push of a
feedback ticket with no live watcher. `--once` = check now. Restarted by `pr-watch-check.sh`.
Live in Prod → durable reminder. Then, every time:
1. Screenshot fix working on production ([[ama-ui-verify]], prod test user, no client data).
2. Reply DRAFT in the original feedback mail's thread (Gmail id in ticket description; else
   search `Ref:<n>`): to Dan, cc Reviewer Two, Reviewer One, ContactOne ([[gmail-drafting]]: thread check, sig,
   proofread). Mail >7 days old → Old mail opener (below). Business level: fixed + live in production, what client can now do, screenshot
   inline (`attachments` `inline:true`, `<img src="cid:...">`), he can respond to client.
3. Never send it (client-facing). Slack DM user (`slack_send_message`, `<@user.slackUserId>`
   so it notifies): reply to Dan ready in Drafts, ticket key, thread link. Then action item:
   ```bash
   bash ~/.claude/skills/ama-feedback-notices/scripts/feedback-reply-item.sh add <TICKET> <threadId> [ref]
   ```
   Stand-up ledger row (Confluence + Forms mirrors re-run) + checker that ticks it off once a
   SENT reply from user lands in that thread (haiku `get_thread` leg, every 30 min 07-23h).
   `close <TICKET>` by hand; `open` lists. Restarted by `pr-watch-check.sh`.

## Pick up the next feedback task (user rule 2026-10-21)

"pick up the next feedback task" → never one another session holds or already started/done:
```bash
bash ~/.claude/skills/ama-feedback-notices/scripts/feedback-next.sh --claim <sid>
```
Order: UNCHECKED mail first, then feedback epic Open/To Do (past that = picked up or done),
newest first, skips live claims (atomic claim dir + live sessions' ticket files). No args = list.
Abandon → `--release <KEY>` (unchecked mail: `--release REF-<ref>`).

**`AUDIT <ref> <msgid> <received>`** = ledger row still `pre-existing`: never checked for a reply
or ticket (17 of 28 install-seeded had neither). Window `.feedbackNotices.unansweredMaxAgeDays`
(365); older ignored. Unanswered + in window = must be addressed. Check, don't assume:
1. Jira: `text ~ "<ref>"` in PROJ. Gmail: `in:anywhere "<ref>"`, `get_thread` every hit that
   is not the bare form mail — a reply/forward from us, Reviewer One, Reviewer Two or Dan = answered.
2. Record: ticket → `feedback-notices-record.sh set <ref> <KEY>` (Open/To Do → take it, as
   CLAIMED below; further along → re-run `--claim`). Answered, no ticket → `set <ref> replied`,
   re-run `--claim`. Neither → create ticket, same shape as the monitor's
   (`feedback-notices-unattended-run.sh` payload: `Ref:<ref> - <ask>`, Gmail id + verbatim +
   requirements/AC/how-to-test, epic, backlog Bugs/Features) via [[ama-jira-api]], then
   `set <ref> <KEY>`, work it.

**`CLAIMED <KEY>`** → `set-session-ticket.sh` + In Progress at once, then one of:
- Fix needed → Fix route above; reply to Dan still due once live (Prod follow-up).
- No fix (how-to, data question, commercial ask) → answer it, draft reply to Dan now, same
  draft rules as Prod follow-up step 2-3 (screenshot only if it helps), `feedback-reply-item.sh add`.

**Old mail opener**: feedback mail received >`.feedbackNotices.askIfRepliedAfterDays` (7) days
before the draft → reply to Dan OPENS by asking if his team already answered the client on it
(they reply to clients directly; no reply in our mailbox ≠ client never heard). Every draft,
both routes.

`NONE` → new mail may be unticketed: `FEEDBACK_NOTICES_FORCE=1 bash
.../feedback-notices-unattended-run.sh`, re-run `--claim`. Still NONE → say so.

## Test / run by hand

```bash
FEEDBACK_NOTICES_DRAFT_ONLY=1 FEEDBACK_NOTICES_LOOKBACK_DAYS=30 bash ~/.claude/skills/ama-feedback-notices/scripts/feedback-notices-unattended-run.sh
```
Prints leg A's JSON, every would-be ticket, the DM text. Creates/sends/records nothing.
Real run outside the task: drop `DRAFT_ONLY` (one run per day; `.feedback-notices-lastday`).

Seed old mail: `feedback-notices-record.sh add <msgid> <date> <ref> pre-existing` = UNCHECKED
(feedback-next.sh offers it for the AUDIT check), not "handled". Checked → `set <ref> <KEY|replied>`.

Config (`harness-config.json` `.feedbackNotices`): `senders[]`, `subjectPrefix`, `epicKey`,
`reportTarget` (U-id DMs, C-id posts a channel, empty = tickets only), `lookbackDays` (7),
`unansweredMaxAgeDays` (365), `askIfRepliedAfterDays` (7).
