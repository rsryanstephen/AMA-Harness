# Verifying a QA deployment after a push to develop

Pushing to `develop` on an AMA_APP repo triggers an automatic deployment to QA (already
set up, outside Claude's control — nothing here triggers it, this only checks its result).

**Never run this automatically.** Offer it after a develop push, wait for an explicit
yes/no — it takes 12-15 minutes for most services, longer for `search`, so it's not
something to silently block on. Declining is a normal answer (e.g. a small fix), not a
fallback to talk the user out of. **Gate-enforced**: `deploy-verify-confirm-gate.sh`
denies launching `verify-qa-deploy.sh`/`verify-deployment-e2e.sh` until
`confirm-deploy-verify.sh` records a yes for this session (one-shot — a later push asks
again).

**Never launch it from a subagent that returns before it finishes** — see CLAUDE.md's
"Subagents Must Never Return With Live Background Work". Launch from the main session
with Bash `run_in_background: true`, or have a subagent wait on it synchronously.

**Always check in this order: build → Octopus → AWS. Never start with AWS.** Starting
with AWS means verifying against what may be the OLD deployment. If the build hasn't
finished (or failed, or was never triggered), any AWS
check is just describing the previous deploy, not this one — wasted work, not a
finding. This is exactly the order `verify-deployment-e2e.sh` already encodes (see
below) — follow the same order even when checking things by hand instead of running
that script.

## Scope — not every repo, not every kind of check

- **Excluded entirely**: `admin`, `exporterplus` — S3-hosted frontends, no ECS
  task/Lambda runtime to check (see below for what to do instead).
- **ECS-backed API services** (`manage`, `search`, `reports`, `resultsprocessor`,
  `export`, `cohortreports`, `cohorts`, etc.) → full check: deployment reached steady
  state, no crash-loop restarts, no error-level log spam.
- **Lambdas** → deployment-success check only (`LastUpdateStatus=Successful`, new
  `LastModified`). **Don't check runtime health** — a Lambda doesn't run until invoked,
  so "is it running without errors" doesn't apply the way it does for an ECS task.
  **These fields are NOT proof the code actually changed** — see [[ama-octopus-deploy]]'s
  Lambda-staleness gotcha, they can look updated while old code keeps running.

## UI fixes (admin/exporterplus): local run and verify UI output before deploy, not AWS after

No AWS check applies (S3-hosted, no runtime) — see [[ama-ui-verify]] instead for the full
standing rule (self-verify → fix loop → user local sign-off, before any deploy).

## Running it

```bash
# ECS-backed API service (default 15 min max wait; pass a higher number for search)
bash ~/.claude/skills/ama-cloudwatch-search/scripts/verify-qa-deploy.sh <repo> ecs [max-wait-minutes]

# Lambda (function name isn't derivable from repo name -- resolve it first with
# cloudwatch-find-log-group.sh <keyword> or `aws lambda list-functions`)
bash ~/.claude/skills/ama-cloudwatch-search/scripts/verify-qa-deploy.sh <repo> lambda <function-name>
```

ECS mode polls `describe-services` every 30s until `rolloutState=COMPLETED` and
`runningCount=desiredCount`, then checks for tasks that stopped for a non-routine reason
(a normal deploy scale-down reads `stopCode=ServiceSchedulerInitiated` — that's expected,
not a crash; anything else since the deploy started is flagged), then scans the CloudWatch
log group for `ERROR`/`Exception`/`Fatal` in the same window via
[cloudwatch-search-logs.sh](scripts/cloudwatch-search-logs.sh).

**This can run long** — for `search` (slower than other services) or if the
default 15-minute poll window isn't enough, run it with `run_in_background` rather than
blocking, or pass a higher `max-wait-minutes`.

**Verifying a specific fix (e.g. "did this error stop appearing") → still check steady
state first, don't hand-roll a narrower check that skips it.** A custom check that only
watches for one log line never notices a crash-looping build — and a crash-looping task
never boots far enough to log the thing you're checking for, so "the bad line is gone"
is a false-negative "success," not real confirmation. Build on
`verify-qa-deploy.sh`'s actual polling (bounded `max-wait-minutes`, `rolloutState`, the
crash-loop check above) instead of writing a fresh unbounded poll — it already covers the
foundational case a narrower custom check can silently miss.

## What counts as an error worth flagging vs. normal noise

Still a first pass — this hasn't been tuned against a real fleet-wide error taxonomy yet.
Treat as a starting point, refine as false positives/negatives show up:
- Routine: a single scale-down task stop during deploy (`ServiceSchedulerInitiated`),
  informational-level log lines, expected startup warnings already documented in
  [[ama-debugging-notes]].
- Worth flagging: any task stop with a different `stopCode`, a non-zero container
  `exitCode` after the deploy window started, repeated restarts of the same task
  definition, or `ERROR`/`Exception`/`Fatal` lines in the post-deploy log window that
  aren't already a known signature (check [[ama-graylog-search]]'s `KNOWN-SIGNATURES.md`
  first — same known-noise logic applies here).

## Naming reminders (see [AWS-REFERENCE.md](AWS-REFERENCE.md) for the full table)

Cluster `qa-v1-AMA`, service `qa-v1-<repo>-api-esvc`, log group
`/aws/ecs/qa-v1-ama-<repo>` — three different name shapes for the same repo, don't derive
one from another.

## Full end-to-end check (Bitbucket → Octopus → AWS), not just AWS

For tracing one specific push all the way through — not just "is QA healthy right now" —
use [verify-deployment-e2e.sh](scripts/verify-deployment-e2e.sh) instead. Same offer-only
rule applies.

```bash
bash ~/.claude/skills/ama-cloudwatch-search/scripts/verify-deployment-e2e.sh <repo> [bitbucket-repo-slug-override] [ecs-short-name-override]
```

Checks, in order: (1) latest Bitbucket `develop` pipeline status — stops here if
FAILED/IN_PROGRESS; (2) resolves the matching Octopus project in `Spaces-1` (mirrored as
`octopus.spaceId` in `~/.claude/harness-config.json`) and confirms
its release version; (3) delegates to `verify-qa-deploy.sh` for the AWS/ECS check, now
also confirming the **deployed image tag** matches the expected version, not just that
the service is steady (a steady service can be steady on the OLD version).

**For triggering/resolving Octopus itself** (space/project/environment/channel
resolution, triggering a deployment directly, task polling, the version-is-the-cross-
system-key convention, the hostname/project-name-collision gotchas, the Bitbucket-branch
workaround if Octopus is unreachable) — that's all moved to its own skill, [[ama-octopus-deploy]].
This script only reads Octopus far enough to confirm the deployed version matches what
was expected; it doesn't trigger anything.

## Post a completion summary to the support Slack channel (`slack.amaSupportChannelName`)

Once verification above actually confirms a deploy landed clean (steady state / build
success, no crash-loop, no error-level log spam) — staging, QA, or production, any repo —
post a short summary to Slack channel **#<amaSupportChannelName>**
(`slack.amaSupportChannelId` in `harness-config.json`). **Standing instruction (per
explicit user request), do this every time, not a one-off ask** — this is the one step
in the whole deploy flow that's a plain notification (not a merge/push/revert), so it
doesn't need the same per-step confirmation the rest of [[ama-deploy-release]] does.

Keep it short — repo(s)/service(s), version, environment, verification result. A few
lines, not a transcript dump. **Production deploys additionally include the api-testing
results** (`production` + `production_exports` custom pipelines, run in serial — see
[[ama-deploy-release]]'s Step 5a) — hold the post until both finish, don't post AWS-only
verification first and follow up separately. **Don't post if verification found a real problem and the
deploy is still being investigated** — post once it's actually confirmed healthy, or, if
reverted, post that outcome instead once the revert itself is confirmed. Silence during
an active incident is correct; a premature "all good" post is worse than no post.
