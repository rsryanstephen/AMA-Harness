---
name: commit-ticket
description: Use when Claude commits, pushes, merges, raises a PR, creates/transitions a Jira ticket, or writes/amends a commit message or ticket status. ALSO use at the start of any new substantive task (real fix, feature, investigation, infra change) to create/resolve its ticket immediately. ALSO use on noticing a real defect while working on something unrelated. ALSO use when a fix is for a regression.
---

# Commit Ticket

Every commit ties to a ticket. Commit message starts with ticket number.

## Found an issue along the way?

A real, still-open defect in AMA_APP code (not a scoping call like "that's task #48" or
"someone else's file") found while working on something unrelated → don't just flag it in
the reply and move on, a flag with no chosen action is as good as never finding it. Same
turn, pick one: raise a Jira ticket now, or — if it looks minor — ask the user: ticket
separately, leave it, or fix now despite being out of scope.

Several related incidental findings from one sitting → one ticket, not one each (see
consolidation rule below).

A bug in `~/.claude` harness tooling itself → `harness-gaps.md`, not Jira — don't ticket that.

## `git push`/fetch/clone failing on a bitbucket.org remote — check these first

- `ssh: connect to host bitbucket.org port 22: Network is unreachable` (hangs, not an
  error) → this network blocks outbound port 22. Already fixed in `~/.ssh/config`
  (routes over `altssh.bitbucket.org:443`) — if it recurs (new machine, config reset),
  reapply the same fix, don't re-diagnose as auth.
- DNS resolution failing (any host, not just bitbucket.org) → transient VPN-DNS blip:
  keep polling until it clears, backing off the interval as it drags on (10s → 30s →
  1m → 5m → 15m). Don't stop and hand back to the user. If it drags on badly, append
  the evidence (timestamps, resolver, hostnames) to the not-yet-sent draft IT ticket at
  `~/.claude/IT-TICKET-VPN-DNS-bitbucket.md`.
- This is git-over-SSH transport only — a different layer from Bitbucket's REST API
  (Pipelines status, triggering a run), see [[ama-bitbucket-api]] for that.

## Harness work (`~/.claude`) — NO new ticket, ever. Commit against <harnessEpicKey> directly.

Reversed twice already, now mechanically enforced (`harness-ticket-gate.sh` denies any
`createJiraIssue` whose Epic Link is <harnessEpicKey>). **Do not reverse this again
without the user saying so in those exact words.**

Every harness change: commit message is `<harnessEpicKey>: <description>` — same epic
ticket every time, never a new sub-ticket. No status transition (the epic isn't
"worked" by one change), no comment on any ticket. Keep
`ama-claude-harness/AGENTS.md` current instead (`README.md` too, but only when the
change is human-visible) — see `harness-memory`'s `ama-harness-no-epic-comments` note
— that's what future adopters actually read.

## Create the ticket at request time, not commit time

Waiting for a commit/push/PR moment leaves real work (investigation, infra changes,
debugging) untracked — or never ticketed at all if no commit ever happens.

- **New substantive request** (a real fix, feature, investigation with findings worth keeping, infra/code change) → create/resolve its ticket **immediately**, before starting the work. Don't wait for a commit/push/PR moment.
- **Not every message needs this** — a quick question, a status check, continuing an already-ticketed task doesn't need a fresh ticket. Judge it: would this be worth a Jira comment/record if someone asked "what was done and why"? If yes, it needs a ticket now, not later.
- Ticket already exists for this thread of work (explicitly named, or clearly the same task as an already-ticketed one earlier in the session) → reuse it, don't create a duplicate.
- This doesn't replace the commit-time check below — it's a backstop for whenever the request-time step got skipped or the scope changed mid-task.

**No code/config change at all → no ticket, unless the action itself is important or
dangerous.** A redeploy with zero code change (re-running an existing build/release,
restarting a service) tracks nothing. Default to no ticket for read-only checks, status
queries, or an action that doesn't alter code/config/data.
Exception: the action's own risk still warrants one even with no diff — e.g. a
Production deploy or redeploy, a database operation, anything [[ama-deploy-release]]-
shaped — track *that it happened*, not a code change.

**Consolidate related work into one ticket — don't fragment.** Before creating a new
ticket, check whether a ticket already opened THIS SESSION covers the same
skill/repo/theme — if yes, reuse it (reopen if already wrapped), don't create another.
Small skill-doc tweaks, corrections, and cleanup items from one continuous sitting
default to ONE ticket for the whole sitting, not one each. Only split when a change is
a genuinely independent defect or distinct feature someone would want to
review/revert/track apart on its own — not merely "a different file" or "a different
paragraph."

**A bug caused by a previous fix → reopen that ticket, don't raise a new one.** If
root-causing today's bug traces it back to a specific earlier ticket's change (a
regression, not a new independent defect), bring that ticket back to **In Progress** and
commit the current fix against it — same ticket, not a fresh one. Only raise a new ticket
if the causal link is genuinely unclear or the earlier ticket can't be identified with
confidence — don't force a match that isn't real just to avoid creating a ticket.

**Recent regression, causing ticket NOT identifiable → the generic Regressions ticket
(`atlassian.regressionsTicketKey`, currently <regressionsTicketKey>), not a new ticket.** This
only applies when the rule
above doesn't — a causing ticket found with confidence still wins, reopen it instead.
"Recent" = introduced within roughly the last 3 releases. Cheap, usually-available bar
(no blame-hunting/git archaeology required): the regressed behavior belongs to a feature
or change that shipped in one of the last 3 releases. Resolve the window live, never
hardcode version numbers — `GET /rest/api/3/project/PROJ/versions`, keep only names
matching `release/<N>.0.0`, numeric-sort on `N` (the list isn't returned in order and can
contain junk entries), take the 3 most recent released ones plus any in-flight branch
above them.
- Not sure whether it's recent enough / whether it qualifies → **ask the user**: new
  ticket for this fix, or under the Regressions ticket. Wait for the answer, don't guess.
- Regression older than ~3 releases → ordinary new ticket, unchanged behavior below.
- Routing to the Regressions ticket skips the `On QA: `/`On Prod: ` prefix question
  entirely (below) — no ticket is being created, so there's no title to prefix.
- The Regressions ticket never transitions status, never gets a Fix Version, never gets a
  per-fix comment — same frozen-bookkeeping shape as <harnessEpicKey> for harness work (see
  "Harness work" above), except it's parked at **Open**, not In Progress — a Bug/Task
  sitting at In Progress forever would show up permanently in the "pick up tasks" `status =
  "To Do"`-adjacent queries and any bare status-column query below. Don't apply the usual
  "Claude owns it → In Progress" rule to this ticket.
- Still record it via `set-session-ticket.sh` like any other resolved ticket (see below) —
  that part is unconditional.

## Workflow

1. User asks to commit. Ticket named? → use it.
2. Ticket only described (not an exact key) → search first: `project = PROJ AND text ~ "<keywords>" ORDER BY updated DESC`. One strong match → confirm briefly, don't silently guess. Multiple → list them. Zero → fall through to step 3.
3. No ticket named or found → **hard stop before committing** — don't guess, don't commit-then-flag-it-in-a-note. Ask, and wait for the answer:
   - Which existing ticket does this change relate to? OR
   - Should a new ticket be created?
4. Have ticket → commit message format:
   ```
   PROJ-XXXXX: <description of fix>
   ```
   `PROJ-XXXXX` = real ticket number. Description = short, imperative.

## Record the resolved ticket for this session — every repo, not just `~/.claude`

Every time a ticket gets resolved for the current task (new or reused, any repo, not
only harness work): `bash "$HOME/.claude/hooks/set-session-ticket.sh" "<cwd>" "<this
session's chat log filename>" PROJ-XXXXX`.

Universal — not just harness commits — so [[context-hygiene]]'s task-switch hint can
fire for ordinary ticket work too.

## Rules

- Never commit without a ticket ref resolved first — this means STOP before the commit, not commit-then-apologize.
- A later push/cherry-pick/rebase that carries a no-ticket commit forward has the SAME obligation as the original commit — check the commit message before pushing, not just before committing the first time.
- Ticket number leads the message, colon + space, then description.
- Applies to every repo, every session.

## Creating a new ticket

- **Assignee** not specified → default to the user (Your Name / you@example.com — mirrored as `user.displayName`/`user.email` in `~/.claude/harness-config.json`; swap both for a different adopter). Never leave unassigned.
  - Jira's assignee field needs an **accountId** (opaque GUID), not an email. Read it straight from `user.jiraAccountId` in `harness-config.json` — don't call `lookupJiraAccountId`/an email search to re-resolve it, it's stable and already cached there. Field empty/missing → resolve once via `lookupJiraAccountId`, then write the result back into the config file so it's never looked up again.
- **Status**: every new ticket stays at Jira's raw default **Open** — do NOT auto-transition
  it to To Do at creation (reversed from an earlier convention, per explicit user
  instruction). This is deliberate, not an oversight: **Open = raised/backlog, To Do =
  explicitly promoted when selected for the current week's work** (see
  [[ama-team-meeting-notes]]'s "This week" step) — a distinct, later event, not something
  that happens automatically at creation. Then, if the situation warrants it:
  - Work not started yet → stays **Open**.
  - Claude starts working on it immediately in the same session → the "Actively working a
    ticket" rule below still applies as normal (Open → **In Progress** directly, no need to
    pass through To Do first).
  - Work already done at creation time (e.g. creating the ticket retroactively for something just shipped) → apply the normal status-transition rules below AS IF the event already happened, not a blind default. Don't leave it at Open when the real state is further along.
  - Confirmed deployed to prod → **Done** — but only on the user's explicit confirmation (see below), never inferred.
- **Epic Link** (`atlassian.epicLinkFieldId` in `harness-config.json`) → optional, contextual. For an actual AMA_APP
  repo, check whether a more specific epic applies and set it if so — leave unlinked
  if none genuinely fits, don't force one just to fill the field. **Never
  <harnessEpicKey>** on a new ticket — that epic gets no sub-tickets at all (see
  "Harness work" above; `harness-ticket-gate.sh` denies it). Assignee is the only
  field [[jira-ticket-fields-gate]] mandates at creation — it no longer requires an
  epic link.
- **Description — required sections**, gate-enforced (`jira-ticket-description-gate.sh`,
  presence-only, any wording/heading style):
  - Bug: how to reproduce, acceptance criteria, how to test.
  - Feature/support/task/story: requirements, acceptance criteria, how to test.
  - Bulleted, one line each — no prose paragraphs. Floor not ceiling: context/env/links
    welcome above the required sections. Full templates + filled example:
    `TICKET-TEMPLATE.md`. Create through `jira-create-issue.sh`, not MCP
    `createJiraIssue` — the script posts wiki markup to Jira's v2 endpoint; MCP's v3
    would render the markup as literal text.

## New ticket left at Open → add it to the AMA Backlog page

Ticket stays **Open** (not worked now) → add it to the AMA Backlog Confluence page
before calling ticket creation done — page should stay priority-ordered, per user
instruction. Worked immediately this session (Open → In Progress) → skip, backlog is
future work only. Harness (`<harnessEpicKey>`) / Regressions ticket → never applies,
neither is ever created. Mechanics + section mapping + insertion rules: `BACKLOG-PAGE.md`.

## Actively working a ticket

Claude owns a ticket → move it to **In Progress** the moment ownership starts (picked up,
investigating, planning) — not gated on a code change landing. Same bar as "Create the
ticket at request time" above.

Unless the user says otherwise. **Does not apply to harness work** — <harnessEpicKey>
never transitions for an individual change (see "Harness work" above).

## Picking up tasks in a new session

User says "pick up tasks" / "what should I work on" / similar → query **To Do**
specifically, not Open:
```jql
project = PROJ AND assignee = "<user.jiraAccountId from harness-config.json>" AND status = "To Do"
```
Run via [[ama-jira-api]]'s `jira-search.sh`, fields `key,summary` — just enough to
list and pick from. Only To Do tickets are "ready to start now" — don't also pull in
Open ones (see the Open-vs-To-Do rule under "Creating a new ticket" above).

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

## Old/foreign ticket picked up → verify premise first, not just work it

Trigger: ticket `created` >2y ago (resolve live, `created <= -730d`, never hardcode a
date) OR `reporter` != `user.jiraAccountId` (`harness-config.json`) — condition may no
longer hold.

- Bug/fix → test if condition still reproduces BEFORE fixing. Use [[verify]] /
  [[ama-ui-verify]] / [[ama-report-debug]] for the how, by area — don't re-derive repro
  steps here.
- Feature/requirement → confirm with user it's still wanted before working.
- Verified absent, or user confirms not wanted → **cancel automatically** (user
  instruction): comment the evidence, transition to Cancelled/Won't Do (resolve via
  `jira-get-transitions.sh`, may take hops; none offered → ask user, don't force a
  status), remove from AMA Backlog page (`BACKLOG-PAGE.md`), tell user it was
  cancelled.
- Couldn't verify (no env/access) ≠ absent — say which, then ask user. Never cancel on
  "couldn't verify."

## "What tickets are in column/status X?" — default to the user's own, don't ask

A bare `project = PROJ AND status = X` search reliably includes noise a real
board never shows. Default `assignee = currentUser()` on every bare column/status query — don't
ask first, don't present the unscoped result as the board's truth. Only drop that
filter if explicitly asked for everyone's/the whole team's/all devs' tickets.

[[ama-deploy-release]]'s Step 0b layers a `fixVersion` filter on top of this for the
release-specific follow-up question ("are this release's tickets done?") — a further
refinement, not a substitute for the default assignee scope above.

The [[jira-ticket-fields-gate]] hook (assignee required at ticket creation, see
"Creating a new ticket" below) is what keeps this scoping question answerable at all —
an unassigned ticket can't be excluded by any scope filter.

## Creating a ticket

Fix routes to the Regressions ticket (see above) → skip this whole section, no ticket is
being created.

Need to create a ticket and it's a bugfix → ask user: bug only on QA, or on prod?

- Only on QA → title prefix `On QA: `
- On prod → title prefix `On Prod: `

E.g. `On QA: FieldTableMapper crashes resolving ConnectionManager`.

## Ticket status transitions

Code event → ticket may move to:

- PR raised to merge ticket → develop → **Review** (open PR)
- Push / merge code → develop → **QA**
- Push code → master → **Test Complete**
- Push code → `release/*`/`hotfix/*` branch, Staging deploy confirmed stable → final
  target: testable by a human → **Ready to Test** (id `10171`, not `QA`'s id `10121`
  despite similar wording) + a comment with testing instructions, otherwise →
  **Test Complete**. Board blocks a direct In Progress → target hop — hop
  `Review` → `QA` → target first (confirm each hop's transition ID via
  [[ama-jira-api]]'s `jira-get-transitions.sh`, don't assume). **Do this automatically
  once Staging is confirmed stable — watch for it, don't wait to be asked** (ticket
  bookkeeping, not a deploy action). See [[ama-hotfix]] Step 2a, the canonical version
  of this — [[ama-cut-release-branch]] Step 3a reuses it.
- **Committing a fix directly onto an already-cut `release/*`/`hotfix/*` branch → also
  set that ticket's Fix Version to the branch name** (`fixVersions: [{"name":
  "release/128.0.0"}]`, exact match), same as [[ama-cut-release-branch]]'s Step 3a bulk
  sweep does for tickets included at cut time — a ticket added later needs the same tag,
  not just a status change. Version doesn't exist in Jira yet → same gap as Step 3a, no
  tool here creates one, ask the user to add it, don't guess a workaround.
- **Reverse case: picking up a ticket whose Fix Version ALREADY names an outstanding
  `release/*`/`hotfix/*` branch → commit/merge the fix there automatically, don't ask.**
  Check the Fix Version before starting work. It matching a live branch already answers
  [[ama-deploy-release]]'s "Mid-release UI fix" question (for the release vs.
  develop/QA) — only ask there when Fix Version is unset/ambiguous.
- Deployed to production → **Done** — **unconditionally automatic, not gated on
  asking the user first** (reversed 2026-08-11 per explicit user instruction — this
  line previously required checking with the user before every Done transition;
  PROJ-15294's hotfix/128.0.2+128.0.3 only reached Done because the user asked
  after the fact). Once Claude's own verification confirms the deploy actually landed
  — the ECS task-definition **image tag** matches the deployed version, never inferred
  from health alone, see [[ama-octopus-deploy]]'s deployed-vs-running rule — sweep the
  Fix-Version-scoped tickets from Test Complete to Done:
  `project = PROJ AND fixVersion = "<release/hotfix branch>" AND status in (Done, "Test Complete")`,
  transition only the Test Complete subset (`jira-get-transitions.sh` first, don't
  hardcode the id). This is [[ama-deploy-release]]'s Step 7a, already **mandatory,
  not an offer** there for full releases — [[ama-hotfix]] Step 4 reuses that exact
  step for hotfixes, so it is equally mandatory there. The
  `octopus-prod-deploy-ticket-sweep-reminder.sh` hook (`PostToolUse` on
  `Bash`/`PowerShell`) is the mechanical backstop — fires on the production deployment
  API call itself, since self-recognition alone missed this once already.
- A `git push` to master/develop/`release/*`/`hotfix/*` triggers a reminder
  ([[git-push-ticket-reminder]] hook) naming the session's resolved ticket and the
  expected status — it can't verify Jira's live state (no read access), so it nudges
  every matching push; check the real status yourself before acting on it.
- **Harness work in `~/.claude` itself** → no ticket lifecycle at all (see "Harness
  work" above) — commit against <harnessEpicKey>, update `AGENTS.md` (and `README.md`
  if the change is human-visible), done. This
  reminder hook still fires on a harness push (it can't tell harness from ordinary
  AMA_APP work) — recognize the push as harness-shaped and skip the status-transition
  advice, don't force one.
- **The Regressions ticket** (see above) → same no-lifecycle treatment: no transitions,
  no Fix Version, no comments, ever, no matter how many fixes land against it.
  `git-push-ticket-reminder` and `jira-fixversion-confirm-gate` still fire on a push
  against it (same blind spot as the harness case) — recognize it by key and skip the
  advice, don't force a transition or a Fix Version onto it.

Target status not offered from current status → step through intermediates, and there
can be more than one hop (e.g. Open → To Do → Review → QA) — re-check [[ama-jira-api]]'s
`jira-get-transitions.sh` after each hop rather than assuming the next one reaches the
target.

**A transition ID is per-ticket, never reuse one seen on a different ticket** — even for
the same-named target status, a reused ID fails SILENTLY (status unchanged, no error).
Always run `jira-get-transitions.sh` for the specific ticket you're transitioning.

**Ticket already further along than the target → leave it, don't force it backward.** A
ticket at Test Complete/Ready to Test is already past QA in the workflow; there's
usually no backward transition, and moving it "back to QA" isn't meaningful anyway.

**A transition rejected with "missing required information" is not necessarily about a
missing field — don't blindly retry.** The call can have already succeeded
server-side; a retry then fails for a DIFFERENT reason (ticket no longer in that state),
surfacing as the same misleading error text. Before concluding a field is actually
missing:
1. Re-fetch the ticket's current status — the transition may have already succeeded
   despite the error-looking response.
2. Call the MCP `getTransitionsForJiraIssue` (not `jira-get-transitions.sh` — this
   needs the transition's own `fields` metadata, which the trimmed script doesn't
   carry) and check the target transition's `fields` — `{}` means no required field
   exists at all, full stop, regardless of what the error text implied.
Only treat it as a genuine missing-field problem if the status truly didn't change AND
the transition metadata actually lists a required field — and if so, name that field
specifically rather than asking the user to guess it blind.

## After pushing to develop — offer to verify the QA deployment (ECS-backed API services only)

Pushing to `develop` on an AMA_APP API-service repo (not `admin`/`exporterplus` — S3-hosted
frontends, no runtime to check) triggers an automatic QA deployment behind the scenes.
**Offer** to verify it landed clean (steady state, no crash-loop, no error-log spam) —
**never unprompted**, wait for explicit yes/no, run from the MAIN session not a subagent.
Gate-enforced (`deploy-verify-confirm-gate.sh`) — see [[ama-cloudwatch-search]]'s
`DEPLOY-VERIFICATION.md` for the full mechanism.

**`admin`/`exporterplus` skip this AWS check but aren't exempt from verification** — they
carry their own PRE-push gate instead (self-verify → fix loop → user local sign-off,
before the push even happens) — see [[ama-ui-verify]]'s standing rule, don't push first
and check after like the API-service case above.

## Leave context for future agents, before considering an AMA_APP task done

A durable USER preference, correction, or project fact (not architecture/bug-class) →
that's [[harness-memory]]'s job, not this section — see its boundary rule.

**Skill-based, not `CLAUDE.md`.** `CLAUDE.md` is loaded once at session start, but that cost is unconditional — every future session opened in that repo pays for the WHOLE accumulated file from the first turn, whether or not that session's task has anything to do with what's in it. A skill only loads when the Skill tool actually judges it relevant. Never write to a repo's `CLAUDE.md` for this — use a skill instead, e.g. `~/.claude/skills/ama-debugging-notes/` with one reference file per repo/topic, so a session only pays for the one file actually relevant to its task, not the whole accumulated set.

Two different bars, not one — this is the part that actually controls bloat, not the file format:

1. **Repo/architecture-type context** (how a repo's API service or library is actually wired, a branch/version convention, a library's real API surface for the version in use) → **add somewhat liberally**, into [[ama-architecture-notes]] (companion skill to this one, AMA_APP-fleet-wide, one reference file per repo/topic). **Check first whether a more specific companion skill already owns this exact topic** (release/deploy mechanics → [[ama-cut-release-branch]]/[[ama-deploy-release]]/[[ama-octopus-deploy]], not here) — add there instead, even mid-investigation. Worth a quick `~/.claude/skills/` glance if unsure, since a skill from a concurrent session isn't automatically known. This describes structural facts that keep mattering for ANY future work in that area, not one bug. No need to ask first when it clearly took real investigation to find (not obvious from a quick read). **Durable class, not point-in-time state**: before writing, ask "will this still be TRUE, not just outdated, once the current work finishes?" A mid-upgrade snapshot ("5 repos still on the old pipeline tag") goes actively FALSE the moment the upgrade lands — keep the general lesson ("pipeline image tags can drift independently per-step, check all of them"), drop the specific snapshot (which repos, which versions, right now). If a specific instance is still-open real work, that's rule 3 below (a ticket), not a note here.
2. **Bug-specific context** (the root cause and fix of one particular incident) → **very conservative, opposite default**, into [[ama-debugging-notes]] (companion skill, reoccurring-bug-CLASS patterns only, one reference file per repo/topic) when the class is AMA_APP-specific — or another skill's reference file if it's a tool/system-specific known signature (e.g. [[ama-graylog-search]]'s `KNOWN-SIGNATURES.md`). Only add if it's a genuinely GENERIC bug class likely to reoccur — not "this exact thing happened once" (a one-off, self-resolving VPN/DNS hiccup doesn't qualify). Test before adding: could the SAME class of bug plausibly happen again in a DIFFERENT instance (different field, different repo, different exact symptom), not just "could this literal incident repeat"? If it's really "how does the DI container / a library API / a branching convention behave" wearing a bug-report costume, it's actually category 1, not this one. **Always ask the user before adding**, propose which reference file it'd go in, state why it's genuinely a reoccurring class, and wait for confirmation.
3. A genuinely still-open, unfixed bug found while investigating something else (not a pattern to recognize later, just a real defect sitting in the code) → see "Found an issue along the way?" above. Don't file it away as "documentation" instead of surfacing it as work to do.
4. Keep additions terse, high-signal, caveman style — same as every skill file. This is architecture/pattern context for navigating the codebase faster next time, not a blow-by-blow of what was fixed (the commit message and Jira ticket already own that).
5. **Terse ≠ vague.** Brief enough to avoid bloat, never so brief another agent could misread it. A concrete example (real file:line, real error signature, real version number) beats a short abstract sentence — it's often shorter AND clearer, not a tradeoff between the two.
6. **Scale length to severity, not to how interesting the investigation was — and severity justifies including a fact, not narrating it at length.** A minor gotcha earns a few lines (symptom substring + fix); even a genuinely severe bug still gets terse treatment (the rule, the fix, one compressed evidence tag), not a full incident retelling. Give a tangential extra finding its own short line, or drop it. **Concrete self-check**: before finalizing any addition, compare its length against 2-3 neighboring entries in the same file — noticeably longer is the signal to trim, regardless of how significant the fact is. Applies to your own draft in the same turn you write it, not just to auditing someone else's leftover note (rule 7).
7. **Another concurrent session's uncommitted note found in these skills → audit it (this section's bar, plus style/length), then commit it automatically if it passes — don't leave it sitting uncommitted or wait to be told to commit each time.** Only fix or drop what fails the audit (point-in-time state written as if durable, too verbose, vague, wrong file). Commit message notes it was written by another session and audited before committing.
