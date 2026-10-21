---
name: ama-embs-notices
description: Triage "<one entry per line; this element only declares the type> Data Notice:" emails for relevance to AMA — which notices matter, which part of AMA they hit, and what action they demand. Use when hooks/embs-notices-check.sh's nudge fires, when the user says "check the <one entry per line; this element only declares the type> notices"/"<one entry per line; this element only declares the type> data notice"/"did <one entry per line; this element only declares the type> tell us about X", or when a data surprise in GNM/FNM/FHL needs checking against what the vendor already announced. Sibling of ama-embs-reminders (that one is arrival DATES from the calendar; this one is CONTENT of the notices).
---

# <one entry per line; this element only declares the type> Data Notice triage

Vendor announces breaking changes in these emails. Most are irrelevant to AMA. Missing one
costs a production incident — see `AMA-SURFACE-MAP.md`'s "Why this skill exists".

## Mailing <one entry per line; this element only declares the type> — BOTH addresses, every time

Any outgoing mail to <one entry per line; this element only declares the type> (question, case follow-up, data query) goes to EVERY address in
`harness-config.json` `.embs.supportRecipients` — currently `<one entry per line; this element only declares the type>`
AND `<supportRecipients>` — and cc's EVERY address in `.embs.supportCcRecipients` (Reviewer One,
Reviewer Two). Your Name, 2026-09-16: ice.com alone is not enough, bkfs.com is the live support desk; Reviewer One
and Reviewer Two are cc'd on every vendor thread. Read the config, never hardcode. Vendor mail is EXTERNAL → no AI
disclosure line ([[ai-disclosure-footer]]); no <name> cc either (that's ClientCorp-only,
[[clientcorp-cc-horia]]). Drafting mechanics: [[gmail-drafting]].

## Four rules — each maps to a real failure

1. **Subject identifies, never scores.** No path where subject/topic marks a notice
   irrelevant. The WARM/WALA basis change arrived under a Reperforming-Loans subject.
2. **Scope is judged per PARAGRAPH, not per notice.** Out-of-scope products (see map)
   discard a paragraph only. Close a notice as irrelevant only after every paragraph has
   a verdict.
3. **Closing notes/footnotes read LAST and EXPLICITLY**, own verdict line. The material
   content was one closing note.
4. **Keywords boost recall, never filter.** Any hit → written finding for that paragraph
   even if verdict is "no impact". Zero hits → still read every paragraph.

## Steps

1. `bash ~/.claude/skills/ama-embs-notices/scripts/embs-notices-plan.sh` → JSON:
   `since`, `senders`, `subjectPrefix`, `seenIds`, `pendingIds`, `reportTarget`,
   `slackMinTier`, `etlOwner`. Config missing → it fails loud. Don't improvise defaults
   for senders/prefix.
2. **Pending rows first.** Each `pendingIds` entry is a recorded verdict blocked on an
   answer (ETL owner, promised vendor follow-up notice). Answer arrived (followups
   ledger, user, a notice in this window) →
   `scripts/embs-notices-record.sh settle <msg-id> <tier> <ticket|stale|->`. Not yet →
   one line in the report, row stays pending.
3. **Three searches, all mandatory, report all counts:**
   - `in:anywhere subject:"<subjectPrefix>" after:<since>`
   - sender sweep: `in:anywhere from:<each configured sender> after:<since>`
   - label leg: `in:anywhere label:"<each noticeLabels entry>" after:<since>` — no subject or
     sender clause; the label IS the user's filter.

   **`in:anywhere` is required on all three.** Gmail excludes trash and spam by default, and
   these notices now skip the inbox via a filter. [[ama-gmail-thread-reads]] has the evidence
   and the limit (it does NOT reach spam, so an empty result still is not proof).

   **The label leg is insurance, not coverage — do not read it as either more or less.**
   Measured 2026-09-15 over 120 days: all 59 labelled threads already matched the sender sweep,
   so it finds nothing new TODAY. It is here because senders drift (next note), and because a
   colleague filing mail into the folder by hand lands outside both other clauses. Don't delete
   it as dead weight; don't count it as a second net either.

   **The SENDER sweep is the primary net; the prefix search is the convenience.** Confirmed
   live: a 2025-11-05 notice was subject-lined `DATA NOTICE:` with no `<one entry per line; this element only declares the type>` at all, and the
   sender sweep is the only reason it was read — it carried a buried closing note about a
   file's internal header changing (the configured prefix is the looser `DATA NOTICE:`
   since then). Never let the prefix search alone define the candidate set. Always print `N matched prefix, M matched sender, L matched label`; a clean `0 candidates` is the
   failure mode to distrust.

   Senders legitimately vary: notices arrive both direct from the vendor support address and
   via an internal forwarding alias, and which one dominates changes by period. A configured
   sender matching zero in ONE window is not evidence it's dead — don't prune config off a
   single window's result.
4. Skip ids already in `seenIds`. Dedupe on **Gmail message id**, never subject — related
   notices share subjects and one would suppress the other. That one key already collapses
   the overlap ACROSS the three searches, so nothing extra is needed for the label leg.
5. Per remaining notice: `get_thread` (`PLAIN_TEXT`). Body ends mid-content or lacks the
   vendor footer → re-fetch/escalate and SAY SO; never triage a truncated body silently.
6. Partition body into paragraphs. Verdict each, per rules 2–4. Attachments and linked
   files → report "attachment present, unread", don't half-parse.
7. Tier each finding (below). Record one row per triaged notice:
   `scripts/embs-notices-record.sh add <msg-id> <received> <tier> <ticket|stale|pending|-> <slug> <intact|clipped>`
   - T1/T2: the script REFUSES `-`. Carry the ticket key ([[commit-ticket]]), `stale`
     (change already landed / window closed, nothing actionable now), or `pending`
     (blocked on an answer — then also seed/extend an [[ama-followups]] ledger row for
     whoever owes it).
   - Last field is body completeness, not size: `intact` = vendor footer/sign-off present,
     `clipped` = anything less (a clipped row is the one to reopen).
8. Close the run: `scripts/embs-notices-record.sh finish <every candidate id step 3
   returned>` — or `finish --none` for a genuinely empty window. `lastrun` updates only
   when every candidate has a seen row, so an interrupted run re-fires. Honest limit: it
   proves coverage of the candidate list you pass; it cannot see notices the searches
   never surfaced — that's why step 3's two counts are reported verbatim.
9. Deliver per "Output" below.

## Tiers — deliberately not a numeric score

No score, no suppression threshold; that's how a T1 gets silently dropped.

- **T1 — silent value change in an already-published column.** Highest: invisible by
  construction. No ETL error, no missing column, just different numbers and a broken
  series. (The scheduled-UPB basis change was T1.)
- **T2 — client action required by a date.** Opt-in upgrades, "Submit a Request" columns,
  alter statements, deprecation deadlines, parallel-test-file windows.
- **T3 — new field/schema addition** on an ingested product. "Ingested product" = the
  file/tag lists in the map's Product scope section — check there, don't guess from agency
  name. Layout change on an ingested file counts even if we never report the field.
- **T4 — in-scope, no action.** One digest line. Never escalated, never Slacked.

## Output — per flagged item, all six

Verbatim trigger sentence · vendor-side change · named AMA surface (column family /
table / report / curve) · mechanism of harm · effective date · action + owner.

Vague "may be relevant" is ignored by week three. Quote the trigger sentence verbatim,
never a re-summary.

- Scheduling: the on-prompt nudge (`hooks/embs-notices-check.sh`) is primary. A weekly
  detection-only task (`scripts/embs-notices-unattended-ping.sh`,
  `AMA-Harness-EMBS-Notices-Ping`) Slack-pings + writes the digest only when no session
  has shown the nudge for the whole window — it never triages, never marks seen.
- T1/T2 only → Slack via `mcp__claude_ai_Slack__slack_send_message`, `channel_id` =
  `reportTarget` from step 1. A `U…` id DMs, a `C…` id posts to a channel — retargeting
  delivery is that ONE config value (`.embs.noticeReportTarget`), nothing else changes.
  Never Slack a nothing-found week.
- T1/T2 → ticket per [[commit-ticket]] — the durable due-dated store; step 7's `add`
  refuses an undispositioned T1/T2 row. **Seen ≠ actioned**: the seen row records that
  triage happened, never that the problem is closed.
- Client-visible T1 → [[ama-client-facing-notifications]] applies (ask only WHETHER a
  client notification is wanted).
- **Never** auto-reply to the vendor, never submit a request on their portal, never mutate
  the mailbox (no labelling/archiving/trashing) — read-only, audit trail intact.
- Don't verify against Redshift inside the run; point at [[ama-postgres-access]] and
  `AGGREGATION-DB.md` as follow-up.

## First run / new machine

Calibration gate: the run MUST locate the two known-positive 2026 notices named in
`AMA-SURFACE-MAP.md`. Can't find them → the configured mailbox doesn't receive these
notices; STOP and report a mailbox problem. Otherwise the skill reports a clean
`0 candidates` forever and looks healthy.

**This gate tests MAILBOX REACHABILITY, not triage accuracy.** It cannot double as a blind
accuracy test: `AMA-SURFACE-MAP.md` is required reading and its worked examples name those
two notices with their expected tiers, so any run following this skill has already seen the
answer. Don't ask for a "blind" check on them and don't report one as if it happened. A real
accuracy test needs a held-out notice whose verdict is NOT written down here.

**Windowed backfill** (an explicit date range, not the incremental window): if the
calibration notices fall OUTSIDE the range, the gate is unsatisfiable — don't fake it and
don't widen the range to force it. Fetch those two ids directly as a one-off sanity check,
say that's what you did, then triage the range as asked.

Relevance model, keyword lists, worked examples: `AMA-SURFACE-MAP.md`.
