---
name: ama-octopus-deploy
model: sonnet
description: Trigger, check, or promote an Octopus Deploy deployment for AMA_APP. Use for "deploy the pilot to QA", "deploy this branch to staging", "promote the release to production", "ship this to prod", "do I have Octopus access", "what's currently deployed to X", or before guessing at Octopus server/space/project naming.
---

# Octopus Deploy for AMA_APP

See [OCTOPUS-REFERENCE.md](OCTOPUS-REFERENCE.md) for the full API reference — auth, space,
project naming, environments, channel lifecycles, key endpoints, and a confirmed
end-to-end deployment example. Read it before hand-rolling a call.

## Watch every deploy (2026-10-14)

Deploy POSTed, or handed to the user to approve → `bash ~/.claude/scripts/octopus-task-watch.sh <ServerTasks-N> <sid>` as Bash run_in_background (`--next <project> <Environments-N>` before the task exists). Silent until done; FAILED = error lines + cause → debug now, never wait for the user. Hooks enforce it: `octopus-deploy-watch-reminder.sh`, `octopus-approval-watch-check.sh`. One watcher per task across sessions (claim dir `harness-state/octopus/watched/`). Production retries stay the user's to run; everything up to the retry command is Claude's. Why (user rule 2026-10-14): ExporterPlus 2.0.0.114 failed twice in Production and the session only learned when the user pasted the link.

## Production POST — prove the release can reach it first (2026-10-14)

`bash ~/.claude/skills/ama-octopus-deploy/scripts/oct-release-progression.sh <Releases-N> <production>`
before every prod `POST /deployments`. Exit 3 = no Production phase in that release's
lifecycle (every hotfix-channel release of the Lambda projects and of search-api
Projects-95): merge to master, deploy the MASTER-channel release. `deploy-lambda.sh` runs the
same check itself. Detail: `OCTOPUS-REFERENCE.md` "Hotfix channel".

## Green build — deployed. Sweep the whole env instead of trusting pipelines

```bash
bash ~/.claude/skills/ama-octopus-deploy/scripts/verify-octopus-env-deploys.sh <Environments-N> [YYYY-MM-DD]
```
`<qa>` QA, `-23` Staging, `-24` Production. With a date, exits 1 and names any
`YourProduct_Exporter_*` project whose release assembled that day is not `Success` in that
environment. A Bitbucket pipeline's last step only CREATES the Octopus release — the
deploy runs and fails separately, and for a Lambda-only project there is no ECS service
to look unsteady, so nothing else catches it (see [[ama-cut-release-branch]] Step 5 1a
for the live 130-cut case).

## Don't guess the server hostname

**Server is `https://yourorg.octopus.app`** (mirrored as `octopus.serverUrl` in
`~/.claude/harness-config.json` — swap that field for a different adopter).
`octopus.<tenant domain>` resolves via internal DNS but its HTTPS connection times
out — not a real endpoint. If
the correct host fails to resolve, check the transient-VPN-DNS-blip note in
[[commit-ticket]] before assuming the server itself is unreachable.

## Repo name → Octopus project isn't a plain substring match

A loose match on `search` also matches `etl-load-elasticsearch-emr` and
`backbone-elasticsearch` ("search" inside "elasticsearch"). Anchor to
`YourProduct_Exporter_<Repo>..._ECS` and require the `_ECS` suffix specifically — some repos (e.g. `search`) also have a coincidentally
same-versioned `-cacheupdate-lambda` project that isn't the one you want.

**Real names are underscore-separated title-case with an `_ECS` suffix** — e.g.
`YourProduct_Exporter_Feedback_API_ECS` (Projects-68), `YourProduct_Exporter_Search_API_ECS`
(Projects-95). Matching the hyphen-lowercase repo slug finds NOTHING (confirmed live
2026-08-31: `test("-ecs$")` over all 114 projects returned zero).

**The decoy: `Backbone_Applications_AMA_<Repo>` projects also exist and look right.** They
carry **0 releases** — legacy/infrastructure-era. `Backbone_Applications_AMA_Feedback`
(Projects-154) is not the Feedback deploy project; Projects-68 is. **Check the release count
before trusting a name match** — `GET /api/<space>/projects/<id>/releases?take=1` →
`TotalResults`. Zero releases on a plausible-looking name means wrong project, not an
undeployed service.

If resolution still isn't unambiguous (zero or multiple projects share the expected
version), stop and list the candidates rather than guessing — flag it to the user.

## Version is the cross-system key

`build-and-publish.sh` hardcodes ECS Docker tags as `2.0.0.<BITBUCKET_BUILD_NUMBER>` — no
`VersionPrefix`, no branch suffix (unlike the NuGet path in `package.sh`). The same value
shows up as the Octopus release version and the deployed image tag.

**A service being up/healthy/responding is NOT proof it's running the version Octopus
says it deployed — always cross-check the actual running image tag against Octopus's
release version, don't infer from "it's working."** A working ECS task and a
correctly-deployed ECS task are different claims.

**"Running image tag" means the RUNNING TASK's image, not the service's task definition**
— `aws ecs list-tasks --desired-status RUNNING` then `aws ecs describe-tasks --query
'tasks[].containers[0].image'`. **Not** `describe-services`/`describe-task-definition`:
the service points at the new revision from the moment a rolling deploy starts, so for
the whole rollout window it tells you what was *requested*, not what is *serving*. This
line used to say `describe-task-definition` and that is exactly how PROJ-15355 got a
correct fix reverted — see `OCTOPUS-REFERENCE.md`'s "What did we ask for vs what is
serving". Easiest correct route: don't hand-roll it — `verify-deployment-e2e.sh`, or
`verify-qa-deploy.sh` with the expected version as arg 5.

E.g. `reports` crash-looped on build `204`, so ECS kept serving `203` while Octopus
still reported `204` as deployed — invisible precisely because nothing failed outright.

**A version "mismatch" doesn't always mean stale.** `BITBUCKET_BUILD_NUMBER` is a per-repo
counter shared across ALL branches, not per-branch. If `develop` hasn't been pushed in a
while but `master` has, the latest `develop` build number can be LOWER than what's
actually deployed (e.g. `cohortdata` develop build `#31` vs QA running `#313` — not a
regression). Read a mismatch as "not verified against the build just pushed," not
automatically "QA is behind."

## exporterplus (and other S3-bundle apps): the ECS tag is the WRONG instrument

The image-tag rule above is for ECS-deployed services. `exporterplus` deploys as an **S3
bundle** — Octopus project `Projects-65 YourProduct_Exporter_ExporterPlus_S3` (`_S3` suffix
is the tell). The `staging-v1-exporterplus-api-esvc` ECS service is just the static host:
its task-def sat at rev `:165` / image `2.0.0.657` from 2026-07-22 while Octopus shipped
`2.0.0.25x` bundles daily — the numbers aren't even from the same counter epoch (repo
migration reset). A watcher polling that tag for a new bundle version spins forever
(cost a real stuck-watcher incident, 2026-08-19).

Confirm an exporterplus deploy with BOTH:
1. `GET /api/<space>/projects/Projects-65/progression` → the release shows the target
   environment with `Success`.
2. A **behavioral probe** of the served app (drive it via [[ama-ui-verify]] and observe
   the changed behavior, or diff a served asset hash) — this is the S3 equivalent of the
   running-image-tag check, and it also covers CDN/browser cache staleness, which the
   Octopus Success alone does not.

## Deploying a Lambda — delete the existing function first, or it silently runs stale code

Octopus/Terraform deploying over an EXISTING Lambda can leave the old code running even
though `LastModified`/`CodeSize`/`Runtime` all look updated (a stale build kept running
under a flipped runtime, crashing every invocation).
Fix: `aws lambda delete-function --function-name <env>-v1-<name>` before every Octopus
Lambda deploy, not just misbehaving ones. Verify via the deployed zip's
`*.runtimeconfig.json` `tfm` (`aws lambda get-function` → `Code.Location`), not just the
`Runtime` field.

**Gate-enforced** (`octopus-lambda-delete-gate.sh`): a `POST .../deployments` is denied
unless a `delete-function` was recorded this session. Not a Lambda project → prefix
`OCTOPUS_TARGET_NOT_LAMBDA=1`. Prose alone did NOT hold — see below.

**Use the wrapper, not hand-rolled delete+POST:**
```bash
bash ~/.claude/skills/ama-octopus-deploy/scripts/deploy-lambda.sh <Environments-NN> <qa|staging|production> <Releases-N> <function-suffix> [--expect-env NAME]
```
Does, in order: progression dry-check (target unreachable → exit 3, nothing deleted) → note previous good release → delete-function → POST (prints `.ErrorMessage` + `.Errors[]`) → wait task, auto re-POST once on worker death → verify function Active (+ env var NAME present, name only). Failure after delete → says function ABSENT + previous release id to redeploy; exit 1. Caller sets gate hatches (`AMA_PREFLIGHT_ACK` etc.). Run it in 1 call per Lambda; ~4 concurrent max (28 at once broke 2 on 130).
Why: **refused POST after delete-function = prod has NO function** (lifecycle/preflight/business-hours refusal; 2026-10-14 reports+notifications absent ~10 min).
**Terraform "Could not load plugin"/"timeout while waiting for plugin to start"/"Failed to release package lock"** = shared-worker contention/crash: retry once (script does) (tracked: PROJ-15796 dedicated worker pool / PROJ-15791). Retire these notes when that ships.
**`POST /deployments` error**: `.ErrorMessage` generic ("There was a problem with your request"); real reason in `.Errors[]`.

**Verify the ARTIFACT after every Lambda deploy, not the task state** — a green task and a
fresh `LastModified` are both consistent with the old code still running:
```bash
bash ~/.claude/skills/ama-octopus-deploy/scripts/verify-lambda-artifact.sh <name>   # e.g. cacheupdate-updatecachestate-lambda
```
Compares `CodeSha256` across staging/qa/production. `STALE` ⇒ delete the function, redeploy
the SAME release, re-run. Do NOT check DLL dates in the zip instead — deterministic builds
give every sibling the same old date (script header has the incident).

## Changed a variable? Redeploying an EXISTING release still ships the OLD value

**Octopus snapshots variable values into a release at creation time — redeploying an
existing release replays that snapshot, it does NOT pick up live variable edits.**
Same class of "looks deployed, isn't really" mistake as the Lambda-stale-code gotcha
above.

After changing any variable, before redeploying an EXISTING release (not creating a
new one): refresh that release's snapshot first.

```bash
curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" \
  "https://yourorg.octopus.app/api/Spaces-1/releases/<release-id>" | jq -r '.Links.SnapshotVariables'
curl -sS -X POST -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" \
  "https://yourorg.octopus.app/api/Spaces-1/releases/<release-id>/snapshot-variables"
```

Then redeploy. Verify the actual effect landed (fetch the live served config/response),
not just that the deployment task succeeded — a successful deploy of a stale snapshot
still reports success.

## Can't reach Octopus at all? A Bitbucket-branch workaround exists

Re-running/pushing a Bitbucket pipeline on `develop` auto-deploys to **QA** (`develop` →
Testing channel, set to auto-deploy QA). Running one on a `release/*` branch (check Jira
for the current release number) auto-deploys to **Staging**. If Octopus itself is
unreachable/unverifiable, triggering the right Bitbucket branch still gets a build
deployed without needing direct Octopus access — see [[ama-bitbucket-api]] for triggering.

## Creating a release via API (`POST /releases`)
- Lifecycle with automatic first phase → Octopus AUTO-DEPLOYS the new release on creation. Do NOT also `POST /deployments` → two tasks per release, the forgotten twin waits at approval (2026-10-15: 5 strays, 2 would strip ClientCorp tags). After create: `GET /deployments?projects=<P>&take=2` first, deploy only if none.

## After triggering a deployment

Hand off to [[ama-cloudwatch-search]]'s `DEPLOY-VERIFICATION.md` (`verify-qa-deploy.sh` /
`verify-deployment-e2e.sh`) to confirm it actually landed clean on the AWS/ECS side — this
skill covers the Octopus half, not the runtime-health half.
