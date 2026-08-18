# Async messaging patterns and smaller libraries

## Three distinct async messaging patterns coexist — not one convention

- **MassTransit typed consumers**: `exportproducer-messages` (`ExportMessage`,
  `ExportStatusMessage` — plain marker interfaces, no envelope/discriminator), consumed
  via `IConsumer<ExportMessage>` in `exportproducer`. MassTransit handles serialization.
- **Raw SQS + hand-rolled envelope**: `cohortcontracts` messages (`GenerateCohortDataMessage`,
  `DeleteCohortDataMessage`) implement an empty marker `IMessage`, tagged with a
  `MessageType` enum discriminator. Pushed via `cohortreports`'s `Publishers/SQSPublisher.cs`
  (raw `IAmazonSQS`), consumed in `cohortdata`. Same low-level style as the cacheupdate
  pipeline's `<env>-v1-cacheupdate-state` SQS calls.
- **Synchronous HTTP disguised as a "client"**: `notifications-client`'s
  `NotificationClient.Notify()` is a plain blocking `POST {NotificationServiceUrl}/notification`
  — no queue involved despite the name suggesting async pub/sub.

`webhooks` is generic ops-alerting (Slack/Teams-style incident alert via named alias URL,
`WebhookSettings.Aliases`), consumed widely (`cacheupdate-infrastructure`, `export`,
`fieldtablemapper`, `reports`, `search`) — a SEPARATE channel from the SQS status queue,
used for failure alerting specifically, not general messaging.

## featureflags — real Flagsmith, fail-open to caller's default

Wraps the `Flagsmith` NuGet package (real hosted/self-hosted service, not a homegrown DB
flag table). `FeatureFlags.GetValueAsync<T>` returns the caller-supplied `defaultValue`
and just logs an error (never throws) if flags are disabled on the environment, not
found, or not enabled. Any flag check must supply a sane default — misconfiguration
silently falls back, never blocks.

## cohortcontracts

Shared DTO/message contract library, depended on only by `cohortdata` and `cohortreports`
(not search/export/reports) — single source of truth for the generate/delete/failed
cohort-data message shapes shared between those two services specifically.

## `*-client` libraries — consistent pattern, no shared base class, no retry policy

`reportclient` and `notifications-client` both just inject `IHttpClientWrapper` (from
`shared-http`) + `ISiteConfigurationReader` for the base URL — no shared abstract base
client class. **No Polly anywhere in the fleet** — retry isn't handled at this layer.
Timeout is a raw `int` overload on `IHttpClientWrapper` (fresh client per call via
factory), not a policy wrapper.

**`fieldtablemapper-client` is an empty stub** — zero `.cs` source files besides
`.csproj`/AssemblyInfo, no reference to `shared-http`. A FieldTableMapper client does not
actually exist yet despite the repo existing — don't assume it's implemented.

## Quick facts

- `caching`: Redis-backed, chunking + compression for large payloads, in-memory fallback.
- `search-cache`: bigger than its name implies — bundles a whole SQL/aggregation
  query-builder framework (30+ builder classes) alongside cache-key generation.
- `shared-http`: also carries HMAC client-auth config and correlation-ID propagation
  middleware, not just an `HttpClient` wrapper.
