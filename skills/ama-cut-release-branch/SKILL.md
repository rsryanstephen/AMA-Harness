---
name: ama-cut-release-branch
description: Cut a new AMA_APP release branch (release/<next-version>) from develop, tag included tickets with the release Fix Version, check for out-of-date library refs. Use for "cut a release branch", "cut the release", "start a release" -- the FIRST stage of a release, before deploying it.
---

# Cut an AMA_APP release branch

**Never run this automatically — always confirm with the user before pushing any branch.**
This creates real branches visible to the whole team and triggers real Staging
deployments fleet-wide. Treat every step below as "propose, then execute on go-ahead,"
not a silent one-shot script.

## Step 1 — Get the next release version from Jira

Query Jira directly (not Confluence — that's `ama-release-notes`' method, kept separate):

```
JQL: project = PROJ AND fixVersion is not EMPTY ORDER BY created DESC
```
`maxResults = 1`, fields `fixVersions`, via [[ama-jira-api]]'s `jira-search.sh` — only
the first result's version is used, no need for the rest of the project or full objects.
Take the first result's `fixVersions[0].name` (format `release/X.0.0`). Increment the
major segment by 1 (matches `ama-release-notes`' existing scheme), e.g. latest
`release/127.0.0` → next `release/128.0.0`.

**When asking the user to create the new release's Fix Version in Jira (Step 3a), give
them the previous release's production-deploy date** — same Octopus-deployment-history
method [[ama-release-notes]]'s Step 3 already uses for this, don't invent a second one.

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

```
project = PROJ AND assignee in (currentUser(), <ama.etlAssigneeAccountId from
harness-config.json — Reviewer One>) AND status in ("QA", "Ready to Test", "Test Complete")
AND fixVersion != "release/<previous-version>"
```

`<previous-version>` is the release resolved in Step 1 (the one being superseded by
this cut) — exclude it explicitly so a ticket already tagged/bundled into that release
doesn't get pulled into this one too, even though its status alone (QA/Ready to
Test/Test Complete) would otherwise still match. Confirm exact status names via
[[ama-jira-api]]'s `jira-get-transitions.sh` rather than hardcoding. Every ticket the query returns
gets tagged — no further code check.

**Before tagging anything, confirm `release/<version>` exists in Jira.** There's no MCP
tool or REST auth here to create a Fix Version — check
`~/.claude/.confirmed-jira-versions` first; if it's not there yet, ask the user to
create it in Jira project settings, then run
`bash ~/.claude/hooks/confirm-jira-version.sh release/<version>`. The
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
   [{"name": "release/<version>"}]}}`) or MCP `editJiraIssue` with the same fields.
3. **Once this Staging deploy is confirmed stable**, transition per ticket (`jira-
   transition-issue.sh` or MCP `transitionJiraIssue`): testable by
   a human → Ready to Test/QA + a comment (`jira-add-comment.sh` or MCP
   `addCommentToJiraIssue`) with concrete testing instructions;
   otherwise → Test Complete directly. Same conditional as [[ama-hotfix]]'s Step 2a
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

1. **Builds**: poll each deployable repo's newly-triggered `release/<version>` Bitbucket
   pipeline to `COMPLETED`/`SUCCESSFUL` (see [[ama-bitbucket-api]] for the auth pattern).
   **False-negative trap**: polling too soon after the push can find no pipeline yet
   (looks like "not found"/failed) when it just hasn't appeared in the API yet — retry
   before concluding a repo failed to build. Separately, a repo can have a
   **chronically broken** `develop`/release pipeline unrelated to this cut (e.g.
   `export-cohort`, red since Nov 2025) — check its recent build history before treating
   a failure as caused by the cut; already red = pre-existing bug to ticket, not a
   release-cut regression.
2. **AWS/CloudWatch — ECS services**: reuse [[ama-cloudwatch-search]]'s `AWS-SWEEP.md`
   checklist and `verify-qa-deploy.sh`/`verify-deployment-e2e.sh`, pointed at the
   `staging` environment instead of `qa` (cluster `staging-v1-AMA`, log groups
   `/aws/ecs/staging-v1-ama-<repo>` — same naming shapes as `qa`, just the `staging` env
   prefix; confirm before assuming identical, per that skill's own naming-mismatch
   precedent).
3. **AWS/CloudWatch — cache-update Lambdas**: `verify-qa-deploy.sh <repo> lambda
   <function-name>` per Lambda (deployment-success check only — Lambdas don't run until
   invoked, see `DEPLOY-VERIFICATION.md`'s existing Lambda scope). Use the
   `staging-v1-<suffix>` naming from `CACHE-UPDATE-DEBUGGING.md`'s table for each
   function name, and don't forget the `cacheupdate-infrastructure`-internal ones
   (`APIGateway`, `Start.Dequeue`, `UpdateCacheState`) alongside the per-step ones.
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
