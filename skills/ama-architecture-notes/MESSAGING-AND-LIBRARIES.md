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

## Decommissioned features still wired in code — grep says live, they are not

Two client-facing features are switched off operationally (user, Aug 2026) but **fully
present in source**. Neither has a feature flag, a removal commit, or an `[Obsolete]`.
Deliberately retained — may be recommissioned, so **don't propose deleting them**.

### AMA blog (Craft CMS)

`POST /notification/blog` (`notifications/.../Controllers/UserNotificationController.cs:67-98`),
`BlogNotificationService`, `BlogNotificationMessageBuilder`, `BlogSecurityCheckService`,
`BlogData`/`BlogAuthorDetail`/`CraftDateTime`/`BlogNotificationTypes`; exporterplus's
`NotificationBlogChangeBuilder` + 4 `NotificationType` members; `AppBlogDomain`/`DNS`/`Url`
still templated (`_build/infrastructure/api_container_definitions.json`, every `appsettings.*`).

- **`BlogBroadcastNewEntry` writes a notification to EVERY user** — the route is the fleet's
  only unauthenticated broadcast. No `[Authorize]`; sole gate is `VerifyWebhookOrigin`, an
  `Origin`-header `Contains(AppBlogDomain)` check. Caller-supplied header, substring
  match. Empty env var ⇒ `Contains("")` is true ⇒ open to anything. (Unset ⇒ `Contains(null)`
  throws ⇒ fails closed.)
- **NOT fail-open in practice — resolved 2026-08-20, don't re-raise it as urgent.**
  `yourproduct-blog-domain` is populated in EVERY environment scope on `Projects-77`
  (`YourProduct_Exporter_Notifications_API_ECS`): Prod/`<production>`
  `http://yourproduct-blog.hs-exporter`, QA+Staging `http://yourproduct-blog.hs-<component name>`, Dev
  `ip-173-31-61-169.ec2.internal`. Live production task def agrees. So the `Contains("")` path
  is unreachable today; the guard on PROJ-15330 is defence-in-depth, not a live hole.
  A code-only read makes this look urgent — it isn't. Re-check the variable, don't re-derive
  from source (see [[self-check-before-asking]]).
- Still true and unfixed: `Origin` is caller-supplied and `Contains` is a substring test, so
  the check is not authentication even when the variable is set. Whoever recommissions the blog
  replaces it rather than trusting it.
- This is NOT the client-notice channel. That's the admin portal — see
  [[ama-client-facing-notifications]].

### AMA Socialising

**No backend service and no DB table** — S3-backed. exporterplus writes definition + data +
image to `{env}-v1-social-export` under `SocialExport/`, a public static site
(`social.example-app.com`, **no repo in this fleet**) renders it, and admin's
Socialising page is direct AWS-SDK-in-browser CRUD over that bucket
(`admin/src/app/socialising/`, plus `admin/src/app/services/s3/*` which only it consumes).

- Only backend involvement is the **shared** export pipeline carrying `ExportType = Social`
  as a special case: `export/.../ExportStatusService.cs:69-80`,
  `exportproducer/.../SocialExportJobPipeline.cs`, `SocialExportNotificationService.cs`,
  `FileUploadJob.cs:56-57`, and `resultsprocessor/.../ExportStatusFacade.cs:27,60`.
- **Social deliberately SKIPS export-status tracking** in all three of those guards. Removing
  a guard changes live Search-export control flow — mark the branch, never the file.
- Current gating is code-level, not flag-level: the exporterplus trigger button is
  **commented out** (`report-actions.component.html:97-108` — commit `cf8ee873a` "Remove
  social share" was only that comment-out), `hideSocialExport = true` default, plus the
  `SocialShareCreator` role. **The admin nav entry is NOT gated and is still visible to
  Admins** (`admin/src/app/app.component.html:49-53`).
- `yourproduct-backbone/Applications/AMA/Social/*.tf` is entirely commented out, but
  `_build/build.sh` still builds/publishes the package, and `ui-testing`'s `SocialFixture`
  steps still run in the QA and Staging pipelines.
- `exportproducer/README.md:63` already says "Search / Social Exports (Decommissioned)" — the
  one pre-existing written signal.
- **Report Sharing is a different, LIVE feature** (`hideShare`/`share`, "Share Report"). Don't
  conflate it with `socialShare`/`hideSocialExport`.
- **No admin entry as of PROJ-15330 (2026-08-20)**: the nav `<li>`
  (`app.component.html`) and BOTH routes (`app-routing.module.ts`) are commented out, code
  intact. The routes were scoped `[Admin, UserManagement]` — WIDER than the Admin-only nav — so
  hiding the link alone would have left `/socialising` reachable by direct URL for a
  UserManagement user. Keep both commented together if this is ever touched.

## `"UserNotification"` has no useful index — measured, not inferred

Live production, 2026-08-20: 225,487 rows / 134 MB, and only two indexes — the `"Id"` primary
key, and `idx_user_report_report_report_type`, a **dead** expression index on
`("Notification"->'NotificationType')`. Dead because it is PascalCase while every writer
serialises camelCase (`Startup.cs` `CamelCaseNamingStrategy`, `FieldNames.cs`, and the admin
portal posting camelCase directly), so it matches no stored key.

Nothing in the repo filters on `notificationType` anyway — `CountNotificationsRequestBuilder`
and `UserNotificationListPageRequestBuilder` filter `"UserId"`, range on `"Created"`, and read
`->>'read'`. So **there is no index on `"UserId"`**, and the notifications-panel query runs a
parallel seq scan (44 ms, ~15k shared buffers for one user). Correcting the dead index's case
would build something still nothing queries; the useful index is `("UserId", "Created" desc)`.
Addressed on PROJ-15330.
