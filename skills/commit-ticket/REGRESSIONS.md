# Regressions -- reopen the causing ticket, or the generic Regressions ticket

Reference for [[commit-ticket]] -- loaded on demand, not at task start.

**Before fixing just this instance**: the causing change likely broke other consumer shapes
too -- sweep them in the same fix ([[ama-debugging-notes]]' `SHARED-CHOKEPOINT-CHANGES.md`);
2nd follow-up from one change = full shape sweep, stop patching instances.

**Causing ticket RELEASED (carries a released `release/*`/`hotfix/*` Fix Version) → NEW Bug ticket linked to it ("relates to"), never reopen.** Reopen + new Fix Version lists old feature as new in release notes (PROJ-14911, 2026-10-14). Gate: `jira-fixversion-confirm-gate.sh` denies adding `release/*` Fix Version to ticket already on a different released `release/*`. Rest of file applies only when causing ticket NOT yet released.

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

