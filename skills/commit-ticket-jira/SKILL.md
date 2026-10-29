---
name: commit-ticket-jira
context: fork
model: sonnet
background: false
description: Executes Jira WRITE bookkeeping whose content is already decided -- create an issue from a handed-over payload, resolve and apply status transitions, set Fix Version, insert a new Open ticket into the AMA Backlog page. Invoked from commit-ticket with an explicit handoff; runs forked with NO session context. "Does this need a ticket / which ticket / what should it say / ask the user something" is commit-ticket's job, not this one.
---

# Commit Ticket -- Jira writes

Forked executor for [[commit-ticket]]. Runs on a cheap model because every rule here is
mechanical: the judgment (is a ticket needed, which one, what does it say) already happened
in the caller.

## Boundary -- what this skill must NEVER do

- **Never ask the user anything.** Forked, no user channel. Missing/ambiguous field →
  return `NEEDS: <what>` and stop. Caller asks and re-invokes. Never guess a field.
- **Never touch the working tree** -- no `git` anything. Jira/Confluence API only.
- **Never decide whether a ticket is warranted.** Handed "create" → create.

## Handoff contract -- caller supplies, this skill assumes nothing

`repo`, `branch`, `ticketKey` (or `create`), `issueType`, `summary` (prefix already applied
by caller), `description` bullets, `epicLink` or none, `targetStatus` or none, `fixVersion`
or none. Any absent and needed → `NEEDS:`, don't infer.

Frozen-bookkeeping keys -- <harnessEpicKey> (harness) and the Regressions ticket
(`atlassian.regressionsTicketKey`): never create, never transition, never Fix Version,
never comment, no matter what is handed over. Recognize by key and return unchanged.

**`atlassian.harnessTestTicketKey` is the opposite case -- transition it freely.** The
harness test fixture (<harnessTestTicketKey>) exists to BE written to; that is its whole purpose.
It shares only the two exclusions: never on the AMA Backlog page (despite sitting at Open),
never a Fix Version. Never treat it as real work, and never close it.

Reads/queries, user-facing answers, and the post-push QA-verify offer stay in
[[commit-ticket]] -- this skill is writes only.

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
  - Confirmed deployed to prod → **Done**, unconditionally automatic (see "Ticket status transitions" below — stale line pre-2026-08-11 reversal removed here).
- **Epic Link** (`atlassian.epicLinkFieldId` in `harness-config.json`) → optional, contextual. For an actual AMA_APP
  repo, check whether a more specific epic applies and set it if so — leave unlinked
  if none genuinely fits, don't force one just to fill the field. **Never
  <harnessEpicKey>** on a new ticket — that epic gets no sub-tickets at all (see
  [[commit-ticket]]'s "Harness work"; `harness-ticket-gate.sh` denies it). Assignee is the only
  field [[jira-ticket-fields-gate]] mandates at creation — it no longer requires an
  epic link.
- **Description — required sections**, gate-enforced (`jira-ticket-description-gate.sh`,
  presence-only, any wording/heading style):
  - Bug: how to reproduce, acceptance criteria, how to test.
  - Feature/support/task/story: requirements, acceptance criteria, how to test.
  - Bulleted, one line each — no prose paragraphs. Floor not ceiling: context/env/links
    welcome above the required sections. Full templates + filled example:
    `../commit-ticket/TICKET-TEMPLATE.md`. Create through `jira-create-issue.sh`, not MCP
    `createJiraIssue` — the script posts wiki markup to Jira's v2 endpoint; MCP's v3
    would render the markup as literal text.

**Payload path — every write script.** `Write` the JSON to
`~/.claude/harness-state/tickets/.jira-write-payload-<KEY-or-topic>.json`, then pass it as
an env prefix on the SAME command:
`JIRA_PAYLOAD_FILE="<that path>" bash ~/.claude/skills/ama-jira-api/scripts/jira-create-issue.sh PROJ Bug`.
No prefix → script exits 1. The old shared `~/.claude/.jira-write-payload.json` is
RETIRED (2026-09-07) — `claude-dir-clutter-gate.sh` denies it, correctly. A fork reaching
for it reads that denial as a gate bug and stops (hit live 2026-09-17). Full rules:
[[ama-jira-api]].

## New ticket left at Open → add it to the AMA Backlog page

Ticket stays **Open** (not worked now) → add it to the AMA Backlog Confluence page
before calling ticket creation done — page should stay priority-ordered, per user
instruction. Worked immediately this session (Open → In Progress) → skip, backlog is
future work only. Harness (`<harnessEpicKey>`) / Regressions ticket → never applies,
neither is ever created. Mechanics + section mapping + insertion rules: `BACKLOG-PAGE.md`.
Handoff carries `backlogPosition` → run create with `BACKLOG_POSITION=<it>`; missing (no epic)
→ `NEEDS: backlogPosition`, never guess a slot. Epic child → no position, script handles it.

## Actively working a ticket

Claude owns a ticket → move it to **In Progress** the moment ownership starts (picked up,
investigating, planning) — not gated on a code change landing. Same bar as [[commit-ticket]]'s "Create the
ticket at request time".

Unless the user says otherwise. **Does not apply to harness work** — <harnessEpicKey>
never transitions for an individual change (see [[commit-ticket]]'s "Harness work").

**Move it OUT the same turn the work finishes.** Deferring ("close after the prod check") →
`reminder.sh add` whose text names the keys + target status — never a promise in prose.
Backstop: `scripts/stale-in-progress.sh` (daily nudge) lists own tickets idle 3+ days in
In Progress/Review/QA (2026-10-27: 10 RDS tickets left a week). Any session may get it:
skip live-claimed keys, transition only what live state proves, list the rest for the user.
Correctly parked (QA awaiting release cut, peer's slow work) → `--ack KEY...` (hidden 14d);
QA never → On Hold (cut tags by status QA). Other waiting work → Blocked/On Hold, not a comment.
## Ticket status transitions

Work event → ticket may move to:

- PR raised to merge ticket → develop → **Review** (open PR)
- Push / merge code → develop → **QA**. **Ready to Test does NOT apply to a develop push** —
  that's the `release/*`/`hotfix/*` row below, and only that row. No Staging deploy is
  required or expected first; a develop push moves to QA on its own. Don't read the absence
  of a Staging deploy as "no transition yet" (PROJ-15330 sat In Progress for two days
  on exactly that misreading — 9 commits on develop, wrong row of this table applied).
- Push code → master → **Test Complete** — EXCEPT a ticket the tester sent back out of Ready
  to Test: Claude never moves that one to Test Complete. Comment the finding, go back to
  **Ready to Test**, the tester closes it (user rule 2026-10-05, PROJ-15417;
  `test-complete-tester-gate.sh` denies the transition).
- Push code → `release/*`/`hotfix/*` branch, Staging deploy confirmed stable → final
  target: **anything downstream of the change could break** → **Ready to Test** (id
  `10171`, not `QA`'s id `10121` despite similar wording) + testing-steps comment.
  **Four things owed, always — description w/ template headings, testing steps, regression
  notes, where to test (`Test on QA` = develop only, `Test on Staging` = release/hotfix branch).
  `ready-to-test-readiness-gate.sh` DENIES the transition without all four** (fails
  closed; no token / Jira down → denied too). Post the comments BEFORE the transition.
  Regression: high risk → Claude checks in session; brief SEPARATE comment only if the UI
  tester can run it from the UI, else a one-line `Regression: …` in the testing-steps comment —
  low risk still owes that line ([[ama-hotfix]] Step 2a item 3 has the mechanics;
  `memory/ready-to-test-regression-comment.md` the rule). Route on blast radius, NOT on UI-testability — not-easily-UI-testable
  still goes to Ready to Test, its testing steps just become a log/DB/API check. Only a
  change with nothing downstream of it goes straight to → **Test Complete**. Board blocks a direct In Progress → target hop — hop
  `Review` → `QA` → target first (confirm each hop's transition ID via
  [[ama-jira-api]]'s `jira-get-transitions.sh`, don't assume). **Do this automatically
  once Staging is confirmed stable — watch for it, don't wait to be asked** (ticket
  bookkeeping, not a deploy action). See [[ama-hotfix]] Step 2a, the canonical version
  of this — [[ama-cut-release-branch]] Step 3a reuses it.
  **Ready to Test has no Fix-Version sweep of its own** — the Done-sweep query below only
  ever moves the Test Complete subset. A Ready-to-Test ticket leaves via the confirmation
  it's waiting on (someone's manual check, or the infra-change ladder above), not via that
  sweep — don't read it as stuck just because the sweep skipped it.
- **Committing a fix directly onto an already-cut `release/*`/`hotfix/*` branch → also
  set that ticket's Fix Version to the branch name** (`fixVersions: [{"name":
  "release/128.0.0"}]`, exact match), same as [[ama-cut-release-branch]]'s Step 3a bulk
  sweep does for tickets included at cut time — a ticket added later needs the same tag,
  not just a status change. Version missing in Jira → create it yourself
  (`jira-version.sh create`), then `bash ~/.claude/hooks/confirm-jira-version.sh <version>`. Never ask user.
- **Reverse case: picking up a ticket whose Fix Version ALREADY names an outstanding
  `release/*`/`hotfix/*` branch → commit/merge the fix there automatically, don't ask.**
  Check the Fix Version before starting work. It matching a live branch already answers
  [[ama-deploy-release]]'s "Mid-release UI fix" question (for the release vs.
  develop/QA) — only ask there when Fix Version is unset/ambiguous.
- **Infra/config change live in prod, no code artifact** (SG rule, DNS record, Octopus
  var, IAM change) — the change IS the deploy. No build, no Fix Version, never routes
  through the Test Complete sweep below (it has no version to tag). Verify it live, then:
  nothing outstanding → **Done** direct. Blocked on a third party confirming → **Ready to
  Test** + comment naming who owes what + link the thread, then seed a
  [[ama-followups]] ledger row (weekly check-in). Done when they confirm; Done anyway,
  comment why, at the ladder's terminal stage if they never do.
  `hooks/prod-infra-change-ticket-reminder.sh` is the mechanical backstop — fires on a
  mutating cloud CLI/API call, same shape as `ticket-worked-while-open-gate.sh` but for
  work with no commit to hang off.
- No Done transition offered from QA (seen: backbone Terraform tickets) → Test Complete,
  then "Deployed Prod" (= Done). Ids per-ticket, re-read `jira-get-transitions.sh` between.
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
- **Hotfix ticket: Done ≠ Closed.** Hotfix's own prod deploy → Done only, same as any
  other ticket. → **Closed** only when the NEXT scheduled release deploys to prod (e.g.
  hotfix/129.0.x closes on release/130.0.0's prod deploy, not its own). [[ama-deploy-
  release]] Step 7a's Done-sweep for a release must also sweep prior open hotfix
  tickets (Done, older fixVersion) to Closed in the same pass.
- A `git push` to master/develop/`release/*`/`hotfix/*` triggers a reminder
  ([[git-push-ticket-reminder]] hook) naming the session's resolved ticket and the
  expected status — it can't verify Jira's live state (no read access), so it nudges
  every matching push; check the real status yourself before acting on it.
- **Harness work in `~/.claude` itself** → no ticket lifecycle at all (see [[commit-ticket]]'s "Harness
  work") — commit against <harnessEpicKey>, update `AGENTS.md` (and `README.md`
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
2. Run [[ama-jira-api]]'s `jira-transition-fields.sh <key>` (not `jira-get-transitions.sh` —
   that trims away the transition's own `fields` metadata; MCP retired 2026-08-31) and
   check the target transition's required-fields column — empty means no required field
   exists at all, full stop, regardless of what the error text implied.
Only treat it as a genuine missing-field problem if the status truly didn't change AND
the transition metadata actually lists a required field — and if so, name that field
specifically rather than asking the user to guess it blind.
