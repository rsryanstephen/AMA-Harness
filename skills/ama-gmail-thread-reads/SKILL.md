---
name: ama-gmail-thread-reads
description: Judging a Gmail thread's current state — has X replied, is this answered, what's the newest message — ALWAYS via get_thread, never search_threads. search_threads silently truncates a thread to its 5 oldest messages regardless of query, so it can read backwards or make a thread vanish entirely. Use whenever a skill needs to know a thread's reply-state, not just discover that a thread exists.
---

# Gmail thread reads — state vs discovery

`search_threads` and `get_thread` do different jobs. Mixing them up reads a thread's state
wrong, and it fails silently — no error, just the wrong answer.

## The bug

`search_threads` caps each thread's message list at **5, oldest-first, regardless of the
query**. Confirmed live 2026-08-26 (`ama-standup-notes`, <harnessEpicKey>): thread
`1a0004ef44cd6154` has 7 messages — a client's reply and the user's follow-up confirming
it was actioned are messages 6 and 7. `search_threads` returned only the 5 oldest. None of
them was the client's reply. Judging "has the client answered?" from that payload said no —
the client had already answered and the matter was closed.

Decisive control, ruling out a query-matching problem: querying
`from:<client> newer_than:2d` still returned the same 5 oldest messages for that thread —
four of them SENT by the user, not the client, and none in the 2-day window. The one
message that actually matched the query was not in the payload. The cap applies per
thread, independent of what matched.

**Two failure modes:**
- **Reads backwards.** State judged from a stale message (the case above).
- **Vanishes entirely.** If a thread's only in-window activity is message #6+, every
  message in the truncated payload is out-of-window. A caller that re-filters by timestamp
  on `search_threads`'s list (common — `after:` is date-only, so most callers re-filter)
  drops the WHOLE thread. Silent, no error, nothing to notice.

## The rule

- `search_threads` — **discovery only.** Use it to find candidate thread ids. Never read
  its message list for state.
- `get_thread(threadId, messageFormat: "MINIMAL")` — **state, always.** Returns the real
  full message list (subject/sender/recipients/date, no bodies — same cost discipline as
  `THREAD_VIEW_METADATA_ONLY`). Judge direction, recency, and reply-state from ITS newest
  message. Apply any in-window re-filter to THIS list, not to `search_threads`'s.

One extra call per candidate thread. Cheap — `MINIMAL` pulls no bodies — and it's the only
way to see whether a thread is actually answered.

## Callers

[[ama-standup-notes]] (Step 3a, client mail) and [[ama-team-meeting-notes]] (week-window
variant) both apply this. If a skill's headless wrapper enumerates its own `--allowedTools`
rather than granting a whole MCP server, `get_thread` must be in that list or the fix
silently reverts to the buggy path on unattended runs — this bit `ama-team-meeting-notes`'s
wrapper once (`get_thread` was missing from `team-meeting-notes-unattended-run.sh`).

## Empty result is NOT proof the mail never arrived — check spam

`in:anywhere` did **not** surface spam-labelled mail. Confirmed 2026-09-08: two AWS SNS
subscription-confirmation mails were sitting in spam while four searches for them returned
empty — `in:anywhere` with a sender filter, with a subject filter, and bare over 1h/2h/1d
windows. They were found by hand, in spam.

Mechanism unknown, and don't infer one: a follow-up `in:spam` returning 0 proves nothing,
because the user had already moved both messages out by then. What is established is the
false negative itself, which is enough.

Cost of getting it wrong: a wrong root cause was built on that empty result — "that address
rejects external senders" — and written into a Jira ticket before the mails turned up.

**Rule:** never report "no such email" from an empty `search_threads`. Report that the
search found nothing and **ask the user to check spam** before concluding anything,
especially before writing non-delivery into a ticket or blaming a mail route. Applies to
[[ama-aws-notices]]'s weekly check, whose whole job is noticing an arrival — and note its
step 9 claims `in:anywhere` covers spam, which this contradicts.

`<amaSupportChannelName>-notices` and `ama-embs-notices` also call `search_threads` — not checked here
whether they judge state from it; flagged in `harness-gaps.md` for review, not asserted.

## `label:` wants the DISPLAY NAME in quotes, not the label id

`search_threads`' docs say `label:` takes an id from `list_labels`. It does not. Measured
2026-09-10 on a label holding 32 messages: `label:Label_7866894213587063248` → `{}`, and so
did `in:anywhere label:Label_78668...`; `in:anywhere label:"<one entry per line; this element only declares the type>"` → 27
threads. An id-based label search fails silently and empty, which reads exactly like "no
such mail". Use the quoted display name. `list_labels` still earns its keep for finding
that name, and for `label_thread`/`unlabel_thread`, where the id IS required. Caller:
[[ama-aws-notices]] step 9b.
