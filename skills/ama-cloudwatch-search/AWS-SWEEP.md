# AWS sweep — checking for restart loops / crash noise across a fleet environment

Trigger phrase: user asks for an "AWS sweep" (or "quick sweep of CloudWatch/ECS", "check
if anything's restarting/crashing"). Follow this same sequence every time, don't
improvise a different one.

**Scope by default to the environment named** (usually `qa`, tied to a specific ticket/
testing cycle) — don't sweep all three environments unless asked. Covers ECS health,
CloudWatch logs, CloudWatch Alarms, and the cacheupdate Step Functions pipeline; NOT
Lambda-wide error metrics, billing, security groups, or IAM unless the user asks for
those specifically.

## Steps, in order

1. **Inventory services**: `aws ecs list-services --cluster <env>-v1-AMA --max-items 200`.
   Note which are dormant (`desiredCount=0` — expected, e.g. `exporterplus-api`, see
   [AWS-REFERENCE.md](AWS-REFERENCE.md)) vs. live.
2. **Recently stopped tasks**: `aws ecs list-tasks --cluster <env>-v1-AMA --desired-status STOPPED`.
   QA log/task retention is short (~1h) — a non-empty list here is already suspicious.
3. **Service health**: `aws ecs describe-services` (batch all live services), check
   `runningCount != desiredCount`, `pendingCount > 0`, or `rolloutState != COMPLETED` on
   any of them.
4. **Running task age — the real anti-crash-loop signal, not just running==desired**:
   `aws ecs list-tasks --desired-status RUNNING` + `describe-tasks` for `startedAt`. A
   task restarting every few minutes shows a `startedAt` only minutes old even though
   `running==desired` looks healthy in step 3 — check age explicitly, don't stop at step 3.
5. **Service event history**: `describe-services` again, look at `.events[:4]`. A single
   `started → registered → steady state` sequence = one clean deploy. Repeated start/stop
   pairs = an actual loop.
5a. **Cross-check the running image tag against Octopus's deployed release — a healthy
    old task can hide a crash-looping new one.** E.g. `reports` was steady and
    responding throughout, but on the OLD version (`203`) — the new build (`204`) never
    went healthy, so ECS just kept serving the old task indefinitely. This
    doesn't always show up as a "young `startedAt`" per step 4, since the long-serving
    OLD task is what's actually running — check `rolloutState`/`PRIMARY` vs `ACTIVE` task
    defs in `describe-services`, and compare the running image tag to what
    [[ama-octopus-deploy]] says was deployed, not just whether the service looks steady.
6. **CloudWatch log sweep**: run [cloudwatch-search-logs.sh](scripts/cloudwatch-search-logs.sh)
   per live service's log group, last 24h, filter pattern:
   `?Unhandled ?FATAL ?ld.so ?OutOfMemory ?Segmentation ?panic ?terminated ?CrashLoop`.
   Narrow further on any hits.
7. **CloudWatch Alarms in ALARM state**: `aws cloudwatch describe-alarms --state-value ALARM`.
   Cheap, single call — catches anything already instrumented with a real metric-based
   alarm (see [GRAYLOG-REFERENCE.md](GRAYLOG-REFERENCE.md) for the known production
   paging stream) that an ad hoc log-pattern grep could miss entirely.
8. **Step Functions failed executions** (cacheupdate pipeline — invisible to steps 1-7,
   those are ECS-only): `query-cacheupdate-stepfunction.sh <environment> <approx-time>`
   (from [[ama-graylog-search]]), or `list-executions --status-filter FAILED` directly against
   `<environment>-v1-cacheupdate-statemachine`. **Before reporting a failed execution as a
   finding, check it's not already fixed**:
   - Only count executions recent enough to plausibly still be broken — a failure from
     before the day's most recent deploy to that environment isn't current state.
   - Cross-check against recently-worked-on tickets (search Jira for tickets touching
     `cacheupdate-infrastructure`/`cacheupdatecoordinator`/`selenium-crawlers` updated in
     the last day or two) — if a matching root cause was already fixed and deployed, don't
     re-report it as a live problem; note it as "already addressed by PROJ-XXXXX"
     instead.

## What's a real finding vs. known noise

- Real finding: young `startedAt` on a service that's supposedly steady, repeated
  start/stop events, or a CloudWatch hit that recurs across multiple timestamps.
- NOT a finding: the recurring `ld.so ... libodbcinst.so.1 ... cannot be preloaded ...
  ignored` stderr line (search/querybuilder, pre-existing cosmetic noise) — see
  [[ama-graylog-search]]'s note on the same repos if it shows up there too.
- A single, non-recurring app-level error (e.g. one `HttpIOException: response ended
  prematurely`) is transient, not a crash cause — check for recurrence before flagging.
- A failed Step Functions execution that's older than the environment's last relevant
  deploy, or that matches a ticket already resolved/deployed, is NOT a current finding —
  note it as already addressed, don't re-report it as live.

## Report format

A short verdict, not a raw dump: one bolded one-line conclusion up top, then evidence
grouped by "Restart loops", "CloudWatch sweep", "Alarms", and "Step Functions" sections
(omit a section if there's nothing to say, don't force all four), non-actionable items
called out explicitly (don't silently omit them), and a closing line tying back to
whatever ticket/question prompted the sweep.
