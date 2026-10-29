# Known error signatures — recognize, don't re-diagnose

Confirmed real signatures this harness has already investigated to the root cause.
Recognizing one of these on sight saves the tokens of re-diagnosing from scratch.

**Tagged-in-Graylog signatures are no longer listed here.** `graylog-search.sh`
segregates any `level:3` sweep on the server-side `known_issue` field automatically and
reports the suppressed count and tags (4814 of 4895 error messages carried one over the 7
days to 2026-09-15) -- except the non-prod catch-all `Suppress non prod alerts`, which is NOT
a known issue and is returned separately as `catchall_tagged` with a `warning`: it covers ~95%
of Staging errors, and folding it in hid 9h of RabbitMQ `BrokerUnreachableException` /
"None of the specified endpoints were reachable" on the Staging export APIs after a backbone
apply swapped the broker NLB security group (PROJ-15801, 2026-10-14; `aws-sweep.sh`
now greps for that signature too). Cancellation exceptions and the exportproducer Hangfire
`PostgreSqlObjectsInstaller` burst were dropped from this file for that reason — the field
is maintained by the team, never goes stale and costs no context. What stays here is what a
tag CANNOT say: which noise hides a real finding, and what to do about it.

## 1. Stale cache (not a bug) — STOP diagnosing on sight

`environment:qa` hit with `Message` starting `System Exception : Could not find table
mapping for field f` (any field name) → known, expected cache-staleness condition, full
stop. Remind the user to update the cache: `https://<app.domains.adminQa from harness-config.json>/update`.

Do NOT: dig into which field/column/schema it is, propose root-cause options, ask
whether to investigate further, or file a ticket for it on its own. Recognizing the
signature IS the answer — nothing past it is worth the tokens.

## 2. Historic Npgsql/Shared DI regression — check the version before treating as new

Signature: `System Exception` failing to activate along the chain
`...Shared.Services.AggregationMetadata.MetadataFacade` → `AggregationDatabaseMetadataService`
→ `AggregationDatabaseRepository` → `ConnectionManager` (or the equivalent
`PossibleValueServiceFactory` → `IPossibleValueService` chain). Surfaces as repeated
500s on `search-api`'s `/search/metadata` and `/search/aggregation-db/field/...`
endpoints, often bursting across `reports-api`/`querybuilder-api`/`fieldtablemapper-api`
**simultaneously** — NOT because one calls the other (rules 8/9's causal-burst pattern
doesn't apply here), but because all of them independently reference the same broken
`YourCompany.Product.Shared` version. Don't triage these as N separate app bugs.

**Root cause (already fixed)**: `product-service-shared` commit `cddff8c1` moved
connection-string validation from lazy to eager (`NpgsqlDataSourceBuilder(...).Build()`
in the constructor instead of at first use) — any consumer with an unconfigured
connection type registered via Autofac's `RegisterAssemblyTypes` crashes on DI
activation, even if that connection type is never actually used. Fixed in
`YourCompany.Product.Shared` version **46.3.5.68** (all consumers were on `46.3.5.66`
before the fix).

**Before treating a new hit of this signature as a fresh investigation**: check whether
the affected repo already references `YourCompany.Product.Shared >= 46.3.5.68`
(`grep -A2 'PackageReference Include="YourCompany.Product.Shared"' <repo>/**/*.csproj`).
Already on 46.3.5.68+ → this is a **different, new** issue that coincidentally matches
the same crash shape, investigate fresh. Still below it → this is very likely the same
already-fixed regression, just not yet propagated to this repo — check
[[ama-library-version-sync]]'s cascade status rather than re-diagnosing.

## 3. `api-testing` negative-test noise — expected, not a real error

Local folder `api-testing` (Bitbucket: `<repository>-api-testing`, see the `testing.md`
classification). QA logs during/after its pipeline run include errors
deliberately triggered by negative-test cases, not real bugs. Recognize by message
substring, don't re-diagnose:
- `search-api`: `Invalid curve request` (CurveAnalyser sending bad ranges on purpose)
- `querybuilder-api`: `DynamicColumn` null Name/Description not-null constraint (create-with-null test expecting DB rejection)
- `reports-api`: `... was not found` paired with `DELETE ... responded 500` (delete-negative-scenario test) -- same signature also lands as a support-notification mail, see [[<amaSupportChannelName>-notices]]'s "Known no-action patterns". Suppressed on the L1 alert stream by pipeline rule `63034ec5883d0a4395b3f37f` ("Filter out Test Automation on AMA", `.graylog.suppressPipelineId` stage 0) -- GUID-shape matched (`regex`), not a pinned literal, after the pinned-GUID version went stale the same day it was written (tests mint a fresh GUID per run). If this signature reaches the support mailbox again, the suppression rule itself is what broke -- check it (see [PIPELINE-RULES.md](PIPELINE-RULES.md)) before re-diagnosing the app.
- Every service: `Test of ERROR logging from YourCompany.Product.<X>` — a deliberate per-service probe, not an error at all. **This one cuts both ways**: ignore it as a "finding," but also confirm it actually fired for all 9 confirmed services during a test run — `Search`, `Manage`, `FieldTableMapper`, `Reports`, `Notifications`, `QueryBuilder`, `Export`, `CohortReports`, `Feedback`. A **missing** probe for one of these isn't noise to ignore — it means that service's error-logging pipeline may be broken, or the test run didn't actually exercise it; flag it rather than silently passing over the absence.
- NOT related to tests, but often appears alongside them: `exportproducer`'s `LineJoiner.SortColumns` mismatch warning — a known recurring warning, export still succeeds.
- `search-api`: `Cache Manager -> Exception thrown while obtaining value to be cached for cache key CURVE__` — same negative-test cluster as `Invalid curve request` above (bad curve data deliberately submitted), not a separate issue.

See [[ama-architecture-notes]]'s `TESTING-REPOS.md` for the fuller picture — this list of
5 patterns is a subset; confirmed present in 10 of ~14 test fixtures, with more
negative-scenario variants than listed here.

A genuine `api-testing`-triggered failure looks different from these — same shape,
but with a status code/assertion that doesn't match what the negative test expects.

**Omit entirely from any sweep report — don't mention it even as a labeled aside.**
Recognizing it as known noise means treating it as if it doesn't exist in the output,
not surfacing it with a label attached.

## 5. Non-AMA Spark noise on production — exclude the transport-level noise, but investigate if an AMA object is named

This Graylog instance is shared with at least one unrelated Spark-based system (see the
non-AMA `application` values already noted in [APP-NAME-MAPPING.md](APP-NAME-MAPPING.md):
`collateral-build`, `orchestrator-engine`, `dynamic-cohorts-build`, etc.), which is the
AMA_ETL system (`~/Repos/AMA_ETL`, see [[ama-architecture-notes]]'s
`FLEET-CONVENTIONS.md`) — a real, investigable codebase, not a foreign black box.
Pure transport-level noise still excludes regardless of query:
- `org.apache.spark.network.client.TransportResponseHandler`
- `org.apache.spark.network.client.TransportClient$StdChannelListener`
- `org.apache.spark.internal.Logging`

**But an error naming an actual AMA object (e.g. `Failed to parse Dynamic Column
dc__<guid> to Spark Column`) is a real cross-system issue, not noise — investigate it,
don't stop at "flagging only".** `~/Repos/AMA_ETL`'s
repos (e.g. `yourproduct-spark-jobs`) are real git repos, pullable from Bitbucket —
investigate them the same as any AMA_APP repo, don't treat "it's ETL" as a reason to
stop.

**Prefer fixing it on the AMA_APP side if at all possible**, even though the error
surfaces on the ETL/Spark side — only fix in AMA_ETL if the app side genuinely can't
address it. If an ETL-side fix is the only option: branch, commit, push, then **raise a
PR against `develop` with Reviewer One and Reviewer Two as reviewers** (don't merge directly) — their
Bitbucket UUIDs are cached in `harness-config.json`'s `bitbucket.etlFixReviewers`.

## 6. `Cache miss for query` (search-api, pre-Aug-2026 builds) — config skip, not a Redis miss

`search-api` Info line `Cache miss for query` / `Cache miss for row count` meant
**caching was SKIPPED by config/rule** (`EnableSearchCaching` false or a caching rule
said no), never a real Redis lookup miss. Misread live once (PROJ-14945 regression
hunt). Reworded 2026-08-13 (search commit 792e4e95) to `...caching skipped by
config/rule -- executing uncached` — the old text only appears in logs from builds
before that. Real Redis misses log `Cache miss for <key>` with an actual key name
(caching library), e.g. `Cache miss for SEARCH_...`.

## 7. `System.OutOfMemoryException` / Npgsql `Exception while reading from stream` in `ExecuteRawQuery` (search-api) — unbounded result set

Stack at `AggregationDatabaseSearchExecutor.ExecuteRawQuery` (`List..ctor` ← Dapper ← Npgsql
`GetString`) = the whole Redshift result was materialised. Same root shows as OOM on prod (16 GB
task) and as the Npgsql stream error after ~5 min on staging (8 GB). Triage in this order: the
`ExecuteAsync::SQL` line 1-2 s earlier — read its **tail** for a `LIMIT` (none ⇒ the limit-gate
class fixed in Search.Shared 19.1.3 / PROJ-15349, check the deployed version first); the
`System Exception … Request Body:` line carries the complete JSON body for a Staging replay. A
memory graph peaking at ~70-77 % is the `DOTNET_GCHeapHardLimitPercent=70` cap, not "didn't run
out" — see `ama-architecture-notes`' `SEARCH-SQL-PIPELINE.md`. From Search.Shared 19.2.0 the same
class surfaces instead as `ResultSetTooLargeException` ("exceeded the configured MaxMaterialisedRows
limit of 100000") — a clean 500 on one request, memory flat; treat it as "this SQL has no LIMIT",
not as "raise the limit". search-api's `MemoryMetricsLogger` lines are Information-level, so they
never reach Graylog on Production — an instance of the fleet-wide Info/Debug gap, see
[GRAYLOG-REFERENCE.md](GRAYLOG-REFERENCE.md)'s Production-logs-at-`Warning` section. Its numbers
are App Insights custom metrics `GC.TotalMemory` / `GC.TotalCommittedBytes` /
`Process.WorkingSet64`.

## 8. Redis outage/failover — messages never contain the word `Redis`

Search `"ConnectionMultiplexer"` OR `"cannot be issued to a replica"` OR `"CACHE MANAGER"`, not
`Redis`/`StackExchange`/`RedisConnectionException` — those match zero. Failover signature: writes
fail `Command cannot be issued to a replica: UNLINK ...` (cache-update steps die → Step Function
FAILED, `ProcessRunning` stuck at 1, see CACHE-UPDATE-DEBUGGING.md), then every API logs
`CACHE MANAGER - ConnectionMultiplexer ConnectionFailed (Pool N)` in one sub-second burst on
reconnect. Any ElastiCache patch/failover pass check: run that query + cache-update execution list
over the window — `ama-cloudwatch-search/scripts/elasticache-update-watch.sh` does both. **Add
`environment:<env>`**: QA/Staging reconnect too (07:00 SAST wake), unscoped prod count read 129, real 71.
2026-10-21: PROJ-15831 prod patch closed "no Redis errors" on a `Redis` query while 70
reconnects + 1 replica-write error + a failed cache update sat in the window.

## 9. QA/Staging wake-window start-up errors — wake order, not a bug

~05:00-06:30Z Mon-Fri (07:00 SAST env-sleep wake) or right after manual `scale-env.sh <env> 1`:
resultsprocessor `PersistentChannel timed out` (crash-loops till RabbitMQ up); reports
`Failed to migrate the database` after `Name or service not known (product-service-fieldtablemapper...)`.
Production or outside that window → real, investigate. Prevention + next step if seen again:
`ama-env-sleep` SKILL.md Gotchas (`wake-first.txt`, 2026-10-22).
