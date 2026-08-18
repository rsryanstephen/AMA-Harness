# AWS reference — beyond just CloudWatch logs

## Standing rule: any AWS setting change needs a matching Terraform update

Infra here is Terraform-managed (see `cacheupdate-infrastructure`, `octopus`'s pinned
binary, etc.). A change made only via `aws` CLI/console-equivalent (not through
Terraform) drifts from source of truth immediately — next `terraform apply` silently
reverts it, or masks the real config from anyone reading the `.tf` files. Whenever an
AWS setting is changed directly, make the equivalent edit in the underlying Terraform
code in the same piece of work, not as a follow-up. If no Terraform source exists for
that resource, say so rather than silently leaving it AWS-only.

Confirmed against the live account (000000000000, us-east-1 — mirrored as
`aws.accountNumber`/`aws.region` in `~/.claude/harness-config.json`, the source of truth for a
different adopter). CloudWatch logs are
only part of the picture for ECS — a task can die with nothing useful in its logs at all (killed
before it could log, or the crash is at the container/orchestration level, not app level). These
other AWS surfaces cover that gap.

## Naming conventions do NOT match across AWS surfaces — don't assume

For the same logical service (e.g. `cohorts-api` in `qa`), three different AWS resources use
three DIFFERENT name shapes:

| Resource | Naming pattern | Example |
|---|---|---|
| CloudWatch log group | `/aws/ecs/<env>-v1-ama-<repo>` | `/aws/ecs/qa-v1-ama-cohorts` |
| ECS service name | `<env>-v1-<repo>-api-esvc` | `qa-v1-cohorts-api-esvc` |
| ECS task definition family | `<env>-v1-<repo>-api` (no `-esvc`) | `qa-v1-cohorts-api` |

Don't derive one from another — resolve each independently:
```bash
MSYS_NO_PATHCONV=1 aws ecs list-services --cluster <env>-v1-AMA --max-items 100
MSYS_NO_PATHCONV=1 aws ecs list-clusters
```
Cluster naming: `<env>-v1-AMA` (confirmed `production-v1-AMA`, `qa-v1-AMA`, `staging-v1-AMA`) — note
the capital `AMA`, unlike the lowercase `ama` in log group names.

**Further exceptions:**
- **The repo's local folder name can differ from the AWS short name entirely, not just in
  format** — `cohortdata` (local folder, and the actual repo) → ECS service
  `qa-v1-cohorts-api-esvc` / log group `/aws/ecs/qa-v1-ama-cohorts`. No substring relation
  at all; "cohorts" isn't derivable from "cohortdata" by any mechanical rule. Don't assume
  a keyword search on the repo name will find it — if zero services match, try dropping
  back to the domain noun (`cohorts`, not `cohortdata`) or check with the user.
- **The `-esvc` suffix isn't universal** — `search`'s QA service is
  `qa-v1-search-api-isvc` (`isvc`, not `esvc`), no documented reason why. Always try both
  before concluding a service doesn't exist.
- Also seen: `qa-v1-exporterplus-api-esvc` exists in the QA cluster despite exporterplus
  being an S3-hosted frontend — but it's scaled to `desiredCount=0`/`runningCount=0`, a
  dormant relic, not a live BFF. Don't be surprised it shows up in `list-services`; check
  `desiredCount` before assuming it means exporterplus has a real backend service.
- **`exportproducer`'s log group drops the `ama` infix**: `/aws/ecs/qa-v1-exportproducer`,
  not `/aws/ecs/qa-v1-ama-exportproducer` like every other service tested (confirmed via
  its task definition's `awslogs-group` setting). Two name shapes exist fleet-wide for
  this one field — try both before concluding a service has no log group at all.
- Confirmed clean across the rest of the fleet's ECS-backed API services too: `export`,
  `feedback`, `fieldtablemapper`, `manage`, `notifications`, `querybuilder`, `reports`,
  `resultsprocessor` all follow the standard `-api-esvc` / `/aws/ecs/qa-v1-ama-<repo>`
  shape with no surprises. `cacheupdate-infrastructure` has no ECS service of its own —
  it's pure Terraform/Step-Functions infra.
- **`cacheupdatecoordinator` is decommissioned — ignore it.** Its ECS service
  (`qa-v1-cacheupdatecoordinator-api-esvc`) still shows up in `list-services`, but don't
  treat that as a live target for deploy verification or debugging; confirmed by the user,
  not something to rediscover from AWS state alone.

## ECS: why did a task actually stop? (often NOT in CloudWatch logs at all)

A crashed/killed container may log nothing before dying. ECS itself records why it stopped,
independent of the app's own logs:

```bash
MSYS_NO_PATHCONV=1 aws ecs list-tasks --cluster <env>-v1-AMA --desired-status STOPPED --max-items 10
MSYS_NO_PATHCONV=1 aws ecs describe-tasks --cluster <env>-v1-AMA --tasks <task-arn>
```
Look at:
- `.tasks[].stoppedReason` / `.stopCode` — ECS's own reason (e.g. a normal deployment-triggered
  scale-down reads `"Scaling activity initiated by (deployment ecs-svc/...)"`, `stopCode`
  `ServiceSchedulerInitiated` — routine, not a crash).
- `.tasks[].containers[].exitCode` / `.reason` — the container's actual exit code. `137` = SIGKILL
  (128+9) — commonly OOM-killed by the kernel, or a forced termination during redeploy; a `null`
  `reason` alongside 137 doesn't mean nothing happened, just that ECS didn't capture a text reason
  for that particular kill. Cross-reference the task's CPU/memory limits and the timing against a
  deploy event before concluding it was a resource issue vs. routine redeploy churn.

## ECS: service-level deployment/scaling narrative

```bash
MSYS_NO_PATHCONV=1 aws ecs describe-services --cluster <env>-v1-AMA --services <service-name>
```
`.services[].events[]` is a rolling log of scheduler activity (steady-state reached, task started/
stopped, deployment progress) — useful for "was this service mid-deployment when X happened" without
needing CloudWatch at all. Cheap to check first since it needs no log-group resolution.

## ElastiCache engine upgrade runbook (exporter fleet redis 5.0.6 → 6.2.6, proven staging+qa 2026-08-13, prod 2026-08-14 — whole fleet now 6.2.6)

These clusters are CLI/console-managed — **no Terraform covers ElastiCache** (grepped
every infra repo), so the usual AWS-change-needs-Terraform rule doesn't apply here.

1. Manual pre-upgrade snapshot first: `aws elasticache create-snapshot
   --cache-cluster-id <rg>-001 --snapshot-name <rg>-pre-upgrade-backup`.
2. **Version selector is the MINOR string, not the patch**: `--engine-version 6.2.6`
   is rejected (`InvalidParameterValue ... please use '6.2'`); pass `6.2`, it lands on
   6.2.6. Param group must move in the same call:
   ```bash
   aws elasticache modify-replication-group --replication-group-id <rg> \
     --engine-version 6.2 --cache-parameter-group-name default.redis6.x --apply-immediately
   ```
3. Watch `describe-events --source-identifier <rg> --source-type replication-group`
   for `Replication Group <rg> engine upgraded` (~17 min staging). Cache CONTENTS
   survive the upgrade (confirmed: BytesUsedForCache flat across the boundary).
   **The `engine upgraded` event is NOT the end** — node patching continues ~10 more
   min with connection failovers (clients log `ConnectionFailed` then
   `ConnectionRestored`, transient). Don't run a cache update or drive traffic until
   the cache-cluster `patched` events land and errors go quiet — a QA cache update
   fired 1 min after "engine upgraded" overlapped the patching and produced a burst
   of transient 23502 DynamicColumn insert rejections (harmless — constraint blocked
   the writes — but it cost a re-run to prove cleanliness).
4. Post-upgrade gotcha: `NewConnections` drops to exactly 0 on 6.x — metric-semantics
   change, not lost connectivity (see the metrics note elsewhere in this file).
   `CurrConnections` is the one to trust.
5. Validate by *exercising*, not just log silence: main cache update + a FromCache
   report drive ([[ama-ui-verify]]'s `drive-report-fromcache.mjs`) + error sweep vs a
   pre-upgrade window with cancellation noise excluded.

## `desiredCount=0` on some ECS services is CORRECT — don't read it as an outage

Confirmed live 2026-08-13. Two services in `<env>-v1-AMA` are **discontinued** and sit at
`desiredCount=0`/`runningCount=0` permanently:

| Service | Why it's 0 |
|---|---|
| `<env>-v1-exporterplus-api-esvc` | `exporterplus` itself is alive — it just deploys to **S3** now, not ECS (see [[ama-architecture-notes]] FRONTEND-ARCHITECTURE.md's build/deploy section). The ECS service is the dead remnant. |
| `<env>-v1-cacheupdatecoordinator-api-esvc` | Discontinued outright. |

Both were zeroed 2026-07-22. Their `events[]` still log `has reached a steady state` on a
6-hourly cadence, so the narrative above looks healthy — that's not evidence they're
serving anything. **Never scale either back up to "restore" it**, and never cite either
as the cause of missing traffic/cache activity. Only `exporterplus`'s S3 deployment
serves that UI.

## Step Functions: no state has Retry configured, fleet-wide

Checked every `Update <Step>` state in `qa-v1-cacheupdate-statemachine`'s definition — zero `"Retry"`
blocks anywhere, only `"Catch"` (which handles failure AFTER giving up, routing to a failure-status
path — it does not retry). This is why a transient error (e.g. `CodeArtifactUserPendingException`
during Lambda cold-start, see [[ama-graylog-search]]'s CACHE-UPDATE-DEBUGGING.md) fails the whole run
immediately instead of succeeding on a retry a few seconds later.

**Source of truth**: `~/Repos/AMA_APP/cacheupdate-infrastructure/StateMachine/main.tf` (Terraform,
`aws_sfn_state_machine` resource, ASL embedded as an inline heredoc string) — NOT
`StateMachine/state-machine.json` in the same directory, which is a stale/separate artifact with
no matching state names. Edit the ASL in `main.tf`, not the live state machine directly via
`aws stepfunctions update-state-machine` — that would drift from the Terraform source of truth.

Standard ASL fix for a transient-error state (add alongside the existing `Catch`, doesn't replace it):
```json
"Retry": [ {
  "ErrorEquals": ["Lambda.AWSLambdaException", "Lambda.TooManyRequestsException"],
  "IntervalSeconds": 5,
  "MaxAttempts": 3,
  "BackoffRate": 2.0
} ]
```
Applies to every `Update <Step>` state the same way — this is a fleet-wide gap in the pipeline, not
specific to the Search/Selenium step where it was first noticed.
