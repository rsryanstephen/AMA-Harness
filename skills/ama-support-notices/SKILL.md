---
name: <amaSupportChannelName>-notices
model: sonnet
description: Triage mail from <one entry per line; this element only declares the type> -- AMA's own automated failure mail. Use when hooks/support-notices-check.sh's nudge fires, when the user says "check support notifications"/"any app-support mail"/"yourproduct-support-notification", or after a monthly-file processing run when a failure mail might have landed. Sibling of ama-embs-notices (vendor data) and ama-aws-notices (AWS platform) -- this one is the APP'S OWN mailbox.
---

# App support-notification triage

App's own failure mail. Hits hardest around monthly-file processing, goes unseen for
hours if nobody's watching. This skill IS the watcher.

## Phase gate -- check `.supportNotices.mode` FIRST, every run

- `construction` (current) -- propose only. Verdict, ack text, ETL-owner message, ticket
  summary, fix outline: all drafted, all sent as ONE Slack DM to
  `targets.construction.ack`. Never post `#<amaSupportChannelName>`, never Slack Reviewer One, never file a
  ticket, never touch code, no matter how obvious the fix.
- `live` -- outbound Slack splits to `targets.live.ack`/`.etlOwner` for real.
  `.supportNotices.createTickets`/`.autoFix`/`.autoHotfix` gate everything past that,
  each flipped independently, each only on explicit go-ahead. Never infer one dial from
  another.
- **Switching `construction` -> `live` also sends the user a DM announcing the switch**,
  as part of making the change -- never silent, even though the switch itself already
  needs explicit go-ahead.

## Cadence -- the SCRIPT decides, not you

`support-notices-plan.sh` already worked out today's day-class and whether this tick
acts (`act`). If invoked outside the unattended runner (user asked directly), run it
anyway and trust `act`/`day`/`cadence` in its output -- don't re-derive by eyeballing a
calendar. `SCHEDULE-UNRESOLVED` on stderr -> STOP, report it, do not guess a day class.

## Steps

1. `bash ~/.claude/skills/<amaSupportChannelName>-notices/scripts/support-notices-plan.sh` -> JSON:
   `since`, `senders`, `seenIds`, `pendingIds`, `day`, `cadence`, `act`, `mode`,
   `ackTarget`, `etlOwnerTarget`, `dials`. Config missing -> fails loud.
2. **Pending rows first.** Each `pendingIds` entry is blocked on an answer. Answer
   arrived -> `support-notices-record.sh settle <msg-id> <verdict> <ticket|stale|->`.
   Not yet -> one line in the report, stays pending.
3. Gmail search `in:anywhere from:<each sender> after:<since>` (`search_threads`), skip ids
   already in `seenIds` -- dedupe on **Gmail message id**, never subject.
   **`in:anywhere` is required.** Without it Gmail drops trash and spam: a real AWS notice was
   found sitting in TRASH once, and this mail is filterable like any other. It still does NOT
   reach spam, so zero hits is never proof nothing arrived -- see [[ama-gmail-thread-reads]]
   and the calibration gate below.
4. Per remaining mail: `get_thread` (`PLAIN_TEXT`). Read the whole body, including any
   stack trace / SQL text -- that's the diagnosis material for verdict `app`.
5. **Verdict each mail — exactly one:**
   - `etl` / `sparc` -- not ours. Owner is Reviewer One (`ama.etlAssigneeName`). Draft the ack
     and the ETL-owner message; **never** <avoid> to Reviewer One (`audiences`
     policy -- he owns ETL/AWS, app internals aren't his domain).
   - `app` -- ours. Draft the ack, a ticket summary, and a diagnosis + proposed fix. A
     SQL error in a report query is the canonical case -- read the actual query/error
     text from the mail, don't guess at the cause.
   - `no-action` -- routine, self-healed, or a duplicate of something already
     triaged. **Never Slacked.** Record WHY as a slug (`heartbeat`,
     `already-fixed-see-PROJ-X`, `dup-of-<msgid>`) -- an unexplained no-action is a
     verdict nobody can review later.
6. Record one row per triaged mail:
   `support-notices-record.sh add <msg-id> <received> <verdict> <disposition|-> <slug>`
   - `etl`/`sparc`/`app` REFUSE a bare `-` disposition: ticket key, `stale`, or
     `pending`. Phase `construction` has no ticket tool -- record `no-action` with a
     `phase1-dm-only` slug and let the DM carry the real verdict; don't invent a fake
     ticket key to satisfy the gate.
   - `no-action` REFUSES an empty slug.
7. Close the run: `support-notices-record.sh finish <every candidate id>` or
   `finish --none`. `lastrun` updates only when every candidate has a seen row.
8. Deliver per "Output" below.

## Known no-action patterns

Empty on purpose -- this section absorbs "there will be many exceptions" as they get
confirmed. Add one line per pattern, with the msg-id or subject fragment that proved it:
`<subject/body fragment> -> no-action, because <reason>`. Growing this list is how the
monitor gets quieter without getting blinder.

- `System Exception : Report with id <guid> was not found` paired with
  `HTTP "DELETE" "/report/<guid>" responded 500`, from `product-service-reports-api`
  -> no-action, but NOT purely "intentional negative test" as first assumed 2026-08-22.
  Corrected 2026-08-25: commit `a71a010` (2026-08-19) regressed this from ~1/run to
  ~10-11/run by adding a redundant cleanup-sweep bug to 7 more call sites -- see
  [[ama-graylog-search]]'s `KNOWN-SIGNATURES.md` #3 for the full story and the fix
  (PROJ-15340). Suppressed at source on the L1 alert stream by a Graylog pipeline
  rule (GUID-shape matched, not pinned). If this signature's volume climbs again or it
  lands in this mailbox despite the rule, check PROJ-15340 shipped and the rule is
  still intact before re-diagnosing the app -- don't re-assume "just test noise".
- `Unable to delete report dimension: Dimension has already been deleted.` from
  `product-service-reports-api` -> same root cause and same fix (PROJ-15340) as
  the report-guid pattern above, one call site. No Graylog suppression needed for this
  one specifically -- the fix removes the redundant delete outright, so post-fix this
  signature should stop appearing rather than needing to be muted.

## Transient noise -- correlated alert cluster under 1 hour

- Intermittent connectivity/read errors (e.g. EMBS FTP SSH banner) only, not generic
  app exceptions.
- Cluster span (last alert - first, same thread) < 1hr, nothing new in last ~15 min ->
  `no-action`, slug `transient-<hours>m`. Never Slacked, not even a compacted line.
- Span > 1hr, or still recurring at triage time -> triage normally.

## Uncertain verdict -> investigate, don't guess

- **The unattended run investigates too -- `Investigated: no` is a real finding, never a
  default.** Its leg A gets `support-notices-investigate.sh` (read-only: `graylog`,
  `pipeline`), so "no tool to investigate from here" is no longer true and must not be
  written. Run BOTH checks per candidate before verdicting. Record `pending` only when a
  check itself errored -- name which one -- not because a mail merely looks ambiguous.
- Interactive session: **mandatory before recording `pending`** -- check the
  `<repository>-api-testing` pipeline for a run overlapping the error's timestamp
  (`ama-bitbucket-api`). Skipping this and recording `pending` anyway is the exact gap
  that let a genuine test bug (PROJ-15340) sit unfixed. Branch on the result:
  - Coincides, signature already confirmed intentional (see "Known no-action patterns")
    -> `no-action`.
  - Coincides, NOT already confirmed intentional -> investigate the actual test code,
    fix if it's a real test bug, ticket it (`commit-ticket`) -- don't just suppress.
    Once fixed, this class never alerts `#<amaSupportChannelName>` even in `live` mode.
  - Doesn't coincide -> triage as a real app error, verdict normally.
- Every investigation, benign or not, ends by adding exactly ONE line somewhere -- terse,
  no incident narrative, useful cold to a future agent:
  - benign, likely to recur -> "Known no-action patterns" below.
  - a reusable technique for investigating THIS mailbox's errors faster -> "Investigation
    shortcuts" below.

## Investigation shortcuts

- `scripts/support-notices-investigate.sh` -- the read-only wrapper both this skill and
  the unattended runner use. Read-only BY CONTRACT: leg A's Bash is scoped to this one
  path, so a subcommand that mutates anything would hand an unattended run write access
  it is not supposed to have. Never add one.
  - `pipeline <iso8601-utc>` -> any `<repository>-api-testing` run overlapping that
    instant (+2min grace). `OVERLAPS` = probably test-caused, not a live fault.
    `INCONCLUSIVE` = the 30-run window never reached the instant asked about; it is NOT a
    negative, and reading it as one triages a test-caused error as a live app fault.
  - `graylog <lucene-query> <range-seconds> [limit]` -> match count + trimmed samples off
    the alert stream. Count and recency are the triage signal: one hit last week and a
    49-hit cluster still firing this morning are different reports.
  - `triage <iso> <query> [range]` -> both of the above, ONE invocation.
  - `triage-batch <iso> <query> <iso> <query> ...` -> `triage` for EVERY mail, ONE
    invocation. Unattended runs use this, always. Round-trip costs minutes; one call per
    mail is what killed three leg-A runs on their timeout.
- Both need `GRAYLOG_PAT` / `BITBUCKET_API_KEY` in the environment; they fail loud, not
  silently empty, when one is missing.
- Graylog host = corporate network. VPN down -> every query times out, error names it.
  Not a token problem, not a query problem.

## Output

- **Phase `construction`**: one Slack DM to `ackTarget`, opening with the literal line
  `Support notification triage:` (own line -- keys the brevity gate's raised ceiling).
  Nothing found -> **send NOTHING.** DM only when there is a real issue (user
  instruction, 2026-09-08 -- reverses the old "never silence a clean window" rule). At
  ~3h cadence the clean-window message was 8 DMs/day; that noise buries the one DM that
  matters. Unattended: leg A replies `NONE`, wrapper suppresses the send, ledger and
  lastrun still advance, ping log still records it. NOT written to the digest either --
  that just moves the noise into every session's prompt.
  - **Never fails to send** (user rule 2026-10-15). Ceiling 400 words
    (`hooks/lib-slack-words.sh`). Runner pre-checks vs the REAL gate: as-is -> no-tools
    summarize leg -> deterministic shrink (`scripts/lib-support-dm-fit.sh`: subjects only,
    token-truncate, pointer to `harness-state/notices/.support-notices-lastdm-full`; floor =
    header + count). Leg B hook-blocked -> one retry with short form. `DRAFT_ONLY` prints
    word count + path. Fixtures: `support-notices-parse-test.sh`.
  - `NONE` = "no new mail to triage", nothing weaker. Saw mail, couldn't settle it -> NOT
    a clean window: list the id, say so, let it send.
  - **Per flagged item, terse block only** -- no message ids, no restating the plan
    JSON, no proposed-message essays:
    ```
    <one-line subject/description>
    `<verbatim error text>` -- first seen <time>
    Investigated: yes. <one-line outcome -- hit count, whether still firing, pipeline overlap>
    Ticket: <link>, or "none yet"
    ```
    Message ids stay internal only (for `support-notices-record.sh`), never in the DM.
  - Matches a "Known no-action patterns" entry, or the transient-noise rule -> **one
    line only**, not a block: `<subject/id> -- no-action, known pattern: <short reason>`.
    Don't re-report a confirmed-benign, recurring signature as a fresh finding.
  - The error quote is always **verbatim**, backticked -- never a paraphrase.
- **Never type a `Sent using @Claude` signature manually, headless or interactive.**
  Confirmed 2026-08-25 (controlled tests): Slack/the connector auto-adds it in BOTH
  modes, unreliably -- typing it in guarantees a visible duplicate more often than it
  prevents a missing one. Accept the rare unsigned send.
- **Phase `live`**: `etl`/`sparc` -> ack on `targets.live.ack` (`#<amaSupportChannelName>`) AND a
  Slack to `targets.live.etlOwner` (Reviewer One) -- <level> level, ETL/AWS framing only. `app`
  -> ack on `targets.live.ack`, ticket per [[commit-ticket]] IF `createTickets` is on,
  then diagnose/fix IF `autoFix` is on, then hotfix per [[ama-hotfix]] IF `autoHotfix`
  is on -- each dial gates only its own step, never assume the next one follows. Same
  quote/known-pattern rules as `construction` above.
- **Seen ≠ actioned**: the seen row records that triage happened, never that the
  problem is closed.
- Never auto-reply to the sender, never mutate the mailbox (no labelling/archiving/
  trashing) -- read-only, audit trail intact.

## First run / new machine

Calibration gate: confirm the configured mailbox actually receives mail from
`.supportNotices.senders` at all -- a Gmail search returning zero for the full
`lookbackHours` window on a machine that just started this monitor is ambiguous between
"quiet fleet" and "wrong mailbox/sender config". If genuinely zero, say so plainly
rather than reporting a silent clean pass.
