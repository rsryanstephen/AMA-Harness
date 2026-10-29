# AWS sweep — checking for restart loops / crash noise across a fleet environment

Trigger phrase: user asks for an "AWS sweep" (or "quick sweep of CloudWatch/ECS", "check
if anything's restarting/crashing"). Follow this same sequence every time, don't
improvise a different one.

**Scope by default to the environment named** (usually `qa`, tied to a specific ticket/
testing cycle) — don't sweep all three environments unless asked. Covers ECS health,
CloudWatch logs, CloudWatch Alarms, and the cacheupdate Step Functions pipeline; NOT
Lambda-wide error metrics, billing, security groups, or IAM unless the user asks for
those specifically.

## The sweep

```bash
bash ~/.claude/skills/ama-cloudwatch-search/scripts/aws-sweep.sh <env> [--hours N]
```
Runs the fixed sequence and prints evidence per section: 1 services (live vs dormant),
2 recently-stopped tasks, 3 service health, 4 **running task age** (a task restarting every
few minutes shows a young `startedAt` while `running==desired` looks healthy — the real
anti-crash-loop signal), 5 service events, 6 CloudWatch crash-class log sweep per live
service (known noise segregated by `cloudwatch-search-logs.sh`), 7 alarms in ALARM,
8 cache-update Step Functions FAILED executions in the window.

Two judgements the script leaves to you, with the inputs printed:

- **5a. Running image vs Octopus's deployed release — a healthy OLD task can hide a
  crash-looping NEW one.** `reports` once served build `203` steady throughout while `204`
  never went healthy. `resolve-aws-names.sh <env> <repo>` prints registered vs running image;
  `verify-octopus-env-deploys.sh` says what Octopus thinks it shipped.
- **8. Is that failed execution already fixed?** Only count executions newer than the
  environment's last relevant deploy, and cross-check tickets touching
  `cacheupdate-infrastructure`/`cacheupdatecoordinator`/`selenium-crawlers` in the last day
  or two — a fixed-and-deployed root cause is "already addressed by PROJ-XXXXX", not a
  live finding.

## What's a real finding vs. known noise

- Real finding: young `startedAt` on a service that's supposedly steady, repeated
  start/stop events, or a CloudWatch hit that recurs across multiple timestamps.
- NOT a finding: anything `cloudwatch-search-logs.sh` reports under
  `known_noise_suppressed` (the `libodbcinst.so.1 ... cannot be preloaded` ld.so line on
  search/querybuilder). New cosmetic noise goes into that script's `NOISE` pattern, not here.
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
