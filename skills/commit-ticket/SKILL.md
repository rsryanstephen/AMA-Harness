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

**`git push`/fetch/clone failing on a bitbucket.org remote** (port 22 unreachable, DNS NXDOMAIN) -> `GIT-TRANSPORT.md`. Read it when a git transport call fails, not before.
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

**This fix is for a regression** (a bug caused by an earlier fix) -> `REGRESSIONS.md`: reopen the causing ticket ONLY if unreleased (released -> new linked Bug), or route to the generic Regressions ticket. Read it only when the bug traces back to a previous change.
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

## Jira writes go to the forked executor -- [[commit-ticket-jira]]

Ticket creation fields, status transitions, Fix Version, backlog-page insertion:
[[commit-ticket-jira]]. Forked + cheap model, no session context -- so THIS file decides and
DRAFTS, that one posts.

Hand over: `repo`, `branch`, `ticketKey` or `create`, `issueType`, `summary` (prefix already
applied, see "Creating a ticket" below), `description` bullets, `epicLink`, `targetStatus`,
`fixVersion`. It returns the key, or `NEEDS: <field>` -- then YOU ask the user, never it.

Draft the description to `TICKET-TEMPLATE.md`'s required sections before handing over
(`jira-ticket-description-gate.sh` enforces presence): Bug → how to reproduce, acceptance
criteria, how to test. Feature/support/task/story → requirements, acceptance criteria, how
to test. Bulleted, one line each.

**Testing steps: every field/option a step names must exist where the step runs it** (tester
ask, PROJ-15442). Name the report TYPE the step opens; confirm each group-by/criterion/
column is in that template (AMA: `reports/.../TemplateReports/Templates/<template>.json`, or
the live picker) before posting. Same label on two fields (measure vs group-by) → name which.

Stays here, NOT forked -- anything that talks to the user or the working tree: which ticket
(Workflow above), title prefix, the "pick up tasks" and column/status queries below, the
post-push QA-verify offer, and every git mechanic.


**User asks "pick up tasks" / "what should I work on" / "what's in column X"** -> `QUERYING-TICKETS.md` (the To-Do query, UI-vs-non-UI split, ETL assignee, default-to-your-own scoping).
## Old/foreign ticket picked up → verify premise first, not just work it

Trigger: ticket `created` >2y ago (resolve live, `created <= -730d`, never hardcode a
date) OR `reporter` != `user.jiraAccountId` (`harness-config.json`) — condition may no
longer hold.

- Bug/fix → test if condition still reproduces BEFORE fixing. Use [[verify]] /
  [[ama-ui-verify]] / [[ama-report-debug]] for the how, by area — don't re-derive repro
  steps here.
- Feature/requirement → confirm with user it's still wanted before working.

**Another session may be working the same repo** (or a plan/earlier message states a constraint about one) -> `SHARED-REPO.md`: re-verify the claim live, add a worktree rather than switching branches, and the pathspec/synthetic-blob commit rules. Read it before committing in a repo another session touches.
## Creating a ticket

Fix routes to the Regressions ticket (see above) → skip this whole section, no ticket is
being created.

Need to create a ticket and it's a bugfix → ask user: bug only on QA, or on prod?

- Only on QA → title prefix `On QA: `
- On prod → title prefix `On Prod: `

E.g. `On QA: FieldTableMapper crashes resolving ConnectionManager`.

**Security finding** (injection, authz bypass, vuln, CVE, exposed secret...) → handover `epicLink` = `atlassian.securityEpicKey` (PROJ-15476), say "Security issue" in description. Gate-enforced: `harness-ticket-gate.sh` denies security-looking create without it; mere mention → payload `"security_epic_exempt": "<why>"`.


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

**Task done, and you learned something durable** -> `LEAVING-CONTEXT.md`: which companion skill takes the note, the two different bars for architecture vs bug-class, and the terseness rules. [[harness-memory]] owns user preferences/corrections instead.
