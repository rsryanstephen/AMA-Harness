---
name: ama-deploy-release
description: Deploy an already-cut AMA_APP release branch to Production — merge to master/develop, verify builds, deploy via Octopus, verify AWS, revert path on failure, branch cleanup. Also mid-release UI fixes ("for the release" vs "for develop/QA"). Use for "deploy the release", "release is ready to go out", "push the release to production", or a fix targeting an outstanding release/develop/QA.
---

# Deploy an AMA_APP release

**Higher stakes than cutting the branch — this touches `master` and Production.**
Confirm with the user before every major step below (merge, master push, Production
deploy, revert). Never chain past a failure silently.

## Step 0 — Check Staging for unaddressed errors since the release was cut

Before touching master: this release branch has been running on Staging since it was
cut ([[ama-cut-release-branch]] Step 3) — confirm it hasn't been silently erroring.

1. **Window start** = the earliest Bitbucket pipeline run for `release/<version>` on
   each repo (its cut/first-Staging-deploy timestamp) — query pipelines filtered to
   that branch, sorted oldest-first, take the first result's `created_on` (see
   [[ama-bitbucket-api]] for the pipeline-query pattern). Window end = now.
2. Sweep Graylog (`environment:staging`) and CloudWatch for that window, per
   deployable repo in the release — see [[ama-graylog-search]]/[[ama-cloudwatch-search]],
   same known-noise filtering (`KNOWN-SIGNATURES.md`) as any other sweep.
3. Anything real and unaddressed → stop, tell the user, don't proceed to Step 1 until
   it's resolved or the user explicitly says proceed anyway.

## Step 0a — Tag Reviewer One's Done/Test Complete tickets for this release

Fix Version drives every later step (0b, 7a, release-notes handoff) — backfill it
before anything else queries on it. Some of Reviewer One's tickets miss the tag: created/moved
status after [[ama-cut-release-branch]]'s Step 3a already ran at cut time, so that
sweep never caught them.

```jql
project = PROJ AND assignee = <ama.etlAssigneeAccountId, harness-config.json — Reviewer One>
AND status in (Done, "Test Complete") AND fixVersion is EMPTY
```
Fields `key,status,fixVersions`, via [[ama-jira-api]]'s `jira-search.sh`. **`fixVersion
is EMPTY` only** — never retag a ticket that already carries a past release's version,
that would yank it out of that release into this one. Same fixVersion-confirm gate as
Step 3a — confirm `release/<version>` is in `~/.claude/.confirmed-jira-versions` first,
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
Poll that repo's newly-triggered `master` Bitbucket pipeline to `COMPLETED`/`SUCCESSFUL`
(see [[ama-bitbucket-api]] for auth). **Don't deploy anything to Production until every
repo's master pipeline is green** — a red pipeline here stops the whole release, tell
the user which repo/step failed rather than proceeding partially.

## Step 4 — Deploy to Production via Octopus (only once Step 3 is all green)

See [[ama-octopus-deploy]] for auth/space/project-naming/endpoint details — reuse it, don't
re-derive. Mechanically this is the same list-release/trigger-deployment/poll-task
pattern already confirmed working there, targeting `YourProduct-Production` instead of
`YourProduct-Staging`.

**Lambdas in this release (the cache-update lambdas, always included per
[[ama-cut-release-branch]]) need the existing function deleted before this step** — see
[[ama-octopus-deploy]]'s Lambda-staleness gotcha.

**Not every Octopus project with a newer release belongs to the release — check before
deploying.** Confirmed traps, all seen in one prod deploy (2026-08-18):
- `YourProduct_Exporter_OrganisationExports_API_ECS` — **DISCONTINUED, never deploy it.**
  It still shows a newer `latest` than prod forever.
- `Backbone_Applications_AMA_*` — separate `1.0.0.x` track, most never deployed to prod.
  Not part of an AMA_APP release.
- A project whose `latest` build number matches **no** release repo's master build is not
  in this release, whatever the version diff says.

**Prod version can look HIGHER than latest — the Bitbucket repo migration reset build
numbers.** `Export_Cohort_ECS` read `latest=2.0.0.31` vs `prod=2.0.1.311`; the `.311`
values are pre-migration. Don't read that as "prod is ahead, skip it". Confirm by content
(`git diff --stat origin/release/<v> origin/master` empty ⇒ same code as the
staging-verified build), then deploy the new build.

**Open question, confirm empirically before relying on it**: which Octopus channel a
`master` push lands a release in (candidates seen in that reference: `Master`, `Release`)
hasn't been confirmed end-to-end for a Production deploy the way the Staging path was —
check the project's channels/lifecycle for the actual release that appeared after Step 3
rather than assuming which channel it's in.

## Step 4a — Run a MAIN cache update against Production, and confirm it finished

**Standing step, every production release, not conditional on what the release contained.**
`reports` and `search` cache templates and the SqlTemplate set in Redis, so deploying alone
leaves them serving the pre-release copy — and if the release removed any SqlTemplate column,
the stale cache 500s the affected report for every user rather than merely being stale.

Trigger the `main` cache update for `production` and then **confirm it actually completed** —
the HTTP 200 only means "queued". Exact calls, the state machine to watch, and the Graylog
completion line: [[ama-graylog-search]]'s `CACHE-UPDATE-DEBUGGING.md`.

Do this BEFORE Step 5's verification, or the sweep just measures the stale state.

## Step 5 — Check AWS for anything wrong

Reuse [[ama-cloudwatch-search]]'s `AWS-SWEEP.md` checklist and `verify-qa-deploy.sh`/
`verify-deployment-e2e.sh`, pointed at `production` instead of `qa`/`staging`. Also sweep
Graylog (`environment:production`) per [[ama-graylog-search]].

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

Resolve "now" in ET explicitly, never from local/UTC clock assumptions:
`TZ=America/New_York date '+%H:%M %a'` (on git-bash `%Z` may still print GMT even when the
offset applied — trust the hour, not the label; cross-check against a known UTC timestamp).

**Two separate custom pipelines in the `api-testing` repo, both against production, run
in SERIAL (not parallel) — confirmed from `bitbucket-pipelines.yml`:**
1. `custom: production` — `Category=FullRegression` filter (the standard run).
2. `custom: production_exports` — `Category=Exports` filter (the exports run).

Trigger `production` first (same trigger-a-pipeline pattern as [[ama-bitbucket-api]] — it
never fires on its own, see [[ama-architecture-notes]]'s `TESTING-REPOS.md`), poll to
completion, THEN trigger `production_exports` — don't fire both at once, the user
confirmed serial. Capture the pass/fail summary from both (junit reports under each
build's `test-reports/build_<BITBUCKET_BUILD_NUMBER>/junit.xml`). Feed BOTH summaries into
Step 5's support-channel Slack post (`slack.amaSupportChannelName`, see [[ama-cloudwatch-search]]'s
`DEPLOY-VERIFICATION.md`) — don't post the Slack summary before both runs are in.

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
Version first** — see [[commit-ticket]]'s reverse-case rule: already set to this
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
see [[commit-ticket]]). Tickets already Done: leave alone, no re-transition. Mandatory,
not an offer.

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
