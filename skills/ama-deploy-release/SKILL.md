---
name: ama-deploy-release
description: Deploy an already-cut AMA_APP release branch to Production — merge to master/develop, verify builds, deploy via Octopus, verify AWS, revert path on failure, branch cleanup. Also mid-release UI fixes ("for the release" vs "for develop/QA"). Use for "deploy the release", "release is ready to go out", "push the release to production", or a fix targeting an outstanding release/develop/QA.
---

# Deploy an AMA_APP release

**Higher stakes than cutting the branch — this touches `master` and Production.**
Confirm with the user before every major step below (merge, master push, Production
deploy, revert). Never chain past a failure silently.

## Step 0 — Preflight FIRST: Staging API tests + Graylog/CloudWatch error sweep (gate-enforced)

First thing on "deploy the release", before master is touched (user rule 2026-10-12):
```bash
bash ~/.claude/skills/ama-deploy-release/scripts/release-preflight.sh <version> --hours <hours since cut>
```
- Window = since cut: earliest `release/<version>` pipeline `created_on` ([[ama-bitbucket-api]]).
- Runs: Graylog `environment:staging` level<=3 untagged (known noise auto-segregated), `aws-sweep.sh staging`
  (stopped tasks, unsteady services, crash-class logs, alarms, failed cache updates), `api-testing staging`,
  and infra pairing (`infra-paired-check.sh`, Step 0c).
- Exit 0 → report OK to user, continue. Exit 1 → **warn user with the findings, stop**; proceed only on
  explicit "deploy anyway". Long (API suite) → `run_in_background`.
- `prod-deploy-preflight-gate.sh` denies every Production Octopus deploy without a run <12h old; a run
  with findings needs `AMA_PREFLIGHT_ACK=1`, set only after the user's explicit yes. Fixed/noise → re-run.
- Mid-release fix pushed after preflight → re-run before Step 4 (Staging changed).

## Step 0a — Tag Reviewer One's Done/Test Complete tickets for this release

Fix Version drives every later step (0b, 7a, release-notes handoff) — backfill it
before anything else queries on it. Some of Reviewer One's tickets miss the tag: created/moved
status after [[ama-cut-release-branch]]'s Step 3a already ran at cut time, so that
sweep never caught them.

```jql
project = PROJ AND assignee = <ama.etlAssigneeAccountId, harness-config.json — Reviewer One>
AND status in (Done, "Test Complete") AND fixVersion is EMPTY AND resolved >= "<prev release cut date>"
```
Always bound by `resolved >=` — unbounded returned 50+ tickets back to PROJ-11329. Cut date = previous release's Jira Fix Version `releaseDate`, else date its `release/<prev>` branch was cut; use a day earlier.
Fields `key,status,fixVersions`, via [[ama-jira-api]]'s `jira-search.sh`. **`fixVersion
is EMPTY` only** — never retag a ticket that already carries a past release's version,
that would yank it out of that release into this one. Same fixVersion-confirm gate as
Step 3a — confirm `release/<version>` is in `~/.claude/harness-state/tickets/.confirmed-jira-versions` first,
[[jira-fixversion-confirm-gate]] denies tagging otherwise.

Per ticket: `jira-get-issue.sh` (fields `status,fixVersions`) defensive re-check — skip
if `fixVersions` already non-empty (stale-query guard, same as Step 3a). Else
`jira-edit-issue.sh` payload `{"fields": {"fixVersions": [{"name":
"release/<version>"}]}}` or MCP `editJiraIssue`.

Reviewer One-only — the user's own tickets are already covered by Step 3a / [[commit-ticket]]'s
default-assignee scoping, don't add `currentUser()` here.

## Step 0b — Confirm the release's own tickets have cleared Review

Before merging: "are this release's tickets done" means scoping to the release's **Fix
Version**, never a bare `status = "Review"` search.

```jql
project = PROJ AND fixVersion = "release/<version>" AND status = "Review"
```
Fields `key,summary`, via [[ama-jira-api]]'s `jira-search.sh`.

An unscoped search pulls in unrelated old tickets sitting in Review from past work,
overstating what's outstanding. `fixVersion` is already set on every real release ticket
by [[ama-cut-release-branch]]'s Step 3a, so scoping to it is exact, not a heuristic.

## Step 0c — Check for tickets bundled to this prod deploy

Some infra tickets (e.g. DB engine upgrade) get explicitly gated: "do this together
with release X.Y.Z", not standalone. Miss one → infra half ships without its paired
code half (or vice versa) — crash-loop territory.

Before Step 1: search comments on tickets referencing this release version for
bundling language ("release/<version>", "at the same time as", "together with",
"must deploy together", `Blocked` status pointing at this release):

```
project = PROJ AND status = Blocked AND comment ~ "release/<version>"
```
Fields `key,summary,comment`, via [[ama-jira-api]]. Hit → surface it, confirm the
paired work (e.g. an infra step) is included in this exact deploy before proceeding.
Don't guess — ask the user if unclear whether the pairing is satisfied.

**Infra Octopus projects (YourProduct-Backbone group, all 49 build.sh components) — mechanical**
(user rule 2026-10-15). Release never deploys them, so Step 0's preflight runs:
```bash
bash ~/.claude/skills/ama-deploy-release/scripts/infra-paired-check.sh <version|hotfix/X.Y.Z>
```
Keyed on tickets: infra commits naming a ticket with this Fix Version → project → Production status.
- `LIVE` = nothing to do. `NOT-IN-PROD` / `NO-PROD-DEPLOY` = ships WITH this release (or user rules
  it out) — preflight flags it, gate needs the user's yes. Agree order: infra first, unless the app
  must stop using the thing first (teardowns). Plan review + approval per [[ama-terraform-backbone]].
- `NO-PROJECT` = dir with no Octopus project (`Base/Certificates`) — applied locally, check by hand.
- `NOT-ON-MASTER` = merge the infra branch first.
- Blind spot: untagged ticket (e.g. In Progress) → invisible; Step 0c's comment search + ledger cover it.

## Step 0d — Run a Staging cache update if this release touched report fields, SqlTemplates or SQL builders

Same trigger condition as [[ama-hotfix]]'s cache update gate, same gap this fills: the
release branch has been on Staging since [[ama-cut-release-branch]] cut it, but that
skill's own Step 5 only verifies the cache-update Lambdas *deployed* — it never triggers
an actual `main` update run. If nobody ran one since, Step 0's error sweep above is reading
a stale cache, not this release's real state.

Touched report fields, SqlTemplates, Search.Shared's SQL builders, search's result
post-processing (Search.Shared Services/Query/Executor/Formatters, Search.Domain result
builders — the cache stores the processed result, not the raw rows), or fieldtablemapper's
mappings (anything changing the SQL a report emits or the values it returns — the Search leg
clears cached results; QA/Staging never auto-update, see
`memory/ama-cache-update-after-deploy.md`) → run a `main` cache update against Staging before
trusting Step 0's sweep or proceeding to Step 1. Didn't touch any → skip, no update
needed. First `bash ~/.claude/skills/ama-cloudwatch-search/scripts/wait-ecs-rollout.sh staging <services>`
— a still-rolling deploy drains the task doing the cache-update work and the state machine
burns to `States.Timeout` (Step 4a has the incident). Mechanics and the Graylog completion
line: Step 4a's recipe with `<env>=staging`, and [[ama-graylog-search]]'s `CACHE-UPDATE-DEBUGGING.md`.

## Step 1 — Merge release branch into master AND develop

For each deployable/library repo carrying `release/<version>`: merge it into `master`,
and separately merge it into `develop` too (both merges source directly from the release
branch, not chained through master).

**A fix committed onto the live release branch reaches develop through THIS merge — never
as a parallel cherry-pick.** Cherry-picking gives two commits, different SHAs, identical
content, and no shared ancestry: git then sees unrelated commits touching the same lines,
so every later merge conflicts there. That is exactly what happened across release/129.0.0
— `.csproj` conflicts in six repos plus a `reports` `UpdateUserReportService.cs` semantic
conflict that took a live investigation to settle weeks later, all for work that was
already present on both branches. It also hides real drift: a genuinely missing commit
looks identical to a duplicated one unless you compare patch ids.

Check what is actually unapplied with `git cherry origin/develop origin/master` (`+` =
genuinely absent, `-` = equivalent patch already there), not a commit count.
`develop-backmerge-reminder.sh` fires on the same predicate after a master push.

```bash
cd "$(bash ~/.claude/hooks/lib-harness-repos.sh path <repo>)"
git fetch origin
git checkout master && git pull origin master
git merge --no-ff origin/release/<version>
# repeat against develop
git checkout develop && git pull origin develop
git merge --no-ff origin/release/<version>
```

**Record master's pre-merge commit hash for every repo before merging** — needed for
Step 6's revert path if Production deploy goes wrong later.

## Step 2 — Merge conflicts: flag and stop, never auto-resolve

A conflict on either merge → `git merge --abort`, tell the user exactly which repo and
which files conflicted, and wait. Don't guess a resolution, don't pick a side. This
applies per-repo — one repo conflicting doesn't block merging the others, but don't
push any repo's master until its own merge is clean.

## Step 3 — Push master, verify every pipeline goes green

Only after Step 1/2 are clean for a repo:
```bash
git push origin master
```
`bash ~/.claude/skills/ama-bitbucket-api/scripts/pipeline-status.sh <repo> master --wait`
per repo. **Don't deploy anything to Production until every repo's master pipeline is
green** — a red one stops the whole release; tell the user which repo/step failed rather
than proceeding partially.

## Step 3a — Verify Staging with the automated API test suite before deploying (mandatory, full releases only)

Now part of Step 0's `release-preflight.sh` (runs `api-testing staging` FIRST, before the merge).
Re-run the preflight here only if Staging changed since (mid-release fix). Not for hotfixes
(`--hotfix` skips the suite, see [[ama-hotfix]] Step 4).

## Step 4 — Deploy to Production via Octopus (only once Step 3 is all green)

### Precondition: NOT during US business hours — 9am-5pm ET, Mon-Fri

Standing user instruction (2026-09-09). Same window as Step 5a, now covering the deploy
itself. **Outside it is fine in BOTH directions** — before 9am ET tomorrow is as valid as
after 5pm ET today; don't reflexively defer a whole day to the evening. Inside → timeshift
to the next opening, don't skip. Default reminder slot = next weekday 08:00 LOCAL, never
17:04 ET / 23:00 SAST (PC off then; user rule 2026-10-14, `memory/business-hours-deferral-reminder.md`).

**Emergency/hotfix timeline is NOT an exemption** ([[ama-hotfix]] Step 4 inherits this).
Override is the user's call only, via `AMA_ALLOW_PROD_DEPLOY=1`.

**Gate-enforced** (`prod-deploy-business-hours-gate.sh`), fails CLOSED. **Two independent
deny reasons — read which one you got:** (a) inside the window, or an unresolvable clock;
(b) a deploy call whose target environment isn't a literal in the command text — that arm
ignores the clock and denies at 6am too. Fix (b) by passing `Environments-NN` literally
rather than through a variable or a pre-written body file, not by reaching for the override.

**Resolve ET before ANY claim about this window — conversational ones included.** This is
not just a pre-deploy check: the rule above exists because "it's about 14:55 UTC now, so
you have roughly an hour before US business hours" was asserted at 10:55 ET, ninety minutes
INSIDE the window, from invented UTC arithmetic. Never do UTC arithmetic in your head, and
never store a UTC start time — 9am ET is 13:00 UTC only under EDT, 14:00 UTC in winter.
Canonical resolver: `hooks/lib-et-now.sh` (`et_now`, `et_window_state`). Recipe and the
`TZ=`-is-ignored trap: Step 5a below.

### Precondition: nothing ships to Production that Staging never ran

Before deploying, prove that **the exact commit being released was built and deployed to
Staging** — not merely that the branch was green at some earlier point. A fix committed
straight onto `release/*` late in the cycle is the one most likely to reach Production
untested, precisely because the earlier Staging verification already passed.

Per repo in the release:
```bash
bash ~/.claude/skills/ama-bitbucket-api/scripts/pipeline-status.sh <repo> release/<version> \
  --sha "$(git -C <repo> rev-parse origin/release/<version>)"
```
Exit non-zero (no SUCCESSFUL pipeline for that exact sha) → **stop**. Either it never
reached Staging, or it reached it and failed; both mean Production would be the first
environment to run it.

Then confirm the Staging *artifact* matches (ECS image tag / S3 bundle hash), not just the
pipeline — a green build that never deployed is the same hazard in a different place.

**Every commit made directly onto the release branch must also name a ticket whose Fix
Version includes that branch** — otherwise the release ships work its own ticket list
doesn't mention, and neither the release notes nor the Step 7a sweep will ever see it.
`ticket-worked-while-open-gate.sh` enforces this at commit time; this step is the backstop
for commits made before that hook existed or on another machine.

See [[ama-octopus-deploy]] for auth/space/project-naming/endpoint details — reuse it, don't
re-derive. Mechanically this is the same list-release/trigger-deployment/poll-task
pattern already confirmed working there, targeting `YourProduct-Production` instead of
`YourProduct-Staging`.

**Lambdas in this release (the cache-update lambdas, always included per
[[ama-cut-release-branch]]) need the existing function deleted before this step** — deploy
each via `ama-octopus-deploy/scripts/deploy-lambda.sh` (dry-check, delete, POST, retry, verify);
see [[ama-octopus-deploy]]'s Lambda section.

**Throttle + order** (2026-10-14: ~28 prod deploys at once → Terraform "timeout while waiting for plugin to start"; 2 Lambdas failed after delete-function, absent ~15 min):
- Max 6 concurrent prod Octopus deploys; queue rest.
- Lambda project: delete-function RIGHT BEFORE its own deploy, never ahead of queue.
- `YourProduct_Exporter_CacheUpdate_APIGateway` AFTER `CacheUpdate_APIGateway_Lambda` (data source reads `production-v1-cacheupdate-apigateway-lambda`; else ListVersionsByFunction 404).

**Not every Octopus project with a newer release belongs to the release — check before
deploying.** Confirmed traps, all seen in one prod deploy (2026-08-18):
- `YourProduct_Exporter_OrganisationExports_API_ECS` — **DISCONTINUED, never deploy it.**
  It still shows a newer `latest` than prod forever.
- `Backbone_*` (infra) — separate track, most never deployed to prod. Never deploy by version
  diff; deploy only what Step 0c's `infra-paired-check.sh` flags.
- A project whose `latest` build number matches **no** release repo's master build is not
  in this release, whatever the version diff says.

**Prod version can look HIGHER than latest — the Bitbucket repo migration reset build
numbers.** `Export_Cohort_ECS` read `latest=2.0.0.31` vs `prod=2.0.1.311`; the `.311`
values are pre-migration. Don't read that as "prod is ahead, skip it". Confirm by content
(`git diff --stat origin/release/<v> origin/master` empty ⇒ same code as the
staging-verified build), then deploy the new build.

**A `master` push lands in the `Master` channel — confirmed end-to-end for
`YourProduct_Exporter_Search_API_ECS` (`Projects-95`) on 2026-08-27: master `ed85bc20` →
build #143 → release `2.0.0.143` in `Channels-373` ("Master"), deployed to
YourProduct-Production and verified by ECS image tag. Production's previous release
(`2.0.0.139`) was in that same channel, so the channel is stable across deploys, not
per-release. Still confirm the channel id per project** — they are project-scoped
(`Channels-370..375` here: Default/Development/Hotfix/Master/Release/Testing), so read
`/projects/<id>/channels` rather than reusing an id from another project.

**A single repo push can create releases in SEVERAL projects — check each before deciding
scope.** The same push created `2.0.0.143` in both `YourProduct_Exporter_Search_API_ECS` and
`YourProduct_Exporter_Search_CacheUpdate_Lambda` (`Projects-96`). Deploying only the project
whose code actually carries the change is correct — those two are routinely out of lockstep
in Production by design (API on `Releases-20401`, Lambda on the much older `Releases-20285`).
Decide by what the artifact contains, not by "a new release exists": the CacheUpdate Lambda
only `POST`s `{SearchServiceUrl}/search/cache/update/internal` and references
`Search.Cache`, so a `Search.Shared` SQL-builder fix does not ship in it at all.

## Step 4a — Run a MAIN cache update against Production, and confirm it finished

**Required only when the deploy touched report fields, SqlTemplates, Search.Shared's SQL builders, search's result post-processing (Services/Query/Executor/Formatters, Search.Domain result builders) or fieldtablemapper's mappings** — anything changing the SQL a report emits or the values it returns; the invalidation ships with the deploy, never left to a tester or client (user rules 2026-09-27, 2026-10-05) — same trigger
condition [[ama-hotfix]]'s Staging cache-update gate already uses, now matching here too.
`reports` and `search` cache templates and the SqlTemplate set in Redis, so deploying alone
leaves them serving the pre-release copy — and if the release removed any SqlTemplate column,
the stale cache 500s the affected report for every user rather than merely being stale.
Didn't touch either → skip this step, no cache update needed.

**First:** `bash ~/.claude/skills/ama-cloudwatch-search/scripts/wait-ecs-rollout.sh production <services>`
— Octopus `Success` is not enough (same deployed-vs-running distinction as Step 4).
`Update Reports`/`Update Search` wait on a task token held by the API task; a still-rolling
deploy drains it, no token returns, `States.Timeout` after 3500s (hotfix/129.0.11, 2026-08-25:
fired 6 min into a rollout, failed an hour later having done nothing). The script's header
carries the rule; `octopus-prod-cache-update-reminder.sh` nudges this step after the POST.

Trigger the `main` cache update for `production` and then **confirm it actually completed** —
the HTTP 200 only means "queued". Exact calls, the state machine to watch, and the Graylog
completion line: [[ama-graylog-search]]'s `CACHE-UPDATE-DEBUGGING.md`.

Do this BEFORE Step 5's verification, or the sweep just measures the stale state.

## Step 5 — Check AWS for anything wrong

Reuse [[ama-cloudwatch-search]]'s `AWS-SWEEP.md` checklist and `verify-qa-deploy.sh`/
`verify-deployment-e2e.sh`, pointed at `production` instead of `qa`/`staging`. Also sweep
Graylog (`environment:production`) per [[ama-graylog-search]].

**Errors that only appear when a client opens a report come HOURS later** (15801 reached a
client first). Schedule `reminder.sh` re-checks at deploy +4h and +24h running
`ama-graylog-search/scripts/error-signature-diff.sh production <deploy time ISO>`; NEW untagged
signature → ticket. The prod-deploy reminder hook names this (also for hotfix Step 4).

**Skip this step for a UI-only deploy** — the change is confined to frontend code
(`exporterplus`/`admin`, an S3-hosted static bundle) with no backend/API/Lambda code
touched. Nothing server-side changed, so CloudWatch/Graylog have nothing relevant to
show either way — a sweep there is a no-op check, not a real signal. The real
verification for a UI-only deploy is the behavioral probe (served bundle content check +
driving the actual page) already covered in Step 4/verification, not an AWS/Graylog
sweep. Still run this step whenever the release touches any backend/API/Lambda repo.

## Step 5a — Once stable, run the API test suite against production

**Standing step, unconditional, no per-run confirmation** — confirmed by explicit user
request despite the suite containing destructive-sounding fixtures
(`Deleting_Organization_Negative_Scenarios`, `Delete_User_Negative_Scenarios` — see
[[ama-architecture-notes]]'s `TESTING-REPOS.md`). Only run once Step 5 confirms things
are actually stable, not in parallel with it.

**Never run during US business hours — the blocked window is 9am-5pm Eastern, Mon-Fri**
(per explicit user instruction). **Outside it is fine in BOTH directions: before 9am ET is
just as valid as after 5pm ET** — don't reflexively defer to the evening when an early-morning
deploy finishes at, say, 03:40 ET and could run immediately (clarified 2026-08-18, after
Step 5a was needlessly parked until 5pm). Inside the window, timeshift to the next opening —
don't skip the run.

**Gate-enforced** (`prod-api-test-window-gate.sh`) — a trigger inside the window is denied,
so this is no longer a rule to remember. It fails CLOSED: an unresolvable clock also denies.
Override only with the user's say-so, via `AMA_ALLOW_PROD_API_TESTS=1`.

Resolve "now" in ET explicitly, never from local/UTC clock assumptions. **Do NOT use
`TZ=America/New_York date` — git-bash on this machine ignores `TZ` entirely**, so it returns
UTC while looking like it worked. Proven 2026-08-18: `TZ=UTC`, `TZ=America/New_York` and
`TZ=Asia/Tokyo` all printed the identical time (16:34). An earlier version of this note said
only the `%Z` *label* was unreliable and to "trust the hour" — **the hour is wrong too**, and
trusting it would have started a Production API-test run at 12:34 ET, mid-business-hours.

Use python's zoneinfo, which reads real tzdata:
```bash
python -c "from datetime import datetime; from zoneinfo import ZoneInfo; \
print(datetime.now(ZoneInfo('America/New_York')).strftime('ET=%H:%M %a offset=%z %Z'))"
```
Sanity-check the answer: EDT is UTC-4 (Mar-Nov), EST is UTC-5. **If the printed ET equals
UTC, the lookup failed — don't proceed on it.**

**Two separate custom pipelines in the `api-testing` repo, both against production, run
in SERIAL (not parallel) — confirmed from `bitbucket-pipelines.yml`:**
1. `custom: production` — `Category=FullRegression` filter (the standard run).
2. `custom: production_exports` — `Category=Exports` filter (the exports run).

```bash
bash ~/.claude/skills/ama-bitbucket-api/scripts/run-pipeline.sh api-testing production && \
bash ~/.claude/skills/ama-bitbucket-api/scripts/run-pipeline.sh api-testing production_exports
```
Serial, never parallel (user confirmed). Neither fires on its own
([[ama-architecture-notes]]' `TESTING-REPOS.md`). Feed BOTH junit summaries into Step 5's
support-channel Slack post — don't post before both runs are in.

## Step 6 — Something's wrong: alert the user, offer a revert

Don't revert unprompted — alert first, give the user the choice. If they say revert:

1. **Octopus**: redeploy whatever release was on `YourProduct-Production` immediately
   before this deploy, per affected project (same trigger-deployment call as Step 4,
   targeting the previous `Releases-X`, found via the project's `progression` endpoint's
   deployment history).
2. **Git**: `master` is shared/pushed — **never `reset --hard`**. Use `git revert -m 1
   <merge-commit>` for each repo's release-merge commit, bringing master's *content*
   back to pre-merge state via a new commit, not rewritten history. The pre-merge hash
   recorded in Step 1 is what confirms the revert landed correctly.
3. Leave `develop`'s merge alone unless the user says otherwise — the bad content
   reaching `develop` isn't itself an outage; deal with it as a normal follow-up fix.

## Step 7 — All well: delete the release branch, locally and on remote

```bash
cd "$(bash ~/.claude/hooks/lib-harness-repos.sh path <repo>)"
git branch -D release/<version>
git push origin --delete release/<version>
```
Do this per repo once Steps 3-5 confirm that repo's deploy is healthy — don't wait for
every repo in the release to finish before cleaning up the ones already confirmed good.

---

## Mid-release UI fix — "for the release" vs "for develop/QA"

While a release branch is still outstanding, a UI fix request needs to land in the
right place depending on which environment it's actually for. **Check the ticket's Fix
Version first** — see [[commit-ticket-jira]]'s reverse-case rule: already set to this
outstanding release → that answers it, skip straight to "for the release" below, don't
ask.

- **"For the release"** (or the user names the release version) → branch off / commit
  directly on `release/<version>` itself, not `develop`. Confirm the fix looks right in
  a local browser run **before** pushing. Push → confirms it auto-deployed to
  **Staging** (per [[ama-cut-release-branch]], `release/*` auto-deploys there).
- **"For develop"/"for QA"** → same flow, but against `develop`, confirmed against
  **QA** instead once pushed (develop auto-deploys to QA).
- **Neither said** → ask which one before touching anything. Don't guess — a fix
  landing on the wrong branch either misses the release entirely or leaks into `develop`
  before it's wanted there.

## What this skill assumes already happened

- The release branch exists and was cut via [[ama-cut-release-branch]].
- Staging verification (that skill's Step 5) already passed — this skill is the
  Staging→Production leg, not a substitute for it.

## Step 7a — Select this release's tickets, move the Test Complete ones to Done

Just before release notes, after Step 5/5a confirm production is stable and tests
pass. **Fix Version-scoped, not column-scoped** — pulls in both Done (already tagged
by Step 0a/cut time, nothing to transition) and Test Complete (needs the move), same
reason as Step 0b: don't rely on "only this push could have put anything there".

```jql
project = PROJ AND fixVersion = "release/<version>"
AND status in (Done, "Test Complete", Open, "To Do", "In Progress")
```
Fields `key,summary,status`, via [[ama-jira-api]]'s `jira-search.sh`.

**Query every non-terminal status, not just Test Complete.** A ticket worked straight
from Open never passes through the intermediate columns, so a `status in (Done, "Test
Complete")` query cannot see it — no matter that its code shipped. Confirmed live
2026-08-18: PROJ-15268 and -15269 shipped in release/129.0.0, sat at **Open**, and
were simultaneously listed on the AMA Backlog page as future work anyone picking up the
backlog would treat as unstarted. The sweep had no way to catch them.

Transition the **Test Complete** subset to Done, via `jira-transition-issue.sh` or MCP
`transitionJiraIssue` (`jira-get-transitions.sh` first, don't hardcode the transition ID —
see [[commit-ticket-jira]]). **From Test Complete the board offers NO transition named
"Done"** — the hop is `Deployed Prod` (id 311 on the tickets seen so far, re-resolve per
ticket), which lands on Done. Tickets already Done: leave alone, no re-transition.
Mandatory, not an offer.

**Anything found at Open/To Do/In Progress: report it, don't sweep it silently.** Shipped-
but-not-started is a contradiction worth a human look — either the ticket is genuinely
done (transition it, and remove it from the backlog page, since a Done ticket sitting
there gets picked up again), or the fixVersion is wrong and should be cleared so the
release record stops claiming unfinished work. Verify against real acceptance evidence,
not just "the code matches the description" — for 15269 that was the CI abort disappearing
at exactly that commit on both branches and staying gone for 8 consecutive builds.
Board hops from Open are typically Open → To Do → In Progress → Done; confirm each with
`jira-get-transitions.sh`, ids differ per ticket.

Keep the **full** key list (Done + Test Complete) — hand it directly to Step 8, don't
let [[ama-release-notes]] re-derive it independently.
Harness tickets: still swept to Done, but dropped from the NOTES list -- hand off the full list; [[ama-release-notes]] Step 2 runs `scripts/harness-ticket-filter.sh` and prints the removals in the handoff.

**Same pass: sweep prior hotfix Done → Closed.** This release's prod deploy is the
trigger for every earlier hotfix, not just one this release absorbs:
```jql
project = PROJ AND fixVersion ~ "hotfix/*" AND status = Done
```
Transition each to Closed (`jira-get-transitions.sh` per ticket). Skip
`atlassian.harnessEpicKey`/`regressionsTicketKey` (never transition, see
[[commit-ticket]]), and skip any ticket that ALSO carries a `release/*` Fix Version — that
is release work absorbed by a hotfix, closed by its own release's notes, not by this sweep
(PROJ-15260/-15187 left alone on 2026-09-18 for this reason). Runs on a RELEASE deploy
only, never on a hotfix's own deploy.

## Step 8 — Release is deployed AND all tests pass: write the release notes

**Mandatory final step, not an offer** — once Step 7a has moved this release's tickets
to Done, invoke [[ama-release-notes]] to document the release (ticket list per Step
7a's handoff above). Don't wait to be asked — this is the last step of the deploy, the
same way Step 7's branch cleanup is, not a separate later task.

**Gate on both conditions together, not just one**: a stable-but-untested deploy, or a
passed-test-but-AWS-still-shaky deploy, isn't "all tests pass" yet — don't run this step
early off partial success. If Step 6's revert path was taken instead, skip this step
entirely for this attempt — release notes document what actually shipped, not an
attempt that got rolled back.
