---
name: ama-cut-release-branch
model: sonnet
description: Cut a new AMA_APP release branch (release/<next-version>) from develop, tag included tickets with the release Fix Version, check for out-of-date library refs. Use for "cut a release branch", "cut the release", "start a release" -- the FIRST stage of a release, before deploying it.
---

# Cut an AMA_APP release branch

**Never run this automatically — always confirm with the user before pushing any branch.**
This creates real branches visible to the whole team and triggers real Staging
deployments fleet-wide. Treat every step below as "propose, then execute on go-ahead,"
not a silent one-shot script.

## Step 1 — Get the next release version from Jira

Query Jira directly (not Confluence — that's `ama-release-notes`' method, kept separate):

```bash
bash ~/.claude/skills/ama-jira-api/scripts/jira-version.sh next release          # -> release/131.0.0
bash ~/.claude/skills/ama-octopus-deploy/scripts/last-prod-deploy-date.sh release/<N-1>   # previous release's Production date + next working day
```
The first reads the version LIST (highest `release/X.0.0`, +1) — never derive this from a
ticket search, the newest fixVersion of ANY kind is usually a hotfix. The second is the
previous release's `releaseDate` for Step 3a and [[ama-release-notes]]' start date.

## Step 2 — Determine which repos are actually deployable

**Not the same as `libraries.md`/`api-services.md`.** Those lists encode "publishes a
NuGet package," not "is deployable" — e.g. `search` is classified as a library (it
publishes `Search.Cache`/`Search.Shared`) but ALSO has a `develop` branch and deploys
real Lambdas.

```bash
bash ~/.claude/skills/ama-cut-release-branch/scripts/list-deployable-repos.sh
```

Checks for an `origin/develop` branch with a commit in the last 2 years (not just
existence). The window is deliberate, don't shorten it — see [[ama-architecture-notes]]
FLEET-CONVENTIONS.md's develop-branch-liveness note (dead-`develop` repos vs live but
infrequently-changed ones).

`admin`/`exporterplus` (S3-hosted frontends) DO get release branches like everyone else
here — they're only excluded from the ECS-specific verification in Step 5, not from the
branch cut itself.

## Step 2a — Verify QA with the automated API test suite before cutting (mandatory)

**Standing step, every release cut** — release branches are cut from `develop`, which
deploys to QA continuously, so this is the last checkpoint before a regression already
on `develop` propagates into every deployable repo's release branch at once.

```bash
bash ~/.claude/skills/ama-bitbucket-api/scripts/run-pipeline.sh api-testing qa    # trigger, poll, junit summary; exit 0 = all passed
```
Exit non-zero blocks the cut — it prints the failed test names; tell the user, don't cut anyway.
**No business-hours window restriction** — that gate exists only for the destructive-
sounding fixtures in the production suite ([[ama-deploy-release]] Step 5a); QA has no
such restriction, run this as soon as Step 2 confirms the deployable-repo list.

## Step 3 — Cut release branches on deployable repos

Build the mapping file with the script, then cut — don't hand-format `repo<TAB>ref`
lines or loop fetch/checkout/push per repo, that's exactly the token burn these scripts
replace:

```bash
bash ~/.claude/skills/ama-cut-release-branch/scripts/build-mapping-file.sh <mapping-file>
bash ~/.claude/skills/ama-cut-release-branch/scripts/cut-release-branches.sh <version> <mapping-file>
```

Prints one line per repo: `cut` / `skip` (branch already exists, tip matches) /
`MISMATCH` (exists but tip differs — judge it, don't assume it's fine) / `FAILED
<reason>`. This triggers the repo's Bitbucket pipeline for that branch, which — per
[DEPLOY-VERIFICATION.md](../ama-cloudwatch-search/DEPLOY-VERIFICATION.md) — auto-deploys to
**Staging** via its Testing-channel-equivalent lifecycle rule (`release/*` → Staging).

## Step 3a — Tag included-but-undeployed tickets with the release's Fix Version

**Jira-side query only, never a code/git search** (code-search tagging misses
AMA_ETL/harness repos and wrongly calls their tickets unmerged):

**TWO queries, unioned — one status-based (app work), one resolution-date-based (ETL).**
Neither alone is complete.

Query 1 — app/harness work, mine (`currentUser()`):
```
project = PROJ AND assignee = currentUser()
AND status in ("QA", "Ready to Test", "Test Complete") AND fixVersion is EMPTY
```

Query 2 — anything already past TC, **BOTH assignees** (`ama.etlAssigneeAccountId` from
`harness-config.json` is Reviewer One):
```
project = PROJ AND assignee in (currentUser(), <ama.etlAssigneeAccountId>)
AND fixVersion is EMPTY AND status in (Done, Closed)
AND resolutiondate >= "<release/<N-1> releaseDate>"
```

**Query 2 exists because a status filter CANNOT see work that left those statuses** — ETL work
never enters QA/RTT/TC, own work passes through them to Done between sessions. Whoever owns it,
Query 1 misses it. Hence `assignee in (currentUser(), <Reviewer One>)`, not Reviewer One alone. Get `<release/<N-1>
releaseDate>` from `jira-version.sh show release/<N-1>` (129.0.0 → `2026-08-17`), NOT from
the previous release's cut date.

**Re-run BOTH queries at cut time, never reuse a list gathered earlier** — the set drifts
fast (54 → 55 → 86 over ten days on the 130 cut).

**Also sweep a little BEFORE that date for stragglers.** A ticket resolved days before
release N-1 shipped but never tagged into it fell through the gap and appears in no
release note at all — it belongs in this cut. Widen Query 2 to the N-2 release date and
ask the user about anything in the overlap (2 such on the 130 cut: PROJ-15091,
-15276).

Untagged is the whole test — a ticket already carrying ANY fixVersion is already bundled
into some release or hotfix, so it never belongs in this cut. Confirm exact status names
via [[ama-jira-api]]'s `jira-get-transitions.sh` rather than hardcoding. Every ticket the
queries return gets tagged — no further code check.

**NEVER `fixVersion != "release/<prev>"` — it is wrong in both directions.** Jira's `!=`
excludes empty values, so it drops every genuine (untagged) candidate and returns tickets
tagged to OTHER already-released versions — tagging that set misattributes shipped work.

**Hotfix tickets stay on their hotfix version — do not tag them into the release.**
`hotfix/<N-1>.0.x` tickets reach the release notes via [[ama-release-notes]] Step 2's
union, which resolves the live hotfix-version list and de-dupes by key. Retagging them
here double-counts and breaks that attribution.

**Before tagging anything, make sure `release/<version>` exists in Jira — and create it
yourself if it doesn't.** [[ama-jira-api]]'s `jira-version.sh` does this over REST
(`show` / `create <name> "<description>"`), confirmed working; the old "no MCP tool or REST
auth for this" note was wrong and is gone. Then run
`bash ~/.claude/hooks/confirm-jira-version.sh release/<version>` — creation and this
harness's *confirmed* list are separate, and the gate reads only the list, so an
already-existing version still gets tagging denied until confirmed. The
[[jira-fixversion-confirm-gate]] hook denies any tagging attempt until this is done —
don't guess a workaround around it. Once confirmed/found existing: set the version's
description per [[ama-jira-api]]'s "Version descriptions" section (release = the
tagged tickets' work grouped by theme; Octopus displays it).

For each ticket returned by the query:
1. [[ama-jira-api]]'s `jira-get-issue.sh` (fields `status,fixVersions`) — defensive
   re-check: skip if status
   is already Done or `fixVersions` already includes the previous release (the JQL
   above should have excluded both, this just guards a stale/cached query result).
2. [[ama-jira-api]]'s `jira-edit-issue.sh` (payload `{"fields": {"fixVersions":
   [{"name": "release/<version>"}]}}`). MCP retired 2026-08-31.
3. **Once this Staging deploy is confirmed stable**, transition per ticket
   (`jira-transition-issue.sh`): anything downstream of the change
   could break → Ready to Test + testing-steps comment (`jira-add-comment.sh`);
   regression check + brief separate comment ONLY per
   [[ama-hotfix]] Step 2a item 3 (high risk; comment only if UI-testable by the tester);
   nothing downstream at all → Test Complete directly. Route on
   blast radius, not UI-testability. Same conditional as [[ama-hotfix]]'s Step 2a
   (that's the canonical version of this step — reuse its exact mechanics, don't
   duplicate). A release bundles many tickets, judge each one, not the release as a
   whole. Confirm the actual transition via [[ama-jira-api]]'s `jira-get-transitions.sh`
   rather than hardcoding.

`extract-release-tickets.sh` still useful for [[ama-release-notes]]'s "what code
shipped" question — not the tagging source anymore, `AMA_APP`-only by design, don't
repurpose as a completeness check.

## Step 4 — Check for out-of-date library references, ask before touching anything

Libraries don't get their own release branch. Instead, check whether any deployable
repo's `develop` (== what's live on QA, since `develop` auto-deploys there) references
an older `packages.libraryPrefix` (`harness-config.json`, e.g. `YourCompany.Product.*`)
library version than what's actually latest-published:

```bash
bash ~/.claude/skills/ama-cut-release-branch/scripts/check-library-drift.sh <repo-list-file>
```

Read-only. Queries CodeArtifact (`aws.codeArtifact.{domain,repository}`) for each
referenced package's latest version. Prints one
`<repo><TAB><package><TAB><current><TAB><latest>` line per out-of-date pair, silent if
none are.

**If anything's out of date, list it and ask the user whether to update those
references now** — don't touch any `.csproj` unprompted. Report-and-ask only.

## Cache-update Lambdas and infrastructure are already covered — no extra repos to cut

The release includes the whole cache-update pipeline automatically, because every
component of it is built from a repo already in Step 2's list (confirmed from each
repo's actual pipeline):

- `fieldtablemapper`, `reports`, `notifications` each build their own `-cacheupdate`
  Lambda from `_build/cacheupdate-lambda` alongside their main ECS service.
- `export` builds **two** Lambdas from one pipeline: `export-cacheupdate` (the
  `SqlTemplates` step) AND `report-transfers` (Octopus projects
  `YourProduct_Exporter_Export_CacheUpdate_Lambda` /
  `YourProduct_Exporter_ReportTransfers_Lambda`) — confirmed in
  `export/bitbucket-pipelines.yml`.
- `search` builds `curve-cacheupdate` (the `CurveAnalyser.Lambda` project inside it).
- `selenium-crawlers` is its own repo, already listed, builds `selenium-crawlers-cacheupdate`.
- `cacheupdate-infrastructure` (already listed) is NOT just Terraform — it bundles **six**
  Lambda/Console projects: `APIGateway.Lambda`, `CacheClear.Lambda` (the universal
  messenger, see [[ama-graylog-search]]'s `CACHE-UPDATE-DEBUGGING.md`), `Cascade.Lambda` +
  `Cascade.Console`, `Start.Dequeue.Lambda`, `UpdateCacheState.Lambda` +
  `UpdateCacheState.Console`/`.Domain`. All ship together when its release branch is cut.

**So Step 5's Lambda verification must check ALL of these individually**, not just each
repo's main ECS service — see the step→Lambda mapping table in
[[ama-graylog-search]]'s `CACHE-UPDATE-DEBUGGING.md` for the exact per-step Lambda names
(cross-reference, don't re-derive it here).

## Step 5 — Verify: builds succeed, AWS/CloudWatch clean, Graylog clean

All targeting **Staging**, not QA (the release branch deploys to Staging, not QA):

1. **Builds**: per deployable repo,
   `bash ~/.claude/skills/ama-bitbucket-api/scripts/pipeline-status.sh <repo> release/<version> --wait`
   (retries the not-yet-in-the-API window itself). A repo can have a **chronically broken**
   pipeline unrelated to this cut (`export-cohort`, red Nov 2025–Sep 2026) — check its
   recent history before blaming the cut; already red = pre-existing bug to ticket.
1a. **Octopus deploys — a green build does NOT mean it deployed.** The pipeline's last
   step only CREATES the Octopus release; Octopus deploys it separately and fails
   separately. **Mandatory, not optional:**
   ```bash
   bash ~/.claude/skills/ama-octopus-deploy/scripts/verify-octopus-env-deploys.sh <staging> <YYYY-MM-DD>
   ```
   Exits 1 and names any project whose release from that date is not `Success` on Staging.
   Retry a failed one by POSTing the same `ReleaseId` + `EnvironmentId` again
   ([[ama-octopus-deploy]]). Live on the 130 cut: 17/17 builds green and every ECS service
   steady, while `CacheUpdate_UpdateCacheState_Lambda` sat Failed (Terraform "timeout
   while waiting for plugin to start" — worker flake, clean on retry), leaving Staging
   with 3 cache-update Lambdas on new code and 1 on the old. **No build check and no ECS
   check can see this** — a Lambda-only project has no service to look steady.
2. **AWS/CloudWatch — ECS services**: reuse [[ama-cloudwatch-search]]'s `AWS-SWEEP.md`
   checklist and `verify-qa-deploy.sh`/`verify-deployment-e2e.sh` with `AMA_ENV=staging`
   (they default to `qa`; the var switches cluster and both log-group name shapes to
   `staging-v1-*`, confirmed live 2026-09-15). Pass the 5th arg (expected image tag,
   `2.0.0.<build>`) — a service can be perfectly steady on the PREVIOUS release.
   **`cohortdata` has no ECS service** — it deploys as the Lambda
   `staging-v1-cohort-data`; `<env>-v1-cohorts-api-esvc` is **`export-cohort`**'s.
3. **AWS/CloudWatch — cache-update Lambdas**: `verify-qa-deploy.sh <repo> lambda
   <function-name>` per Lambda (deployment-success check only — Lambdas don't run until
   invoked, see `DEPLOY-VERIFICATION.md`'s existing Lambda scope). Use the
   `staging-v1-<suffix>` naming from `CACHE-UPDATE-DEBUGGING.md`'s table for each
   function name, and don't forget the `cacheupdate-infrastructure`-internal ones
   (`APIGateway`, `Start.Dequeue`, `UpdateCacheState`, `Cascade`, `CacheClear`) alongside
   the per-step ones. **Cheapest whole-fleet check first**: `aws lambda list-functions`
   filtered to `staging`, read `LastModified` — anything not stamped with today's deploy
   is the one that didn't roll out. That is exactly how the 130 cut's failed
   `UpdateCacheState` Octopus deploy surfaced: it still carried the previous release's
   date while its three siblings carried today's.
4. **Graylog**: reuse [[ama-graylog-search]], `environment:staging` instead of `environment:qa`.
5. **API/UI smoke tests** (optional, offer don't auto-run): `api-testing`/`ui-testing`
   exist for exactly this (see [[ama-architecture-notes]]'s `TESTING-REPOS.md`) but
   **don't fire automatically** — no PR/schedule trigger in either repo's pipeline, only
   manually/API-triggered `custom:` pipelines. If verification should include them,
   trigger the relevant `custom` pipeline explicitly (same Bitbucket API pattern as
   [[ama-bitbucket-api]]) targeting `staging` — don't assume cutting the release branch
   already ran them.

## If a cut goes wrong partway, recover by deleting and redoing — no partial fix

There's no in-place repair path: delete the branch (`git push --delete origin
release/<version>` + local `-D`) on every repo it was cut on, then redo Steps 3/4 from
scratch (precedent: `local-infrastructure`'s retired `cleanup-release-121.sh`, see
[[ama-architecture-notes]]'s `SHARED-INFRA-AND-PIPELINES.md`). This skill doesn't use
git-flow or tags, so there's only the branch to clean up, not a tag too.

## What this skill does NOT cover (separate, later skills)

- Deploying the release build further (Staging → Production promotion) and the actual
  release-day cutover (merge to master/develop, verify, deploy, revert path, branch
  cleanup) — that's `ama-deploy-release`.
- Post-deployment release notes — that's the existing `ama-release-notes` skill.
