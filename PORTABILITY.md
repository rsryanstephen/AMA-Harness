# Portability — general harness vs AMA_APP-specific content

Split out of `AGENTS.md` 2026-08-31 (<harnessEpicKey>) to keep the per-session context lean.
Read this when: installing the harness for a new org, syncing `harness-config.json` to/from
Octopus, touching the unattended Ping scheduled tasks, or deciding which skills are
AMA_APP-specific vs general. `AGENTS.md`'s Portability section holds the summary + pointer.

This harness isn't tied to one machine — see **"Installing on a new machine"** at the top
of this file for the clone/install/personalize flow (`scripts/install.ps1` +
`/harness-setup`). Org-specific identifiers (email, Jira/Confluence IDs, AWS account/
region, Octopus server/space/environment IDs, Graylog host/alert stream, Bitbucket org/
repo-slug prefix, CodeArtifact domain/repo, app domains per environment, library prefix,
release recipients/approvers) live in one file, `~/.claude/harness-config.json`, not
scattered across scripts and skill prose (PROJ-15143, both waves — repo
locations/naming, then every remaining hardcoded identifier, fully done). That file is
**untracked** (gitignored) — the cross-machine source of truth is the org's
**"Claude Harness" Octopus library variable set**, which holds **one variable per scalar
value** — `HarnessConfig:<colon-separated path>`, e.g. `HarnessConfig:atlassian:cloudId`,
`HarnessConfig:releaseNotes:emailRecipients:3`,
`HarnessConfig:releaseNotes:greetingNames:<one entry per line; this element only declares the type>`. It used to be one
JSON blob (`HarnessConfigJson`, removed 2026-08-20 at the user's request) — that made
every value invisible and un-editable in the Octopus UI and unscopeable. All of them must
stay non-Sensitive-typed: Sensitive is write-only via the API, so a fetch would get a mask.
Sync via `scripts/octopus-config-sync.sh fetch|push|verify` — setup-time only, nothing
fetches at runtime; the per-person `user` block is never pushed and never overwritten by a
fetch.
- **Colon, not dot, is the path separator.** `releaseNotes.greetingNames` is keyed BY EMAIL
  and those keys contain dots, so a dotted name would be ambiguous. Colons were verified
  empirically to survive an Octopus PUT/GET verbatim before the scheme was built.
- **`harness-config.example.json` IS the schema**, and it is tracked, so Octopus carries
  values only — no type information is smuggled into variable names. It says which leaves
  are numbers (a digits-only string like an account id must NOT become one), which nodes are
  arrays, and what an array element looks like. Two consequences: **push refuses** when a
  live key has no counterpart in the example (such a value could never be placed by a fetch,
  so it would vanish silently on the next machine — add the key to the example first), and
  **every example array must carry one element** even when empty in practice, or its element
  type is unknowable. Placeholder elements never reach a rebuilt config.
- **Anything not prefixed `HarnessConfig:` is preserved untouched** — the same set holds
  `AmaUiTestUserPassword`, added through the UI so the plaintext never transited a tool call.
  Rebuilding the Variables array from the config alone would silently delete it.
- **A machine whose sync script predates `dd3d01a` will fail with "Variable
  HarnessConfigJson not found (or empty)… it must be a plain text variable."** That message
  is misleading: the variable set is fine, the script is old. `git pull` in the harness repo
  is the fix. The new script has the guard in the opposite direction (no `HarnessConfig:*`
  variables → it says the set has not been migrated yet); the old one cannot warn about a
  scheme that postdates it.
- **`verify` is the round-trip gate**: it fetches into a temp file and diffs against the
  local config, changing nothing. Run it after a push. The first fetch after this change
  normalises key order to the example's without changing a single value.
- Logic lives in `scripts/harness-config-vars.py` (`flatten`/`unflatten`), covered by
  `scripts/harness-config-vars-selftest.sh` — 17 synthetic cases, no network, no real config.
  Two platform traps it pins: python's stdout here is NOT UTF-8 unless reconfigured (an
  em-dash in a `notes` value became a byte the next parse rejected), and a bash-side string
  compare of non-ASCII fails on the harness rather than the code. A fresh clone gets the file seeded from
`harness-config.example.json` by `install.ps1`. **The push-after-edit half is
mechanically enforced, two channels:**
- `octopus-config-push-reminder.sh` (`PostToolUse` on `Edit`/`Write`/`Bash`/`PowerShell`)
  content-hashes the config against `~/.claude/harness-state/harness/.harness-config-synced-hash` whenever a
  tool call names the file (or runs the sync script — a bare `push` command must reach
  the re-baseline branch or the statefile goes stale the moment the nudge is obeyed).
  An actual change nudges: own mid-task edit → push when the edits are complete; a
  picked-up manual/external change → push immediately and tell the user. Mere reads
  stay silent; the sync script's own fetch/push runs re-baseline without nudging.
- `on-prompt.sh` catches manual edits no tool call ever names: a zero-fork `-nt` mtime
  test against the statefile per prompt, one confirming `md5sum` only when the config
  is newer, then injects "push NOW automatically, then tell the user" — re-injected
  every prompt until the push happens (which re-baselines the statefile). A same-bytes
  rewrite just refreshes the statefile mtime to quiet the `-nt` test. Two read
behaviors, chosen per key: most fall back to a default (missing/malformed field →
original hardcoded value, no error) so an unconfigured harness still runs with this org's
values; a smaller set (`hr_config_required` in `lib-harness-repos.sh`) that decides WHICH
COMPANY'S infrastructure a call actually hits — Bitbucket org, AWS region/account,
Graylog host, Jira project key — fails loud instead, since a silent default there means
querying the wrong org's real infrastructure, not just using a placeholder.

Not everything is swappable this cheaply, though — some skills assume AMA_APP's actual
fleet shape (ECS-deployed .NET services, Octopus, Bitbucket, Jira/Confluence via the
Atlassian MCP), not just its identifiers:

**AMA_APP-specific — opt-in, skip if your fleet looks different:** every skill prefixed
`ama-` (`ama-architecture-notes`, `ama-debugging-notes`, `ama-cut-release-branch`,
`ama-deploy-release`, `ama-release-notes`, `ama-library-version-sync`,
`ama-search-shared-version-sync`, `ama-library-pr-propagate`, `ama-octopus-deploy`,
`ama-bitbucket-api`, `ama-cloudwatch-search`, `ama-graylog-search`,
`ama-team-meeting-notes`, `ama-hotfix`, `ama-postgres-access`, `ama-ui-verify`,
`ama-report-debug`, `ama-jira-api`, `ama-confluence-api`, `ama-embs-reminders`,
`ama-embs-notices`, `ama-aws-notices`, `ama-followups`), plus
`company-slides` (YourCompany-brand-specific rather than AMA_APP-fleet-specific — not
prefixed `ama-` for that reason, but equally opt-in/skip-if-different). Several of these
have no dedicated section above — one line each:

- `ama-octopus-deploy` — resolves/triggers Octopus deployments directly (space/project/
  environment, task polling), and the Bitbucket-branch workaround if Octopus itself is
  unreachable.
- `ama-confluence-api` — direct Confluence REST for what MCP has no tool for at all:
  uploading/embedding an image on a page (`contentFormat="adf"` bypasses an HTML→ADF
  converter bug that drops media nested in a list item), and archiving a page (no
  delete/trash tool exists anywhere).
- `ama-team-meeting-notes` — the weekly "This week" Confluence update: Open→To Do
  promotion for the tickets selected to work on.
- `ama-deploy-release` — release-day cutover itself: master merge, production deploy,
  main cache update, verify, revert path, branch cleanup (the stage AFTER
  `ama-cut-release-branch`).
- `ama-embs-reminders` — reads the <one entry per line; this element only declares the type> publishing calendar for GNM/FNM/FHL
  monthly-file arrival dates and creates next-day all-day Google Calendar reminders
  carrying the AMA ETL runbook. Config: `harness-config.json`'s `embs` block
  (`calendarUrl`, `googleCalendarId`). Auto-nudged via `hooks/embs-coverage-check.sh`
  (sourced from `on-prompt.sh`, throttled to once/day) once the published tag window
  is about to run out — the calendar page itself is evergreen/rolling, never goes
  stale, so no URL-verification prompts are needed. A created reminder looks like this:

  ![<one entry per line; this element only declares the type> reminder event](docs/embs-reminders-images/image-1.png)

- `ama-embs-notices` — sibling of the above, and the other half of <one entry per line; this element only declares the type> coverage: that one
  reads arrival DATES off the calendar, this one triages the CONTENT of `<one entry per line; this element only declares the type> Data Notice:`
  emails for AMA relevance. Exists because a vendor WARM/WALA basis change announced three
  months ahead — as one closing note under a Reperforming-Loans subject line — was missed
  and became a production incident (PROJ-15307 tracks the impact work). Hence its
  first rule: subject identifies, never scores; scope is judged per paragraph. Tiers
  T1–T4, no numeric score and no suppression threshold.
  **The sender sweep is the primary net, not a backstop** — a 2025-11-05 notice dropped
  `<one entry per line; this element only declares the type>` from its subject entirely and the prefix search would have missed it (also why
  `noticeSubjectPrefix` is the looser `DATA NOTICE:` now). Backfill runs
  also established that AMA reads <one entry per line; this element only declares the type> **Database** format, not Agency Aligned format, so
  position-keyed/Agency-scoped notices are usually moot for us (evidence in
  `AMA-SURFACE-MAP.md`), and that opt-in format upgrades ("Submit a Request", ~3-month
  window, no reminder, silent absent columns) are the recurring expensive trap.
  Product scope carries two axes because notices name **files** while the calendar names
  **tags** — the map holds both, and its loan-level file list is closed (2026-08-12,
  entitlement `REFINITIV-1`). Two things stay deliberately open there rather than being
  inferred into the confirmed-exclusions list: the stratification family
  (`GNM_LDST`/`LoanDist`, PROJ-15310) and the pool-level product list. Also encoded:
  "we don't report field X" retires VALUE changes only — a column-count change on an
  ingested file still breaks the load. A second axis added 2026-08-18 and traced to code:
  **passthrough vs derived**. Only a handful of pool columns are stored as <one entry per line; this element only declares the type> published
  them, and even those are `AVG`/RPB-aggregated before display, so they reconcile against an
  <one entry per line; this element only declares the type> screen only at single-pool granularity; `WAM_HIST`, every AVG/WA column, `WAMQ`/
  `WALAQ` and `Loan Age Band` are AMA's own with no vendor counterpart (the vendor's
  `LoanDist` and `securityperiodicembsquartile` are read by NO app code). This decides
  whether adjusting a field would put AMA at odds with the vendor, or is simply ours to
  define. A third axis landed the same day: the **portal** — `Pool.asp` → `Hist.asp`, behind
  ICE SSO, whose `HistType=Upd` "Significant Updates" screen is the authoritative check for
  whether the vendor restated a field, and whose ToU (1.2.5 robot clause, 1.2.1/1.2.6
  redistribution) means asking the user before driving it. The map also now carries the
  measured Aug 2026 GNM step and the **single-loan-pool trap** that nearly produced the
  opposite conclusion.
  The seen ledger enforces disposition: `embs-notices-record.sh add` refuses a T1/T2 row
  without a ticket key, `stale`, or `pending`; `settle` resolves a pending row once its
  answer arrives; the plan script re-emits `pendingIds` every run so pending rows can't
  be forgotten. `finish <candidate ids>` (or `finish --none`) stamps `lastrun` only when
  every candidate has a seen row — coverage is checked against the ledger, an interrupted
  run re-fires; the candidate list itself is still caller-supplied (Gmail is MCP-only).
  Final row field is `intact|clipped` body completeness, not a size guess.
  Config: the `embs` block's `noticeSenders`, `noticeLabels`, `noticeSubjectPrefix`, `noticeCheckDays`,
  `noticeLookbackDays`, `noticeOverlapDays`, `noticeSlackMinTier`, `noticeReportTarget`
  (the user's Slack DM today — flip that ONE value to a channel id to broadcast: a `U…`
  id DMs, a `C…` id posts to the channel, same `slack_send_message` call; delivery
  verified live 2026-08-17). State: `~/.claude/harness-state/notices/.embs-notices-{seen,lastrun,nudged,digest,pinged}`,
  dedupe on Gmail message id. Nudged via `hooks/embs-notices-check.sh` (sourced from
  `on-prompt.sh`, once/day) — the PRIMARY scheduler. Headless `claude -p --allowedTools
  mcp__claude_ai_…` executes connector calls for real (verified 2026-08-17: Gmail search
  and Slack send both ran), so a weekly task (`AMA-Harness-EMBS-Notices-Ping` →
  `skills/ama-embs-notices/scripts/embs-notices-unattended-ping.sh`) backstops the
  no-session-for-weeks hole: DETECTION only — candidate counts → Slack DM + one
  `.embs-notices-digest` line (surfaced then truncated by the nudge hook). It never
  triages and never writes seen/lastrun; an unattended wrong verdict would suppress a
  notice forever, so judgment stays in-session. Same schtasks caveat as fleet-health:
  InteractiveToken, runs only while logged on. Gmail read tools (`search_threads`/
  `get_thread`/`get_message`) are allowlisted in `settings.template.json`, per the
  "list what skills call" rule.
- **`AMA-Harness-Standup-Notes-Ping`** (weekdays, `InteractiveToken`, same logged-on
  caveat as fleet-health/embs) runs `skills/ama-standup-notes/scripts/standup-unattended-
  run.sh` at 9:00 SAST (moved from 9:30 2026-08-25, along with team-meeting's; `WakeToRun`
  enabled the same day — catch-up alone only made a missed fire arrive LATE, not on time).
  Unlike fleet-health/embs, this one is GENERATIVE, not detection-
  only — it drives the real `ama-standup-notes` skill headlessly. Safe because Step 6 is
  swapped: drafts (never sends) via `slack_send_message_draft` instead of the on-demand
  skill's self-DM-and-send — the unsent Slack draft is the human review gate, not a
  custom approval queue. **Target is configurable**, not hardcoded to `#<amaSupportChannelName>`:
  `standup.notifyMode` picks a key from `standup.notifyTargets`/`notifyTargetNames`
  (`team` = <team>, default; `supportChannel` = `#<amaSupportChannelName>`; `selfDm`
  = Your Name's own DM) — flip the one value to retarget, no code change. Headless call runs under
  a 1500s timeout. **The failure mode that actually bit twice on 2026-08-21 was NOT the
  timeout**: `claude -p` terminates background tasks after 600s, so a run that delegated the
  session sweep to a background subagent and waited on it returned prose ("Waiting for the
  background session-sweep agent…") instead of `DONE`, which the script reads as failure. Two
  fixes, both needed: the prompt forbids spawning/waiting on any subagent, and
  `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` lifts the ceiling (safe — `timeout` still bounds
  the run). 600s was also the old timeout value, which made this look like a plain timeout and
  cost a wrong diagnosis; don't repeat it. **The scheduled-task ACTION is its own trap**:
  registering `-lc "bash "C:\path\to.sh""` stores nested double quotes that collapse, leaving
  the path unquoted so bash eats every backslash (`C:Usersyour.windows.username…`) → **exit 127, script
  never runs, nothing logged** — so the log looks identical to "not fired yet". Confirmed and
  reproduced 2026-08-21 (the first real scheduler test failed this way, and the production task
  had the same defect). Register with a POSIX forward-slash path and NO nested quotes:
  `-lc "bash /c/Users/…/standup-unattended-run.sh"`. **Verify a scheduled task by its
  `Last Result`, not by the script's own log** — a 127 writes nothing.
  **Re-registered via the hidden-task mechanism** (see "Scheduled tasks must never pop a
  visible, focus-stealing console" above) on 2026-08-21 — produced a real, verified
  `LastTaskResult 0` (log shows it reached real script logic), likely fixing this `127`
  as a side effect of dropping the embedded-quotes `Execute` shape, though that one test
  didn't exercise the full body (the daily throttle short-circuited it first).
  **Step 4a aborts the run when the session sweep is empty** (user instruction 2026-08-21):
  Jira alone silently drops every unticketed item, and the resulting note reads as complete —
  the killed-sweep run lost 5 real work items that way. Zero sessions is always a malfunction,
  never a quiet day. Throttled to once/day via
  `~/.claude/harness-state/standup/.standup-notes-lastrun`; failures leave that file untouched so
  the next scheduled fire retries. The Slack copy carries **grouped explanations, not bare
  labels** (Step 6: per-audience greeting + `Updates from me:`, no date and no window line,
  related tickets under one shared context line, every ticket saying what was actually
  DONE) — the first automated draft shipped `PROJ-15337 — WAM_HIST annotation`,
  meaningless to its own audience, which is what forced the raised 250-word brevity ceiling
  above. Greeting is `standup.notifyGreetings[notifyMode]`, empty for `selfDm`.
  **Blank lines go between sections and groups only, never between bullets** — Slack renders
  a blank line between list items as a paragraph break, and leaving this unspecified produced
  a double-spaced `Yesterday` next to a tight `Today` (2026-08-21). That first fix was
  incomplete: the 14:11 draft then wrote grouped items as bullets but **standalone items as
  bare paragraphs**, reproducing the same loose/tight split while violating nothing, since a
  paragraph is not a bullet. Rule now says every item is a `- ` bullet, standalone included.
  **No bare movement bullets** — every bullet needs an explanation under it; the 2026-08-21
  run emitted `PROJ-15330 — Open → In Progress` with nothing beneath it, so a reader
  learned only that a number moved. Fall back to the ticket's Jira `summary` (Step 2 already
  fetched it) when the session sweep gave nothing. Currently prose-only, not gate-enforced —
  it is mechanically detectable in the written file and worth a check.
  **Step 3b carries the previous meeting's Zoom action items** the user owns (shared ones
  included) until they're actually addressed, accumulating across days in
  `~/.claude/harness-state/standup/.standup-action-items.json` — a Zoom summary only ever holds its own meeting's
  items, so nothing else remembers a still-open one. Closes only on evidence this run
  already gathered, shows `done` once so the close is visible, then drops. `firstSeen` is
  immutable — it's the age. Persist only AFTER Step 4a's gates, or an aborted run burns the
  `new` marker. Ledger holds doc ids, so never commit it.
  **Three new sources added 2026-08-25**, all feeding the same ledger/output shape: (1)
  **client mail, both directions** — Step 3a's client-mail sweep (`clientMail.domains`,
  currently `["<one entry per line; this element only declares the type>"]`) yields a `Client mail` section, one bullet per thread naming
  who and the ask's state; (2) **decisions from the Zoom summaries** — Step 3b now also
  reads a decisions section alongside `## Action Items`, `kind:"decision"` in the ledger,
  closing on being superseded/actioned rather than on a fixed window; (3) **decisions and
  action items from Slack threads involving the user** — piggybacks on Step 3a's existing
  unanswered-asks reads (`source:"slack"` in the ledger), no second sweep. Output order:
  `Today`, then `Client mail`, `Decisions`, `Action items`, `Awaiting reply` last — each
  omitted entirely when empty, gate-enforced (`standup-empty-section-gate.sh`'s heading
  loop widened to cover all four). Brevity ceiling raised 250→320 for the added blocks.
  **Fixed 2026-08-26: Gmail `search_threads` silently truncates a thread to its 5 OLDEST
  messages, regardless of query** — read a real client reply as still-outstanding (the
  matching message wasn't even in the payload), and the same bug makes a thread whose only
  in-window activity is message #6+ vanish from the note entirely. Client mail now
  discovers thread ids via `search_threads` only, then calls `get_thread` per thread and
  judges state from ITS newest message — canonical writeup in new
  `skills/ama-gmail-thread-reads/SKILL.md`, `get_thread` also added to team-meeting's
  wrapper allowlist (was missing there). **`Awaiting reply`/`Client mail` also gained a
  dismissal store** (`~/.claude/harness-state/standup/.standup-dismissed.json`, keyed on
  immutable Slack/Gmail ids) for answers that arrive OUT OF BAND — a call, a huddle —
  which no search can ever see; scoped deliberately away from the `search_threads` bug
  above, and it drops a dismissal on genuine new thread activity rather than blinding the
  harness to it permanently. `Awaiting reply` phrasing changed from asserting what someone
  owes to stating what was observed (`Dan — no reply visible in Slack since 25 Aug`), so a
  line like this stays survivable even before a dismissal lands.
  **`Today` widened to 8 ordered sources 2026-08-26** (was 3, rendered a 3-bullet section):
  movements made today, `In Progress` tickets, other active tickets, `To Do` tickets
  (skipping anything deprioritized this run), open ledger action items (promoted, dropped
  from `Action items` that day so nothing renders twice), chases, AMA backlog page next
  items, today's calendar events — worked down until 5–6 bullets or the sources genuinely
  run dry; padding stays forbidden.
  **Fixed 2026-08-26: Claude Code's own context-compaction recap read as fresh work.** A
  block headed *"This session is being continued from a previous conversation that ran out
  of context…"* restates PRE-compaction history, so a session resumed today can present
  week-old work in prose indistinguishable from a same-day accomplishment — one did, putting
  an already-reassigned ticket detail into `Yesterday`. Generic to any chat-log scan, so the
  rule lives in `skills/chat-log-reads/SKILL.md` (grep that opening line; never extract a
  bullet from inside the block, and check BOTH sides of it — the resume's real work often
  sits immediately before it), cross-referenced from Step 3 point 4. Distinct from the
  `away_summary` timestamp trap already documented there.
  **Phrasing 2026-08-28: name the BLOCKER, not the person** (user instruction). These notes
  go to the very people they name, so `Chase Reviewer Two for a decision on 15352` became
  `Follow up on the 15352 decision (blocks 15351)` — same content, framed as the user's own
  next action instead of a public prod at a colleague who is spread thin. Bites hardest on
  `Today` source 6 (chases), which by shape generates an imperative at a named person, and
  on `Awaiting reply`, which now leads with the ask rather than who owes it. Deliberately
  NOT a `.audiences` field: that block's resolution is an algebra (level = min, avoid =
  union) with no tone equivalent, and the offending line was in a note *to* Reviewer One and Reviewer Two
  *about* Reviewer Two, so an addressee-keyed gate would never have fired on it. Mirrored into
  `standup-unattended-run.sh`'s inlined prompt (Monday's run would otherwise regenerate it).
- **`AMA-Harness-Team-Meeting-Notes-Ping`** (Monday only, `InteractiveToken`, same
  logged-on caveat) runs `skills/ama-team-meeting-notes/scripts/team-meeting-notes-
  unattended-run.sh` at 9:00 SAST (moved from 9:30 2026-08-25; `WakeToRun` enabled the
  same day) — GENERATIVE like standup's, not detection-only.
  **Deviates from every other Ping: sends a REAL Slack message, never a draft** — the
  target is always the user's own DM (`user.slackUserId`), so the risk a draft exists to
  manage elsewhere (a wrong message reaching a real audience) doesn't apply, and a draft
  generates no notification, which is the entire point here ("wake me up before the
  meeting"). Message opens `<@slackUserId>` alone on line 1 to trigger it, then Step 1's
  unattended variant fetches a SINGLE reference Confluence page (not the normal page pair —
  this week's page doesn't exist yet, it's created after the meeting) purely to anchor the
  window start. Step 7 gained a new rule that applies to EVERY run of this skill, not just
  unattended: a ticket gets 1-2 lines under its link only when the title alone wouldn't say
  what happened (bounced status, hotfix, defect found late) — most tickets get nothing,
  sourced first from that week's `~/.claude/standup-notes-<date>.md` files (cheap — the
  token cost was already paid that morning), falling back to a Jira changelog read only for
  a ticket the daily notes don't cover.
  **Step 8 (promote selected This-week tickets to To Do) runs automatically here** —
  deliberately unlike standup's, which stays read-mostly. Mitigated by Step 8's existing
  idempotency (skip anything already at/past To Do, never move backward) and a warning
  logged whenever the pick count exceeds last week's completed count by more than
  `×1.5`/`+3` — the shape a bad pace-guess takes, made visible rather than silent. The one
  write action here with no human gate; the Slack message's own `Promoted to To Do:` line
  is the audit trail.
  **Waits, in the wrapper script, for that same Monday's own daily stand-up note before
  doing any real work** — `sleep 60` then poll up to ~20 more minutes for
  `standup-notes-<today>.md`, proceeding on the changelog fallback if it times out. Two
  reasons, not one, so don't read this as accidental: (1) Thursday/Friday's work has no
  daily-note coverage until THIS SAME Monday's standup run writes it — both fire at 9:00 —
  so waiting closes most of that gap; (2) it staggers the two tasks' `claude -p` launches so
  they don't both append to `sessions.txt`'s session-start log at the same instant, a
  shared-file race in the same family as the concurrent-session issues logged in
  `harness-gaps.md`. The scheduled trigger itself stays a literal 9:00 either way — the
  delay lives in the script, not the schedule.
  Raised Slack-brevity ceiling (`LIMIT_TEAM_MEETING=480`, keyed on the literal
  `*Team meeting notes*` header, first 3 lines; raised again 400→480 2026-08-25 for the
  three new blocks below) — unverified against a real send, same status `LIMIT_STANDUP`
  had before its first live overrun; expect to revisit after the first Monday. Throttled
  to once/day via `~/.claude/harness-state/standup/.team-meeting-notes-lastrun`. No
  dedicated enable key — an empty `user.slackUserId` is the off switch, same convention as
  every other Ping.
  **Same three new sources as standup's, week-window variant** (2026-08-25): client mail
  (`clientMail.domains`), decisions and action items from the Zoom summaries posted in
  the window, and decisions/action items from Slack threads — all read directly by this
  script's own headless run (it does not share a live process with standup's), merged
  into the SAME `~/.claude/harness-state/standup/.standup-action-items.json` ledger standup writes, never a
  second store. Three separate `Client mail`/`Decisions`/`Action items` blocks after the
  Last week/This week ticket lists, each omitted when empty.

### Reading Zoom meeting summaries (Step 3b's mechanism, reusable)

First Zoom read path in this harness — nothing else here touched Zoom before 2026-08-21.

- `mcp__claude_ai_Zoom_for_Claude__hub_get_file_content(fileId, "markdown")` returns the
  whole summary, including a ready-made `## Action Items` section of `- **<Owner>:** <text>`
  bullets. `get_file_content` is the deprecated twin — use `hub_`.
- `fileId` = **first path segment after `/doc/`**, nothing else: `.../doc/AbC123/sheet?x=1`
  → `AbC123`. Both `docs.` and `hub.` hosts serve the same id.
- **Never hardcode a doc id, and never commit one** — a `docs.zoom.example.com/doc/<id>` URL grants
  access to the document, which is why `public-scrub-gate.txt` forbids `zoom.example.com` (the host
  itself is now mapped in `public-scrub-map.txt` so docs can name the shape). Discover ids at
  run time from the Slack channel where they're posted
  (`standup.actionItems.sourceChannel`), taking every link from the most recent posting
  **day** — Monday bundles team meeting + stand-up, sometimes as separate messages.
- Zoom failure **degrades, it never aborts** — deliberately unlike Step 4a. An empty session
  sweep makes a note silently wrong about work that happened; a failed Zoom fetch loses one
  additive section. Different blast radius, different response.
- **Stand-up sources are not just Jira** (Step 3a, added 2026-08-21): **mail sent** in-window
  from `user.email` AND from `user.secondaryEmail` where it cc's the primary (that cc is the
  only reason the other tenant's mail is visible in this mailbox at all) — folded into
  `Yesterday`, merged with its ticket where it has one. Plus the user's **unanswered asks
  on Slack**, over a deliberately wider **7-day** lookback (silent-for-4-days matters more
  than yesterday's), becoming an `*Awaiting reply*` section that is omitted entirely when
  empty. **Deliberately NOT filtered to Claude-sent, because that is not detectable** —
  asked for as "Claude-sent" 2026-08-21, then measured the same day: Claude Code's MCP send
  path adds no attribution footer (only the claude.ai Slack-connector path does), and Slack
  search can't filter on it regardless — a search for the Claude bot mention returned 8
  messages of which 1 contained it. Don't rebuild an origin filter on either signal; scope
  is instead "the message asked something", since an unanswered ask blocks the user whoever
  typed it. "Unanswered" means nobody ELSE posted after it; the user's own follow-up is not
  an answer.
  Needs Slack read tools (`slack_search_public_and_private`, `slack_read_thread`,
  `slack_read_channel`) in `settings.template.json` — note the first reaches **private
  channels and DMs**, which is inherent to the feature (the asks live in DMs) but is a wider
  grant than the stand-up alone requires.
- `ama-aws-notices` — the AWS-platform counterpart to `ama-embs-notices`: weekly sweep of
  AWS Health Dashboard events, support cases, extended-support billing and forwarded AWS
  notice email. Exists because the ElastiCache Redis OSS v4/v5 EOL notice went unactioned
  for months and the extended-support surcharge ran at **~$625/mo, ~$7.5k/yr** —
  measured, not estimated, from `ce get-cost-and-usage` grouped by `USAGE_TYPE`
  (`USE1-ExtendedSupportYr1_Yr2-NodeUsage:cache.m4.xlarge` + `:cache.t3.small`, tapering
  mid-Aug 2026 as the fleet reached redis 6.2). **The Health API is the primary source,
  not the mailbox** — all three account alternate contacts are ClientCorp-owned addresses
  (`AMA@client.example.com`, `cloudsecurity@client.example.com`, `cloudfinops@client.example.com`), so `[Action
  Required]` mail reaches YourCompany only via a manual forward. The skill READS those
  contacts each run and flags drift; **calling `account put-alternate-contact` is
  forbidden** — it would overwrite an ClientCorp governance setting and remove ClientCorp's own
  visibility, on a setting no Terraform covers.
  Two axes, never multiplied into one score: harm tier T1 (prod downtime) / T2 (late
  cost) / T3 (AWS-declared security risk) / T4 (past EOS) / T5 (no action, digest only),
  and a deadline band D0 (≤14d or passed) / D1 (≤90d) / D2 (>90d) / D? (unknown, treated
  as D1). Slack fires on T1-T2 at any band, T3-T4 only at D0/D1.
  Four rules, each traced to a live false verdict found during design: **the
  `eventTypeCode` identifies, never scores** (3× `AWS_ECS_TASK_PATCHING_RETIREMENT`
  spanning 15 production services reads as P1 but its own prose says "There is no action
  required on your part" — routine Fargate platform maintenance, safe while
  `minimumHealthyPercent` is 100, which it is); **the deadline comes from the apply-by
  date, never `startTime` or event age** (an event dated 2026-07-31 carried
  `Apply By 2026-08-30`, `Auto-Update: no`, on `hs-prod-exporter-v3`); **entity count > 0
  is not relevance** (strip the `AWS_ACCOUNT`/`UNKNOWN` sentinels first, then classify by
  name — prod membership is what separates T1 from T5); **never filter by region or
  service in the CLI call** (`--filter regions=us-east-1` silently drops a real eu-west-1
  Lambda retirement dated 2026-11-10, the same dotnet8/9 date
  `SHARED-INFRA-AND-PIPELINES.md` tracks). Two pre-seeded exclusions were tried and both
  proved wrong — eu-west-1 and Lightsail (`poc_featureflag_yourproduct`, AL2, EOS passed
  2026-06-30) — so `AMA-AWS-SURFACE.md` ships its confirmed-exclusions list **empty**, by
  design; entries are earned with provenance.
  Ledger dedupes on **`eventArn` + `lastUpdatedTime`**, with a 12-char description hash
  deciding churn from news: timestamp moved but hash identical → `restamp` in place, no
  re-triage and no re-Slack (this is what stops six year-old `UPDATE_AVAILABLE` events
  re-flagging weekly); hash changed → real re-triage. `add` refuses an undispositioned
  T1/T2, and a `watch` disposition refuses a missing wake-up date. `watch` is earned by a
  distant deadline, never by event age.
  **Six subcommands, and picking the wrong one has teeth.** `add` is idempotent on arn, so
  it NO-OPS on a known event — use **`retriage`** (same 11 args) whenever a row already
  exists, because it is the only path that can move the stored `descHash`. Before it
  existed, an AWS-edited description re-flagged and re-Slacked every week forever, since the
  stale hash never updated. `restamp` moves only the timestamp; `settle` resolves a
  `pending`/`watch` row; `mail-add` records an email-leg finding in a **separate** ledger
  (`~/.claude/harness-state/notices/.aws-notices-mail-seen`) keyed on Gmail message id, because the mail leg
  previously had no dedupe at all and could re-Slack the same forward weekly.
  **Cross-field validation is the point, not per-field.** A band other than `D?` requires a
  real date and a provenance; `D?` requires both to be `-`. Validating fields in isolation
  let 7 live rows reach `D0` (due within 14 days) with no date recorded, while `watchUntil`
  was `-` on all 15 — which made `watchDue`, the only date-driven re-surface mechanism in
  the design, unable to fire for anything at all.
  **Suppression is conditional on `lastrun` existing.** The first real run wrote 15 rows and
  never called `finish`, so the rows existed while `lastrun` did not — which suppressed
  exactly those 15 events at the same time as the nudge hook read "never swept". No
  `lastrun` now means the previous run never closed, so nothing is suppressed and every
  event is re-presented carrying `priorTier`/`priorDisposition`, with `priorRun: "unclosed"`
  on the output.
  **Region stripping uses a real allowlist** from `ec2 describe-regions --all-regions`,
  fetched per run and failing closed. The original shape regex
  `^[a-z]{2}(-[a-z]+)+-[0-9]+$` also matched `hs-prod-1`, `hs-qa-2`, `db-main-2` and
  `es-node-3` — deleting a production node's only entity and leaving the event looking
  sentinel-only and benign.
  **Deadline reminders are DERIVED from the ledger, never stored.**
  `hooks/aws-notices-check.sh` recomputes them every prompt (throttled weekly, appended
  outside the digest/staleness if/else — as a third arm it would only fire in weeks the sweep
  was already overdue) and lists actionable rows dated inside `.awsNotices.deadlineHorizonDays`
  (90), `D?` included. **Selection is on the date, not the stored band** — a band is fixed at
  triage and goes stale as the calendar moves. **Collapsed by ticket key**, since one ticket
  covers many events and a per-row list turned 2 real items into 9 lines, which is how a
  reminder gets muted. Rejected `.pending-followups` (no recurrence field, one row per item to
  rewrite weekly, and a duplicated deadline nothing reconciles) and `watch`/`watchDue` (fires
  once, and its `$9=="watch"` selector can never see a row carrying a ticket key).
  **A dated finding with no Health event needs a `manual:<slug>` ledger row** or it gets no
  reminder at all — ACM emits no Health event, so the single most time-critical finding of the
  2026-08 audit (a production wildcard expiring 2026-10-12) was invisible to the reminder until
  `manual:acm-example-app-wildcard` was added. Same applies to cost-leg and
  support-case findings that carry a date.
  **A failed detail fetch is surfaced, never hashed.** `describe-event-details` errors are
  captured and `failedSet` is read; such an event gets `fetchError` set, no hash, and an
  explicit do-not-triage hint. Hashing the empty string gave a stable value that read as a
  real (empty) description — so an unread event came out either as a benign T5 or, on a
  repeat failure, as "churn".
  Cost leg is **asymmetric on purpose**: the extended-support pattern match has NO
  magnitude floor (the reference miss hid inside a much larger ElastiCache bill), while
  new-usage-type detection DOES (`newKeyFloorUsd`) — measured, comparing against only the
  prior two months surfaced 25 per-region request-tier keys in one run, and 25 false
  positives a month is how a monitor gets muted. Suppressed-below-floor is always
  reported, never silent.
  Config: the `awsNotices` block (`checkDays`, `lookbackDays`, `overlapDays`,
  `slackMinTier`, `watchLeadDays`, `newKeyFloorUsd`, `reportTarget`, `noticeForwarders`,
  `noticeLabels`).
  State: `.aws-notices-{seen,lastrun,nudged,digest,pinged}`, routed through `hstate`
  (`hooks/lib-claude-paths.sh`, PROJ-15342) rather than a literal `~/.claude/...`
  path. Nudged via
  `hooks/aws-notices-check.sh` (sourced from `on-prompt.sh`, once/day) — the PRIMARY
  scheduler.
  **Unattended ping added 2026-08-25** (`AMA-Harness-AWS-Notices-Ping`, weekly Monday
  08:30 (retimed from an initial 11:00 the same day, user instruction), `InteractiveToken`,
  `StartWhenAvailable=True`/`WakeToRun=False` — a fire missed because the machine wasn't
  logged on defers to whenever it next is, but nothing wakes it — `skills/ama-aws-notices/scripts/
  aws-notices-unattended-ping.sh`, direct port of `embs-notices-unattended-ping.sh`'s
  shape (same three-gate skip logic: not overdue, or the in-session nudge already fired
  recently, or its own once-per-`checkDays` throttle) for the same reason: the nudge
  covers everything except no-session-for-weeks, and `.aws-notices-lastrun` had NEVER
  been written before this — no sweep had ever completed to record. **DETECTION only,
  same as <one entry per line; this element only declares the type>'s** — no verdicts, no triage, never writes seen/lastrun; the skill's own
  header states why: "an unattended wrong verdict would mark an event seen forever."
  Unlike the <one entry per line; this element only declares the type> equivalent this one needs no threads-count call first (Health IS
  readable from plain bash, but the ping itself still goes through `claude -p` since
  Slack is MCP-only) — one headless `claude -p --model haiku` DM, that's the whole run.
  `scripts/aws-notices-selftest.sh` (61 assertions) covers the record script's refusal
  gates — including cross-field consistency and the mail ledger — **plus** the plan script's
  `classify_entity`/`roll_up_class` and the region allowlist, sourced out of the script so
  the test cannot drift. Not in `check-gates.sh`, which is for PreToolUse hooks. Run it
  after touching either script. Both it and `support-notices-selftest.sh` back up the live
  ledger and restore it from `*.selftest.bak` on exit; that restore is **not** atomic, so a
  hard kill (Bash-tool timeout, Ctrl+C) used to strand the real data in the `.bak` files and
  leave live state wiped, silently — 2026-08-28 it deleted `.aws-notices-lastrun` and emptied
  `.aws-notices-mail-seen`, un-stamping PROJ-15332's sweep. Both now recover leftover
  `.bak` files at startup, which is the only mitigation that works under SIGKILL. Note the aws
  one takes over two minutes — give it a long timeout rather than letting the default kill it.
  Its sensitivity is checked, not assumed: pointed at a missing record script it fails 46 of
  52, the 6 survivors being the pure classification cases that don't touch it. The earlier
  version asserted only a nonzero exit for negative cases, so deleting the script under test
  passed 12 of 18 — "command not found" is nonzero too. **Keep asserting the refusal
  message, not the exit code.**
  **First sweep closed 2026-08-26** (PROJ-15332): a third calibration gate was added
  covering the **mail leg**, which had no check before — Health carries no event at all for
  two of the AC's three known-positive dates (2026-07-02, 2026-08-07; only RDS has a
  matching event), so gate 1's Health-reachability check cannot stand in for it. All 21
  outstanding candidates from that run were triaged: two settled `stale` only after a
  first-party check overturned the notice prose — `hs-production-zip-files` has no
  expiry/transition lifecycle rule so the S3 replication-vs-lifecycle change cannot bite it,
  and both MWAA environments the Airflow notice names are deleted
  (`mwaa list-environments` → `[]`, a `prod`-classed event pointing at nothing). One new
  ticket, PROJ-15348 (AWS SDK for Java 1.x — attribution, not our own code, likely a
  third-party tool's transitive dependency). `finish` now succeeds and
  `aws-notices-plan.sh` reports `candidateCount: 0`.
  **Audited 2026-08-20 and found incomplete — read `AMA-AWS-SURFACE.md`'s "Structural
  ceilings", "No AWS mail arrives here directly" and "ACM" sections before trusting its
  coverage.** Measured gaps in value order: `trustedadvisor list-recommendations` (143 recs,
  ~51 actionable, **zero** Health overlap, covers all four priorities at once — filter on
  `lifecycleStage` not `status`, or two 2024 `resolved` artifacts alarm forever; the older
  `support describe-trusted-advisor-*` API is a dead end, `UNKNOWN_CHECK_ID_ERROR`);
  `rds`/`docdb describe-pending-maintenance-actions` (47 pending incl. `os-upgrade` on the
  production DocDB clusters — response key is `PendingMaintenanceActions`, not
  `…ActionsDetails`, and the wrong key returns null rather than erroring);
  `acm list-certificates` (Health has **no** approaching-expiry event for imported certs →
  PROJ-15335); `accessanalyzer list-findings` (62 active — with Security Hub
  unsubscribed and GuardDuty/Inspector/Config all off, this plus TA is nearly the entire
  security surface); direct version censuses (22 deprecated Lambda runtimes, 18 prod RDS on
  postgres 14, prod DocDB 4.0). Known SEV-1 defects at audit time: the ledger can hold rows
  with no `lastrun` (suppressing those events while the nudge says "never swept"),
  `descHash` is write-once so a genuinely edited description re-flags weekly forever, and
  nothing cross-validates deadline/D-band/`watchUntil` so `watchDue` cannot fire.
  **Three traps here, all cost real time, all silent:** (1) `end` is a jq keyword and
  jq-1.5rc1 rejects it both as `$end` and as an unquoted object key `end:`, failing with a
  bare "syntax error, unexpected end" pointing at the wrong line; (2) `jq -r` emits CRLF
  on this build, so an unstripped value fails ANCHORED shell patterns (`*-prod`) while
  unanchored ones (`*production*`) still match — it classified two production lambdas as
  `unclassified`; (3) an unquoted `D?` in a `case` is a glob, so `DX` passed a validator
  meant to accept only `D0/D1/D2/D?`. Also: the candidate array carries every event's full
  description, so the final assembly must use `--argfile`, not `--argjson` — the latter
  dies with "Argument list too long" at ~30 events.
- `<amaSupportChannelName>-notices` — third notice monitor, watching the app's own
  `<one entry per line; this element only declares the type>` failure mail (<one entry per line; this element only declares the type> = vendor data,
  AWS = platform, this one = the app itself). Only monitor here with a **data-driven
  cadence**: hourly on a monthly-file processing day, every `postProcessingEveryHours`
  for the `postProcessingDays` after, otherwise `dailyCheckHour` (17:00
  `.supportNotices.timezone`, default SAST) every day PLUS `weekendMorningCheckHour`
  (09:00) on Sat/Sun, PLUS a one-shot **catch-up** tick if no successful run is recorded
  for today by the time any of today's designated hours has passed — a machine asleep at
  the exact designated hour must not silently lose the whole day (`~/.claude/
  .support-notices-lastday`, TZ-local date, stamped only on success so a failing run
  keeps retrying next hour; the sibling `~/.claude/harness-state/notices/.support-notices-failday` throttles
  the digest's `FAILED` line to once/day so that retry doesn't spam it). Catch-up never
  suppresses a scheduled tick — both can fire the same day. **The Scheduled Task itself
  needs no change for any of this** — `AMA-Harness-Support-Notices-Ping` is already an
  hourly, 7-day-a-week trigger; all cadence logic lives in `support-notices-plan.sh`.
  Day classification reads `~/.claude/harness-state/notices/.embs-reminders-synced`
  (the table `ama-embs-reminders` already writes) directly — **no Google Calendar call
  at all**, that file already IS the processing-day table, for free. **Coverage-cliff
  guard**: once `date +%Y-%m` reaches `.embs-coverage`'s ceiling, "no row for today"
  stops meaning "not a processing day" and starts meaning "unknown" — `support-notices-
  plan.sh` exits non-zero with `SCHEDULE-UNRESOLVED` rather than guessing `normal`, which
  would silently downgrade a real processing day from 24 checks to 1. The unattended
  runner DMs this failure directly (not just the digest) for the same reason.
  **Phased on `.supportNotices.mode`, not built as three separate skills.** `construction`
  (current) routes every outbound Slack — ack AND the ETL-owner ping — to
  `targets.construction.ack`, a single DM; nothing is ever posted to `#<amaSupportChannelName>`,
  Slacked to Reviewer One, ticketed, or code-changed regardless of verdict. `live` splits ack/
  etlOwner to their real targets; `createTickets`/`autoFix`/`autoHotfix` gate everything
  past that independently. One config value moves the whole monitor between phases —
  deliberate, so the eventual go-ahead is a config edit, not new code.
  **The headless leg's `--allowedTools` carries neither `Bash` nor `Write`, on purpose.**
  Withholding `Write` alone bought nothing on the standup runner while `Bash` was
  granted — that run reached the same effect by shell redirect (see the standup entry
  above). So here the wrapper script (`support-notices-unattended-run.sh`) does every
  local write — seen ledger, lastrun, lastday, digest — itself, around the headless call; the
  headless leg's only reach outward is one `slack_send_message`.
  Verdicts: `etl`/`sparc` (not ours — ack + a Slack to the ETL owner, <level> level,
  no app-internal detail per the `audiences` policy), `app` (ours — ack + ticket summary
  + diagnosis + fix outline; a SQL error in a report query is the canonical case),
  `no-action` (routine/self-healed/duplicate — never Slacked, but the seen row REFUSES
  an empty reason slug, since an unexplained no-action is a judgment nobody can review
  later). `SKILL.md`'s "Known no-action patterns" section is where confirmed exceptions
  accumulate — the mechanism for "there will be many exceptions" without needing a code
  change per exception. **The unattended runner's prompt explicitly tells the headless
  leg to `Read` that section before verdicting** (`support-notices-unattended-run.sh`) —
  a section that nothing loads is dead weight; adding an entry alone doesn't make it
  apply on the unattended path. First entry: a batch of `Report … was not found` /
  DELETE-500 mails is the `<repository>-api-testing` suite's own cleanup, not a real
  app failure.
  Ledger: `~/.claude/harness-state/notices/.support-notices-seen`, TSV `msgId · received · verdict ·
  disposition · slug`, dedupe on **Gmail message id**. `add` refuses `etl`/`sparc`/`app`
  with a bare `-` disposition (ticket key, `stale`, or `pending` only); `finish` stamps
  `lastrun` only when every candidate has a row, so an interrupted run re-fires — same
  shape as both siblings.
  A raised 250-word Slack brevity ceiling exists for this skill's Phase 1 report, keyed
  off a `Support notification triage:` line on **line 1 only** (unlike the stand-up's
  first-3-lines check, which has to skip a greeting) — see the `slack-brevity-gate.sh`
  entry above for the `limit_kind` bug this shares a numeric ceiling value with.
  Scheduled task `AMA-Harness-Support-Notices-Ping` (hourly, `InteractiveToken`, same
  logged-on caveat as the other three) is the PRIMARY scheduler here, not the nudge —
  cadence is data-driven and no cron expression alone can express it.
  `hooks/support-notices-check.sh` copies `aws-notices-check.sh`'s plain `if/else` shape,
  not `embs-notices-check.sh`'s `return 0 2>/dev/null || exit 0` — reaching that `exit 0`
  while sourced would kill `on-prompt.sh` before its final jq emit and silently drop the
  whole turn's injected context.
- `ama-followups` — works a durable ledger (`~/.claude/harness-state/notices/.pending-followups`) of multi-week
  Slack-reply OR email-reply escalation chains (e.g. "remind at +1wk, escalate to someone
  else at +2wk, act at +4wk if still silent"). `CronCreate` can't carry these — it's
  session-only and auto-expires after 7 days — so the ledger is plain on-disk state
  instead, same shape as `ama-embs-reminders`'s coverage file. Nudged by
  `hooks/followup-check.sh` (sourced from `on-prompt.sh`, throttled to once/day) whenever
  a row's due-date has passed. **Column 4 widened 2026-08-26 to a channel-qualified
  handle** — `slack:<user-id>` or `gmail:<threadId>` (a bare id stays Slack, legacy shape
  still works) — so an email chain doesn't need Slack. The hook itself needed no change:
  it parses column 4 positionally but never reads it, only `id`/`due`/`stage`/`desc` reach
  the notice. Seeded 2026-08-26 for PROJ-15312's ClientCorp confirmation wait — the final
  action on a terminal-stage no-reply can be a ticket transition (Done anyway, with a
  comment recording it closed unconfirmed), not only a message.

`skills/ama/` is a browsing-only index — real symlinks (not junctions; a junction inside
this same repo would double-track the files under two paths) back to each `ama-`-prefixed
skill directory above, purely so `ls skills/ama/` shows the grouped set at a glance. Claude
Code's own skill discovery never looks inside it (it only scans exactly one level under
`skills/`), so it's inert to invocation — the real directories stay flat. Adding a new
AMA_APP-specific skill means creating both the real `skills/ama-<name>/` directory *and*
its symlink here.

**General-purpose — applies regardless of org/fleet:**
`commit-ticket` (+ `commit-ticket-jira`), `resource-efficiency`, `chat-log-reads`, `caveman`, `karpathy-guidelines`,
`rename-topic`, `relocate-session`, `open-chat-file`, `process-prompt-queue`, `write-a-skill`, `verify`,
`grill-me`, `context-hygiene`, `grep-usage`, `bash-command-style`, `bash-command-correctness`
— **split by symptom 2026-08-19**: `-style` is prompts/denials only (all gate-backed),
`-correctness` is "the command ran but the output is wrong" (buffering, `MSYS_NO_PATHCONV`,
heredoc/here-string mangling, node paths, non-ASCII, `sed -i` eating a symlink). The split was
forced by evidence: the buffering rule was broken 3× the same day it was written, because
`-style`'s retrieval description only fires on prompt-shaped problems — while its four
gate-backed rules held 5/5 in the same session. Route a new command gotcha by *the symptom a
reader will have*, not by "it's a bash thing" — `slack-search`,
`harness-setup` itself, `gmail-drafting` — email draft/send requests
must `ToolSearch` for the Gmail MCP first, never CLI-only text or `claude-in-chrome`
browser automation as a substitute; also carries the signature-refetch step (API drafts
get no Gmail auto-sig — fetch the real `class="gmail_signature"` HTML from the NEWEST sent
message, `newer_than:30d`, never a PLAIN_TEXT paste and never a `smaller:` filter, which
biases toward stale mail; gate-backed by `gmail-draft-sig-gate.sh`) and a sonnet proofread
pass for external recipients — which you must WAIT for, not launch and then declare the
draft ready. `list_drafts` `view: DRAFT_VIEW_FULL` **does** return `htmlBody`, so a draft's
signature is verifiable after the fact — an earlier note claiming otherwise was wrong, and
believing it is what let a sig fix ship unverified. **Reply drafts: target the
thread's LAST message and then verify `threadId` via `list_drafts`** — pointing
`replyToMessageId` at an inbound message silently created a draft on a NEW thread
(confirmed live 2026-08-18), and `update_draft` doesn't merely fail to change a reply
target, it **detaches the draft from its thread** (2026-08-19, again 2026-08-20), so the
only fix either way is to recreate. Nudged by `gmail-reply-thread-reminder.sh`.


## Scheduled-task infrastructure (moved 2026-08-31 from AGENTS.md — read before registering/debugging any AMA-Harness-* task)

### Fleet-health check — history & delivery path

**Nightly fleet health check:** a Windows Scheduled Task (`AMA-Harness-Fleet-Health-Check`) checks every repo's pipeline YAML validity and every library's Bitbucket build-counter for reset risk. Results live in `~/.claude/fleet-health/` — `results.log` only shows what *changed* since last run; `latest-build-counter.txt` is the current full snapshot. `ama-library-version-sync` checks this file before computing a new version, so a library with a known counter-reset risk doesn't get bumped straight to `live-build+1`. Its own launcher, `skills/ama-library-version-sync/scripts/run-fleet-health-hidden.ps1`, predates the mechanism below and was originally left un-migrated as a "suspected, not confirmed" gap — **confirmed live, <harnessEpicKey>**: `StartWhenAvailable` caught up a missed 01:47 run at 14:26 while the user was at their desk, and the `-WindowStyle Hidden` outer layer flashed exactly as the other three tasks once did. The task's action now routes through `scripts/run-hidden-generic.vbs` instead (see below) — the script's own internals are unchanged.

**A second, independent bug surfaced by that same incident**: `run-fleet-health-hidden.ps1`'s per-repo loop redirected both `StandardOutput` and `StandardError` and read them sequentially with `ReadToEnd()` before `WaitForExit()` — the classic deadlock if one pipe's OS buffer fills while blocked reading the other. The caught-up run hung for 8+ minutes at ~0 CPU (`Responding: True`, textbook blocked-on-I/O, not slow), and because the task's `MultipleInstances` policy is `IgnoreNew`, it silently swallowed a force-run started under the new wrapper while it sat there. Fixed by reading both streams asynchronously via `OutputDataReceived`/`ErrorDataReceived` events instead of sequential `ReadToEnd()` — the standard .NET pattern for this exact trap. **Caution for next time**: killing the outer `powershell.exe` process does NOT cascade to its bash/node child processes (no job object) — they kept running as orphans afterward and finished independently, racing the real fix's own run against the same output files. Harmless here (same idempotent `mv`-based writes), but worth remembering before assuming "killed the parent" means "stopped the work."

**Fleet-health had NO delivery path at all until 2026-08-25** — the check above wrote deltas to `results.log` and nothing ever read them; 7 findings (6 `RISK` build-counter-resets + one `FAIL mappingtool-web: end of the stream or a document separator is expected (3:1)` YAML parse error) had silently accumulated with nobody notified. Fixed at the source: `fleet-health-check.sh` itself now pings `fleetHealth.reportTarget` on newly-added `RISK`/`FAIL` lines only — never on `OK` churn (543 of 702 log lines are benign build-number `OK`, so "ping on any change" would DM nightly and get muted within a week) — deduped against a `.fleet-health-pinged` state file (the same three `RISK` lines are confirmed to flap `>`/`<` across runs, so dedupe is required, not defensive). One headless `claude -p --model haiku` Slack send per new-finding batch, capped ~10 lines + "and N more", plus a `.fleet-health-digest` line for an open session. State files (`.fleet-health-{pinged,digest,nudged}`, `run-history.log`) route through `hooks/lib-claude-paths.sh`'s `hstate`, not a literal `~/.claude/...` path — see that file's own header (PROJ-15342) for where things actually live now; `results.log`/`latest-*.txt` are unaffected, they stay in `~/.claude/fleet-health/` as the snapshot other skills consult by that literal path. `hooks/fleet-health-check.sh` (sourced from `on-prompt.sh`, once/day) covers the OTHER failure mode a ping living inside the script can't see: the nightly task itself silently stopping (disabled, machine never on at 01:47) — nudges in-session when `run-history.log` is older than 2 days. Config: `fleetHealth.reportTarget` (empty = off, same convention as `embs.noticeReportTarget`).

### VPN DNS probe + check-gates reminder (2026-09-01)

**`AMA-Harness-VPN-DNS-Probe`** (every 10 min, PROJ-15367): `hooks/vpn-dns-probe.ps1` via `run-hidden-generic.vbs`. Detects the IT-7829 fault the output-scraping logger can't see (no failing tool command) — `10.1.0.4` NXDOMAIN while the default resolver answers. Digest `hstate notices vpn-dns-probe.txt`, surfaced un-throttled by `on-prompt.sh` (fault self-heals in minutes); recovery lines carry durations for the ticket. `-SelfTest` prints the verdict without writing. Full mechanics in GATES-AND-HOOKS.md's logger section.

**`AMA-Harness-Console-Window-Watch`** (at logon, resident, <harnessEpicKey>, 2026-09-15): `scripts/console-window-watch.ps1` via `run-hidden-generic.vbs`. Detection-only: one `Get-Process` a second, and when a Claude-spawned `conhost/bash/sh/powershell/pwsh/cmd/taskkill/jq/node/wscript` process has a VISIBLE window, one `Win32_Process` snapshot and a block in `harness-state/logs/console-windows.log` (time, title, rect, console kind, 5-level parent chain). Skips windows whose direct parent is `explorer.exe`/`mintty.exe`. `on-prompt.sh` relays new bytes once (`hstate notices .console-windows-shown`). Background: the blank cascading consoles the user sees during a hook-timeout storm (many sessions × 51 PreToolUse hooks × 5s timeouts → `taskkill /T /F` per tree) were never caught with their owner; everything sampled at moderate load is hidden. Register:
```powershell
$vbs = "<repo>\scripts\run-hidden-generic.vbs"; $ps1 = "<repo>\scripts\console-window-watch.ps1"
$a = New-ScheduledTaskAction -Execute wscript.exe -Argument "`"$vbs`" `"powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"`"$ps1`"`"`""
$t = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$p = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName AMA-Harness-Console-Window-Watch -Action $a -Trigger $t -Principal $p -Settings $s -Force; Start-ScheduledTask -TaskName AMA-Harness-Console-Window-Watch
```
`-SelfTest` runs one tick and prints what would be logged. No cadence, so `check-scheduled-tasks.ps1` never marks it stale; `State: Running` is the liveness signal.

**`AMA-Harness-Defender-Hot-Record`** (on demand, ELEVATED, <harnessEpicKey>): a 120 s `New-MpPerformanceRecording` + `Get-MpPerformanceReport` (+ `typeperf` CPU csv, sanitised MPLog extract) taken WHILE the machine is slow. The task is the elevation boundary, so nothing it executes is user-writable: `scripts/register-defender-hot-record.ps1` (elevated, once; `-Unregister` removes) copies `defender-hot-record.ps1` + `run-hidden-generic.vbs` to `%ProgramData%\AMA-Harnessin` (explicit ACL, Users read) -- NOT Program Files: every path in the inner command line must be space-free and unquoted (quotes do not survive the wscript hop). Retires after `-MaxRecordings` (default 3); 30-min cooldown. Started by `hooks/defender-hot-trigger.sh` (two consecutive bash-start samples >=400 ms) and the watcher; output + `defender-hot.log` in `%ProgramData%\AMA-Harness\defender-hot`, relayed by `hooks/defender-hot-check.sh`. Verify non-elevated: `schtasks /change /tn AMA-Harness-Defender-Hot-Record /tr x` must say Access is denied; `schtasks /run /tn AMA-Harness-Defender-Hot-Record` records (git-bash: `schtasks.exe //run //tn …`).

**`AMA-Harness-CheckGates-Reminder`** (daily 08:50, self-deleting): `hooks/check-gates-reminder.ps1` via `run-hidden-generic.vbs`. Chimes + writes `hstate notices check-gates-reminder.txt` while `hstate notices .check-gates-full-run-owed` exists; `scripts/run-check-gates-full.sh` deletes marker + task on a green suite run, and the task deletes itself if it fires with no marker. Armed 2026-09-01: the vpn-dns-logger fix shipped hand-verified because the machine was fork-exhausted (`0xC0000142`/EAGAIN) and the full suite couldn't run.

**`AMA-Harness-FileClaim-Reminder`** (daily 09:05, self-deleting): `hooks/file-claim-firing-reminder.ps1` via `run-hidden-generic.vbs`. Same shape as the CheckGates one — chimes + writes `hstate notices file-claim-reminder.txt` while `hstate notices .file-claim-firing-owed` exists, deletes its own task once the marker is gone. What clears it is an EVENT, not a person remembering: the first time `cross-session-repo-claim.sh`'s file check actually warns, it removes the marker and writes the firing itself into the same digest, so the good news arrives by the same route as the nag. Armed 2026-09-02 (commit 3a0e68b): the guard is unit-tested but has never been observed warning on a real concurrent commit, and PROJ-15368 stays In Progress until it has. Verified live the same day — task runs (`LastTaskResult=0`) and writes the digest; a simulated firing cleared the marker, wrote the good-news line, and the task deleted itself on its next fire. The clear path is guarded to production (real `CLAUDE_STATE_DIR`, no `FCLAIMS_FILE` override) so `check-gates.sh`, which exercises that very warn branch, cannot clear the live marker.

### Scheduled task DEFAULTS silently skip fires — check these three on every new task

Confirmed live 2026-08-25: `AMA-Harness-Standup-Notes-Ping` never fired on a Tuesday. Not
a code fault, not the 127 — Task Scheduler's own defaults. All five `AMA-Harness-*` tasks
had `DisallowStartIfOnBatteries = True` (Windows' default), and four of five had
`StartWhenAvailable = False`:

| Setting | Default | Why it silently loses a run |
|---|---|---|
| `DisallowStartIfOnBatteries` | `True` | On a laptop on battery at fire time the task **does not start at all** — no log line, no nonzero exit, nothing to find. |
| `StopIfGoingOnBatteries` | `True` | Unplug mid-run and a 15-minute headless `claude -p` is killed partway. |
| `StartWhenAvailable` | `False` | A fire missed because the machine was off/asleep is **never retried** — the next run is the next scheduled slot, a full day later for a daily task. |

All three are now `False`/`False`/`True` on every `AMA-Harness-*` task. **Set them on any
new task too** — `New-ScheduledTaskSettingsSet` does not default to these values, so a task
registered the obvious way inherits the silently-skipping defaults.
`scripts/register-hidden-task.ps1` sets all three by default (added 2026-08-25 — it used
to pass no `-Settings` at all, so anything registered through it got Windows' own
silently-skipping defaults).

`WakeToRun` is a separate, per-task judgment call, not part of the anti-skip default set
— it's the difference between "arrives late" and "arrives on time," at the cost of
waking a sleeping machine. `True` on the two GENERATIVE note tasks
(`AMA-Harness-Standup-Notes-Ping`, `AMA-Harness-Team-Meeting-Notes-Ping`, 2026-08-25 —
catch-up alone only made Tuesday's missed run arrive at 10:32 instead of 09:30, not ON
time). `False` on every detection-only monitor (fleet-health, embs, aws, support) — a
monitor being a few hours late costs nothing, so there's no case for waking the machine.
`register-hidden-task.ps1`'s `-WakeToRun` switch defaults `False` for the same reason.

**Catch-up creates a SECOND failure mode — the post-wake cold start.** With
`StartWhenAvailable` on, a fire missed while the machine slept arrives the instant it
wakes, ahead of the network and the claude.ai MCP connectors. A generative run in that
window dies with "every `mcp__claude_ai_Slack__*` tool is unavailable", which reads as a
broken connector rather than a cold start. Confirmed live 2026-08-25 (user's PC was
off/asleep with no network at 09:30): the 10:32 run failed exactly that way, and a probe
minutes later returned `AVAILABLE` with nothing changed. Two layers now cover it:
`hooks/lib-unattended-ready.sh`'s `wait_until_online` (cheap curl reachability poll,
sourced by both generative Ping scripts before they invoke `claude -p`), plus
`RestartCount=3`/`RestartInterval=PT15M` on both generative tasks so a run that still
lands too early retries itself. Deliberately NOT an MCP probe — verifying the connector
costs a whole extra `claude -p` per run, and these two layers cover the same window free.
`RestartInterval` must be an ISO-8601 string (`"PT15M"`); assigning a `TimeSpan` fails with
"task XML contains a value which is incorrectly formatted".

Diagnostic tell, worth knowing because it looks like nothing is wrong: `Last Run Time`
showing an OLDER date than today while `Next Run Time` shows TOMORROW means today's slot
was skipped outright, not that the task failed — a failure would leave today's date in
`Last Run Time` with a nonzero `Last Result`. `Set-ScheduledTask` can also take minutes to
return while a headless run is in flight; apply settings one task per call, not in a loop.

### `schtasks.exe` from git-bash needs DOUBLED slashes

`schtasks.exe /query …` in git-bash is silently broken: MSYS rewrites `/query` to
`C:/Program Files/Git/query` and the call errors out (`Invalid argument/option`). Under a
`2>/dev/null` that reads as "no task found" — `resume-rate-limited.sh`'s cleanup loop never
found a task to delete and `statusline.sh`'s already-scheduled check always answered no,
for weeks. Write `schtasks.exe //query //tn "<name>"` (every flag doubled), or go through
PowerShell. Confirmed live 2026-08-28. Registration itself already routes through
`register-hidden-task.ps1`, so only query/delete are affected.

### An unattended run refused by a spend/usage limit must say so

Three `<amaSupportChannelName>-notices` fires on 2026-08-25 hit "individual spend limit", did nothing,
and looked identical to "nothing new". Every `claude -p` runner (`standup`, `support-notices`,
`team-meeting-notes`, `embs-notices`, `aws-notices`) now appends a line to
`harness-state/notices/unattended-blocked.txt` when the output mentions a spend/usage/rate
limit; `on-prompt.sh` surfaces that file once on the next prompt and clears it. The limit,
not the data, is then the reported reason.

### Weekly harness-gaps auto-review (`AMA-Harness-Gaps-Review`, added 2026-09-07)

`skills/ama-harness-gaps/scripts/harness-gaps-unattended-run.sh`, task **daily 15:00**,
`InteractiveToken`, `StartWhenAvailable=True`/`WakeToRun=False`, `ExecutionTimeLimit` 72h,
`MultipleInstances IgnoreNew`. Daily rather than weekly on purpose: the weekly usage window's
reset (Tue 08:00 SAST at registration time) may drift, so the runner reads `resets_at` live and
runs only when the reset falls on tomorrow's local date — the last afternoon of the budget week.
Guards in order: live weekly usage (`hooks/lib-claude-usage.sh`; API down → statusline state
file if <24h old, else SKIPPED — unknown is never treated as 0%), reset-is-tomorrow, not
already run for that reset (`harness-state/harness/.harness-gaps-lastrun` holds the reset
date), account-wide usage ≥90% (or every candidate model at its own weekly cap; one capped model is just dropped) → POSTPONED (no stamp; next week's fire runs), zero `- [session ` lines →
stamp and exit. Then two `claude -p` legs on one `--session-id`: plan (`--model opus
--permission-mode plan`, must reply a `PLANNED` line; `.modelUsage` must name an Opus-tier
model or the run fails before executing) and execute (`--resume`, `acceptEdits`, must reply
`DONE` + `---DIGEST---`). Plan saved under `scratch/harness-gaps/`, log
`harness-state/logs/harness-gaps-review.log`, digest `harness-state/notices/harness-gaps-review.txt`
(relayed once by `on-prompt.sh`). Seams: `HARNESS_GAPS_DRY_RUN=1` (print the decision, no
claude), `HARNESS_GAPS_FORCE_RUN=1` (skip the four schedule guards), `HARNESS_GAPS_PLAN_ONLY=1`
(stop after leg 1), `HARNESS_GAPS_NOW=<epoch>`, `CLAUDE_USAGE_JSON=<file>`.

Registration (inline PowerShell — `register-hidden-task.ps1` is one-shot only):
```powershell
$vbs = "<repo>\scripts\run-hidden.vbs"
$a = New-ScheduledTaskAction -Execute wscript.exe -Argument "`"$vbs`" `"bash /c/Users/<user>/.claude/skills/ama-harness-gaps/scripts/harness-gaps-unattended-run.sh`""
$t = New-ScheduledTaskTrigger -Daily -At 15:00
$p = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15) -ExecutionTimeLimit (New-TimeSpan -Hours 72) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName AMA-Harness-Gaps-Review -Action $a -Trigger $t -Principal $p -Settings $s -Force
```

### Biweekly QA backlog sweep (`AMA-Harness-Backlog-QA-Sweep`, added 2026-10-19)

`skills/commit-ticket-jira/scripts/backlog-qa-sweep.sh`, task **every 2 weeks, Monday 09:00**,
same settings as Gaps-Review. Adds every ticket the QA reporter (`backlogQaSweep.reporterName`/
`reporterAccountId`, <uiTesterName>) CREATED since the last good run and that is still Open to the backlog
(`backlog-add-ticket.sh`, section by issue type). Skips anything past Open (shared
`backlog-statuses.sh`, same list `backlog-prune-resolved.sh` deletes by), anything already on main
OR Deferred, Epics. Window = stamp `harness-state/harness/.backlog-qa-sweep-lastrun` (run start,
written only if every add succeeded), else 14d. No LLM for the work; only `claude -p` = haiku Slack
send. Slack DM every run while today <= `backlogQaSweep.slackEveryRunUntil` (trial week, <YYYY-MM-DD: DM every run through this date, failures only after; blank = failures only>),
failures only after. Digest `notices/backlog-qa-sweep.txt` (added/failed only) relayed by
`on-prompt.sh`; log `logs/backlog-qa-sweep.log`. Seams: `BACKLOG_QA_SWEEP_DRY_RUN=1`,
`BACKLOG_QA_SWEEP_SINCE="YYYY-MM-DD[ HH:MM]"`.

```powershell
$vbs = "<repo>\scripts\run-hidden.vbs"
$a = New-ScheduledTaskAction -Execute wscript.exe -Argument "`"$vbs`" `"bash /c/Users/<user>/.claude/skills/commit-ticket-jira/scripts/backlog-qa-sweep.sh`""
$t = New-ScheduledTaskTrigger -Weekly -WeeksInterval 2 -DaysOfWeek Monday -At 09:00
$p = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15) -ExecutionTimeLimit (New-TimeSpan -Hours 72) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName AMA-Harness-Backlog-QA-Sweep -Action $a -Trigger $t -Principal $p -Settings $s -Force
```

### Scheduled tasks must never pop a visible, focus-stealing console

Confirmed live, reproduced three times now (<harnessEpicKey>): launching `bash.exe`/`powershell.exe`
via Task Scheduler in the interactive logon session allocates a NEW, VISIBLE console
window that steals foreground focus — inherent to how a console-subsystem executable's
console gets allocated at process creation, not something Task Scheduler's own action
model can suppress (it has no window-style field at all). This bit for real: three
scheduled tasks (`AMA-Harness-EMBS-Notices-Ping`, `AMA-Harness-Standup-Notes-Ping`,
`AMA-Harness-Support-Notices-Ping`) called `bash.exe` directly with zero hiding, each
firing hourly/daily and popping a window that persisted for minutes (they run headless
`claude -p` internally).

**The first fix attempt — `powershell.exe -NoProfile -WindowStyle Hidden -File …` as the
task's own action — was tried live and confirmed INSUFFICIENT.** It still flashes one
frame: `powershell.exe` is itself a console-subsystem executable, so Windows allocates
its console at process creation, before the PowerShell host can even start running to
apply `-WindowStyle` to itself. `run-fleet-health-hidden.ps1` (the one pre-existing task
that already tried to solve this, undocumented outside its own header, which is why the
lesson never propagated to the other three) uses exactly this insufficient pattern for
its own outer layer — suspected, not confirmed, to still flash; not migrated, see above.

**The mechanism that actually works, confirmed live with zero flash: `scripts/
run-hidden.vbs`, launched via `wscript.exe`.** `wscript.exe` is a GUI-subsystem
executable with no console of its own, and `WScript.Shell.Run`'s window-style parameter
(`0` = hidden) is applied via `STARTUPINFO` at the CHILD process's creation time, before
that child's console exists — there is nothing to flash, for `wscript.exe` itself or for
whatever it launches. Every scheduled task registered from now on MUST route through it:
```
Execute:   wscript.exe
Arguments: "<repo>\scripts\run-hidden.vbs" "bash /c/Users/.../some-script.sh"
```
Exit code of the bash command propagates as `wscript.exe`'s own, so `Get-ScheduledTaskInfo`'s
`LastTaskResult` still means what it already means. Register with `Register-ScheduledTask`/
`New-ScheduledTaskAction`, **`Execute` unquoted** — the same shape that produced a clean
`LastTaskResult 0` for `AMA-Harness-Support-Notices-Ping`, and avoids the
embedded-quotes-in-`Execute` shape suspected of causing Standup's `127` (below).

**`scripts/run-hidden-generic.vbs` is the sibling for a payload that isn't a bare bash
command** — `run-hidden.vbs` hardcodes a `bash -lc "<arg>"` wrapping around whatever it's
given; `run-hidden-generic.vbs` passes its one argument straight to `WScript.Shell.Run`
as the complete command line, unmodified. Used for `AMA-Harness-Fleet-Health-Check`,
whose payload is an outer `powershell.exe -File run-fleet-health-hidden.ps1` invocation,
not a bash command. Quoting note for whichever wrapper you use: each hop (Task
Scheduler → `wscript.exe`'s own argv → `WScript.Arguments(0)`) is a separate argv slot
and needs no escaping: `run-hidden.vbs` still has to double the caller's embedded quotes
once, for the ONE hop where it splices the argument into a larger `bash -lc "…"` string;
`run-hidden-generic.vbs` has no such splice, but if the single argument you're building
for it itself contains a quoted sub-path (e.g. `-File "C:\…\foo.ps1"`), you still have to
double THOSE quotes once when composing the Task-Scheduler-level `Arguments` string, per
ordinary Windows argv-quoting rules (`""` inside a quoted argument = one literal `"`) —
this is the same nested-quote hazard as Standup's `127`, just one layer removed.

For a bash caller that needs to register a task DYNAMICALLY (today, only
`hooks/statusline.sh`'s `schedule_resume()`, for the rate-limit auto-resume one-shot),
use `scripts/register-hidden-task.ps1 -TaskName … -At … -Command …` instead of hand-
building `schtasks.exe /create` — every value arrives as its own separate process
argument, built once inside PowerShell, so there is no bash-side quote nesting at all
(the OLD `/tr "bash \"$HOME/...\""` shape is exactly the nested-quote collapse that cost
Standup its `127`). **`scripts/` is NOT symlinked into `~/.claude`** (unlike `hooks`/
`skills`/`memory`) — resolve the real repo root via
`git -C "$HOME/.claude/hooks" rev-parse --show-toplevel` first. Also confirmed live:
`~/.claude/hooks` is a Windows **junction**, and a junction's `..` resolves relative to
the reparse point's own apparent location for a native Win32 path lookup
(`powershell.exe -File`), NOT the target — `${BASH_SOURCE[0]%/*}/../scripts/…` opens
fine from bash (MSYS resolves it differently) but `powershell.exe` reports it doesn't
exist. Always resolve through `git rev-parse`, never a relative `..` through a junction.

**Mechanically enforced**, not just documented — prose alone already failed to
propagate this once. `hooks/scheduled-task-hidden-gate.sh` (`PreToolUse`, `Bash`/
`PowerShell`) denies any `Register-ScheduledTask`/`New-ScheduledTaskAction`/
`schtasks … /create` call whose command doesn't reference `run-hidden.vbs`, (for the `/xml <file>` form the action lives in the FILE, so since 2026-08-28 the gate reads that file's `<Command>`/`<Arguments>` and applies the same check — it false-denied a correct `/xml` registration on 2026-08-24)
`run-hidden-generic.vbs`, or the pre-existing `run-fleet-health-hidden.ps1` (now only
ever reached FROM INSIDE `run-hidden-generic.vbs`, never launched directly by Task
Scheduler). Deliberately does **not** treat `-WindowStyle Hidden` as a valid escape
hatch, for the reason above. `scripts/check-gates.sh` covers it. Known limit, same class
as other single-call-scoped gates: if an action is built across two separate tool calls,
this can't see the first call's content.


`AMA-Harness-Standup-Notes-Ping`'s `127` (documented lower down as unconfirmed-cause) —
re-registering it through this mechanism produces a real, verified `LastTaskResult 0`
(the log shows it reaching real script logic, `skip: already ran today`, proving bash
executed correctly through the new action) — likely fixed as a side effect of dropping
the embedded-quotes `Execute` shape, though the full body wasn't exercised by that one
test (the daily throttle short-circuited it).

**Update 2026-09-01 — that `LastTaskResult 0` no longer holds, and the caveat above is why.**
The `127` launch failure is indeed gone (the wrapper executes bash correctly), but the task
now reports `LastTaskResult 1`: the *script* runs and fails on its own terms. Its log
(`harness-state/logs/standup-notes-ping.log`) shows `run failed: empty reply -- likely hit
the timeout 1500 timeout mid-run` on both 2026-08-28 and 2026-09-01 — two of the last five
runs. Cap raised to 2700s. Deliberately NOT paired with a retry: the Slack message is sent
before the run replies `DONE`, so a timeout can land *after* the post went out and a retry
would publish the standup twice.

`AMA-Harness-Team-Meeting-Notes-Ping` reports `LastTaskResult 1` for an unrelated reason —
its headless run concluded the claude.ai Atlassian MCP connector was unauthenticated and
that therefore "there is no other way" to do the Confluence steps. There is: `--allowedTools`
already grants `Skill`/`Bash`, and `ama-confluence-api`/`ama-jira-api` are REST +
`$ATLASSIAN_API_TOKEN`. A headless run can never complete an interactive OAuth consent, so
the MCP connector is the one Atlassian path that *structurally* cannot work unattended — the
prompt now says so up front and routes every Atlassian call through the REST skills.

**The general lesson, which cost weeks of blindness: registration is NOT liveness.** A task
can be `State: Ready`, with a plausible `NextRunTime`, and have never once done its job —
`AMA-Harness-VPN-DNS-Probe` was in exactly that state from the day it shipped until
2026-09-01, failing every 10-minute tick on `LastTaskResult 0xFFFD0000`. Two distinct traps
sit here, and the codes distinguish them:

- **The launch failing** — `0xFFF…`, `127`. `wscript` never ran the payload, so the payload
  logged nothing and looked exactly like a quiet system. Cause both times: the stored
  `Arguments` escaped an inner path as `\"` (a bash/C escape) where Windows argv quoting needs
  a doubled `""`. The `""` rule is documented above; `\"` is the specific wrong form to check
  for, and it is checkable *at rest*, which is where it is unambiguous — in the command text
  at registration time a `\"` may be legitimate bash escaping.
- **The payload failing** — any other non-zero. The plumbing works; the script's own logs
  hold the reason (both cases above).

`skills/ama-library-version-sync/scripts/check-scheduled-tasks.ps1` now checks all of this
nightly inside the fleet-health sweep (`\"` in stored args, result-code class, staleness past
a multiple of each task's own cadence, and an action bypassing the hidden wrapper — which
also closes the "built across two tool calls" limit noted above). After registering ANY new
task, run it with `-SelfTest` reasoning in mind: confirm a real `LastTaskResult 0`, never
just a successful registration.
