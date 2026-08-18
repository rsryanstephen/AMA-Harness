---
name: ama-cloudwatch-search
description: Search AWS CloudWatch Logs for AMA_APP ECS/Lambda repos. Use when Graylog has no relevant logs, when CloudWatch/ECS/Lambda logs are mentioned directly, investigating infra-level failures (container crash, task provisioning, missing env vars), an "AWS sweep" / "quick sweep of CloudWatch/ECS", or verifying a deploy landed clean on AWS.
---

# CloudWatch log search

Why this exists, not just [[ama-graylog-search]]: **infra-level failures never reach Graylog** — a crash before/outside the app's own logging pipeline (container startup error, missing env var, `ld.so`/`LD_PRELOAD` failure, ECS task provisioning failure, Lambda cold-start/timeout/OOM) has nowhere to log TO in Graylog. E.g. `qa-v1-ama-search`'s own container logs an `ld.so: object '...libodbcinst.so.1'... cannot be preloaded` line that never reaches Graylog at all — it's stderr from the container runtime, before the .NET app's logger even starts.

Account: `000000000000`, region `us-east-1` (this machine's default AWS CLI profile already has the needed IAM permissions, no extra setup). Mirrored as `aws.accountNumber`/`aws.region` in `~/.claude/harness-config.json` — swap both for a different adopter.

## Critical gotchas: `MSYS_NO_PATHCONV=1` and `PYTHONUTF8=1`

**Every command below MUST run with `MSYS_NO_PATHCONV=1`** — every CloudWatch log group
name starts with `/` (e.g. `/aws/ecs/qa-v1-ama-search`) and git-bash mangles it before
`aws.exe` sees it. Both scripts below already set this internally; a direct `aws logs ...`
needs it yourself. Why/pipeline scoping rules: see [[bash-command-style]]'s native-exe
section — applies to `jq` too.

**`PYTHONUTF8=1` on every `aws logs` call** — aws-cli crashes on non-ASCII log content
otherwise (`PYTHONIOENCODING=utf-8` alone does NOT fix this, confirmed).

## Log group naming

- **ECS services** (most AMA_APP repos): `/aws/ecs/<environment>-v1-ama-<repo>` — clean, consistent. Confirmed for admin, cacheupdate, cohortreports, cohortreportsexport, cohorts, cohortsearch, export, exporterplus, feedback, fieldtablemapper, manage, notifications, organisationexports, pricing, querybuilder, rabbitmq, reports, resultsprocessor, search, and more. (`cacheupdatecoordinator` still shows up in AWS but is decommissioned — see [AWS-REFERENCE.md](AWS-REFERENCE.md), ignore it.)
- **Lambdas**: no reliable pattern — ad hoc per function (e.g. `production-v1-cacheclear-lambda`, `production-v1-search-cacheupdate`, `qa-v1-cohort-search`). Don't guess — search by keyword:
  ```bash
  bash ~/.claude/skills/ama-cloudwatch-search/scripts/cloudwatch-find-log-group.sh <keyword>
  ```
  Prints `<log-group-name>\t<retention-days-or-"never expire">` for every match, ECS and Lambda both.

## Retention varies — check before assuming a time range is available

**qa ECS log groups retain only 1 day**; **production ECS retains 5 days**; Lambda retention is per-function and inconsistent (seen: 1, 5, 30, never-expire). A "check what happened last week in qa" ask may simply have nothing left to find — check retention first (the find-log-group script prints it) and say so explicitly rather than reporting a clean empty result as "no errors happened."

## Searching

```bash
bash ~/.claude/skills/ama-cloudwatch-search/scripts/cloudwatch-search-logs.sh "<log-group-name>" "<since>" "<until>" "<filter-pattern-or-empty>" <limit>
```
- `<since>`/`<until>`: anything `date -d` accepts (`"2026-07-21T08:00:00Z"`, `"1 hour ago"`, `"now"`).
- `<filter-pattern-or-empty>`: **CloudWatch Logs filter pattern syntax, NOT Lucene** — plain substring (`"Exception"`), OR-style (`"?ERROR ?Exception"`), or `""` for everything in the window. Don't reuse a Graylog Lucene query here, it's a different syntax.
- Prints a console link to the log group (`.../cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group/<url-encoded-name>`) plus each matching line with a human-readable UTC timestamp.

## User asks for an "AWS sweep" — follow the same checklist every time

Don't improvise a fresh process each time. See [AWS-SWEEP.md](AWS-SWEEP.md) for the exact
step order (service inventory → stopped tasks → service health → running-task age →
event history → CloudWatch log scan), what counts as a real finding vs. known noise, and
the expected report format.

## After a push to develop — verify the QA deployment landed clean

Offer this after pushing an ECS-backed API-service repo to `develop` (excludes `admin`/
`exporterplus` — S3-hosted, no runtime to check). **Always offer, never run unprompted**
— it takes 12-15 minutes (longer for `search`), wait for an explicit yes/no first. See
[DEPLOY-VERIFICATION.md](DEPLOY-VERIFICATION.md) for scope, the script, and what counts
as a real error vs. routine deploy noise.

## Beyond just logs — ECS task/service state, and a systemic Step Functions gap

**Read [AWS-REFERENCE.md](AWS-REFERENCE.md) before concluding "nothing to find here.**" Covers: why
ECS log-group/service-name/task-definition-family naming does NOT match across those three surfaces
(easy to get wrong); how to check why an ECS task actually stopped (`stoppedReason`,
container `exitCode`) when it crashed before logging anything at all; ECS service deployment/scaling
event history; and a real gap — zero `Retry` configuration anywhere in the cacheupdate
state machine, fleet-wide, plus exactly where its Terraform source lives if that's ever worth fixing.

## When to reach for this vs. Graylog

1. Default to [[ama-graylog-search]] first — it's the app-level source of truth for most errors.
2. Graylog shows nothing for a suspected time window, OR the user explicitly asks about CloudWatch/ECS/Lambda/container/infra-level behavior → come here.
3. Same correlation rules as Graylog apply (see that skill's rules 8/9) — a burst of CloudWatch errors within ~0.5-3s of each other is one incident, not many.

## Do NOT

- Run any `aws logs ...` command without `MSYS_NO_PATHCONV=1` — it silently corrupts the log group name argument otherwise.
- Guess a Lambda's log group name from its repo name — naming isn't consistent, always search by keyword.
- Report an empty CloudWatch result as "no errors" without checking retention first — it may just mean the logs already expired.
- Use Lucene query syntax in `--filter-pattern` — CloudWatch's filter pattern syntax is different.
