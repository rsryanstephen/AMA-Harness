---
name: ama-appinsights-query
description: Query Azure Application Insights (KQL) for AMA_APP services -- custom metrics like search-api's GC.TotalMemory / GC.TotalCommittedBytes / Process.WorkingSet64, requests, exceptions. Use when memory/heap history, "App Insights", "Application Insights", or a per-task metric timeline is needed that Graylog and CloudWatch don't hold.
---

# Application Insights query

One component per env (`<component name>|staging|prod`, all in the `Pay-As-You-Go` subscription),
appIds in `harness-config.json` `.azure.appInsights.<env>.appId`. Not secret -- appId is an
identifier, auth is separate.

```bash
bash ~/.claude/skills/ama-appinsights-query/scripts/ai-query.sh production query.kql
```
KQL from a FILE, never a command-line arg (same rule as every other API skill here). TSV out.

## Auth -- two paths, script picks automatically

1. **Default: `az` login.** `az login --use-device-code` once (user runs it via `! az login
   --use-device-code`; account needs Reader on the component). Refresh token lives ~90 days
   of use -> re-login rarely. Script calls `az account get-access-token --resource
   https://api.applicationinsights.io` each run; token never on the command line.
2. **`APPINSIGHTS_API_KEY` set -> used instead** (`x-api-key` header). Headless/cron path.
   Make: portal -> component -> *API Access* -> Create key, *Read telemetry* only. Env var only,
   never in config/chat.

## Gotcha

`az monitor app-insights query` (extension `application-insights` 1.2.0) dies on CLI 2.74:
`Profile.get_login_credentials() got an unexpected keyword argument 'resource'`. Don't debug
it -- REST endpoint `https://api.applicationinsights.io/v1/apps/<appId>/query` is what the
script uses. `az monitor app-insights component show` also returns empty fields; use
`az resource show --resource-type microsoft.insights/components --query properties.AppId`.

## search-api memory metrics (what's there)

`customMetrics` names `GC.TotalMemory` (live heap MB), `GC.TotalCommittedBytes` (committed
MB), `Process.WorkingSet64` (MB), every 30 s per task, `cloud_RoleInstance` = task host. Only
where `MemoryMonitor__Enabled=true` (staging, production). Recipe:

```kql
customMetrics
| where timestamp between (datetime(<from>) .. datetime(<to>))
| where name in ("GC.TotalMemory","GC.TotalCommittedBytes","Process.WorkingSet64")
| summarize mx=max(valueMax) by bin(timestamp, 30m), name, inst=tostring(cloud_RoleInstance)
| evaluate pivot(name, max(mx))
| order by inst asc, timestamp asc
```
Read: committed >> live for hours = GC holding freed segments (retention), not live data.
Live ~= committed ~= 12 GB = a real oversized result set (see `ama-architecture-notes`'
`SEARCH-SQL-PIPELINE.md` cap note). Same line goes to Graylog at Information ("Memory Metrics") ->
visible on Staging/QA (Debug) only; production history = App Insights. The sustained-pressure
Error (60% of GC hard limit, 10 min) does reach production Graylog.
