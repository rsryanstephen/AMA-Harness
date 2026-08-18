# Core libraries: shared, common-*

## shared (YourCompany.Product.Shared)

Ships a legacy logging facade: `LogExtensions.WriteDebug/WriteInfo/WriteError`
(`Extensions/LogExtensions.cs`) extend `Common.Logging.ILog` (log4net-style API), NOT
Serilog's `ILogger` directly. See `common-logging` below for how this actually gets
routed. See [[ama-debugging-notes]]'s `DI-EAGER-CONSTRUCTION.md` for the eager
connection-type-construction regression.

**It's a grab-bag by known, stalled plan, not by accident.** A 2021 Confluence page
("Better Bounded Contexts") proposed splitting `shared`'s unrelated concerns into their
own packages — several items on that list genuinely did get extracted over the years
(config → `common-configuration`, Swagger → `common-swagger`, FieldTableMapper/QueryBuilder
→ their own services). But confirmed still living inside `shared` today, un-extracted:
`FieldTableMapper/` + `FieldTableMapperClient/`, `DynamicColumnClient/`,
`Configuration/Readers/`, `Metadata/` (aggregation metadata), `Builders/SqlTemplate/`, and
`Enum/ExportStatusIndicator.cs`. If asked to reduce `shared`'s bloat, this is the existing,
already-agreed-on list to start from — no need to re-derive candidates from scratch.

## DynamicColumnClient / custom bands

`DynamicColumnClient/` (in `shared`, see above) calls the `querybuilder` service --
that's the one custom-band/dynamic-column errors surface against (Graylog `application`
`product-service-querybuilder-api`). But confirmed 2026-07-31: the data itself lives
in the **export API's** Postgres DB, not querybuilder's own -- querybuilder reads
another service's database directly. Genuine architecture quirk, not a documentation
gap -- don't assume querybuilder owns its own data just because it serves the errors.
See `ama-report-debug` and `ama-postgres-access` for the resolve-connection procedure.

## common-configuration

`SiteConfigurationReader` is a flat passthrough over `IOptions<SiteSettings>`, bound from
config section `nameof(SiteSettings)`. **Gotcha**: the section name is literally the class
name — rename the class and config binding breaks silently (falls back to property
defaults, no error, no exception).

## common-cqrs

NOT dependency-free from `auth` — `UserService.cs` and `ICommand`/`IQuery` pull
`IAuthService`/`AuthenticatedUser` straight from `YourCompany.Product.Auth.Security`. Any
consumer transitively needs `auth` registered, or `CommandInterceptor`/`QueryInterceptor`
DI resolution fails at startup.

`CommandInterceptor<T>`/`QueryInterceptor<T>` are MediatR `IPipelineBehavior`s: populate
`request.User` from `IUserService.GetUser()` before the handler runs, then after the
handler returns, iterate `response.Events` and publish each via `IMediator.Publish`. **If
the interceptor pipeline isn't registered in a consumer's MediatR setup, events silently
never fire** — no exception, no log, nothing.

`UserService.GetUser()` swallows both `InvalidOperationException` and generic `Exception`
from `IAuthService.GetUser()`, returns `null` instead of throwing. Any handler
dereferencing `request.User.Username` without a null check → NRE, not obvious from the
interface signature.

## common-lambda

`ScanAndInstallDependenciesModule` (Autofac) scans `AppDomain.CurrentDomain.BaseDirectory`
for `YourProduct.*.dll` and registers all types `AsImplementedInterfaces().SingleInstance()`.
**Convention requirement**: any assembly needing auto-wired DI in a Lambda MUST be named
`YourProduct.*` — anything else is silently skipped, no registration, no error until
resolution fails downstream.

`ExceptionHandlingInterceptor` is a separate, independent MediatR behavior from
common-cqrs's interceptors (different generic constraint: `IRequest<TResponse>` vs
`ICommand<TResponse>`) — registering both in a Lambda is intentional layering, not
redundant.

## common-logging

**Key fact**: `SetupLoggingExtensions.Configure` bridges two logging systems at startup —
builds a Serilog `LoggerConfiguration` and sets `Log.Logger`, AND calls
`Common.Logging.LogManager.Configure(...)`. This means `shared`'s legacy `ILog`-based
`LogExtensions` calls route through Serilog once this bridge runs. **If a consumer never
calls `.SetupLogging()`** (e.g. a Lambda that skips the ASP.NET Core host pipeline),
legacy `ILog` calls go nowhere / use default config, silently.

`HeaderLoggerDecorator` dumps ALL request headers verbatim into 500-error log context —
**no redaction of `Authorization`/cookies** at this layer. Redaction (see
[[ama-debugging-notes]]'s `REDACTION-AND-LOGGING.md`) happens elsewhere in the pipeline —
don't assume secrets are scrubbed here.

Only 500+ responses get the full decorator chain (`HeaderLoggerDecorator`,
`BodyLoggerDecorator`, `FormLoggerDecorator`, `HostLoggerDecorator`,
`ProtocolLoggerDecorator`, resolved via `IEnumerable<ILoggerDecorator>` — order is
registration order, not an explicit priority). Non-5xx traffic logs one line at Debug —
Debug must be enabled to see per-request timing for normal traffic.

**Don't assume every library is on the same baseline TFM before a fleet-wide bump** — one
library was found lagging a full version behind the rest of the fleet during the net9
upgrade, needing a bigger multi-target jump than the standard one-version add everyone
else did. Check each repo's actual current TFM first, don't assume uniformity.

## common-models

Plain POCOs/DTOs, nothing non-obvious.

## common-mongo

Multi-connection-string design: `RegisterMongoConfiguration` reads
`MongoSettings:Connections` (a list, `Key`+`ConnectionString` per entry), registers one
`Keyed<IMongoClientFactory>(key)` per entry. **Consumers must resolve via Autofac's
`IIndex<string, IMongoClientFactory>`**, not a plain injected factory — a service
expecting the old flat `MongoSettings:Connection` shape finds nothing.

`RegisterMongoConfiguration` has a startup-time side effect: installs a CA cert into the
local X509 Root store if `MongoSettings:CACertLocation` is set — **throws at startup** if
the path doesn't exist. Easy-to-miss reason a service fails to boot in a new environment.

## common-swagger

Builder-pattern wrapper around Swashbuckle, nothing deeply non-obvious.

## certificateloader (added later)

Tiny lib: pulls an HTTPS cert from AWS Certificate Manager Private CA at Kestrel startup
(`UseHttpsCertificateFromPCA()`). Not DI-registered — called directly in `Program.cs`,
`ICertificateAuthorityLoader` is `new`'d up, never resolved from a container. Sync-over-async
(`.Result`) at bind time, no visible timeout — can hang startup on a slow/unreachable AWS
call. **Bug found and ticketed (PROJ-15163)**: its "skip cert loading under Tye
(local dev)" check reads env var `"ASPNETCORE_ENVIRONMENT "` (trailing space) — never
matches, so the skip is dead code; it always makes a live AWS call, even locally. Zero
external consumers today.

## Library dependency layers (in-house `YourCompany.Product.*` refs) — upgrade bottom-up

Computed from csproj PackageReferences across `libraries.md`. Fleet-wide lib change
(e.g. framework bump) → do leaves first, up.

- **Layer 0** (no in-house deps): auth, caching, common-configuration, common-models,
  common-lambda, common-logging, common-mongo, common-swagger, shared-http,
  cohortcontracts, exportproducer-messages, featureflags, fieldtablemapper-client,
  webhooks, **certificateloader** (added later, confirmed zero `YourCompany.Product.*` refs)
- **Layer 1**: common-cqrs→auth; cache-update-shared→common-lambda;
  notifications-client→common-configuration,shared-http;
  **shared**→auth,caching,common-configuration,common-models,shared-http
- **Layer 2**: reportclient→shared,common-configuration,shared-http
- **Layer 3**: search-cache, search → reportclient,shared + most of Layer 0

New library repos added to the fleet after this section was first computed:
`certificateloader` (see above, already folded in). A second one, `core`, was added and
then **removed again as redundant** (2026-07-23) — it was an in-progress, unfinished
consolidation library with zero external consumers; don't expect to find it if an old
reference surfaces somewhere. Re-check `libraries.md` (now at
`~/Repos/AMA_APP/developer-docs/repos-overview/libraries.md`) periodically — this list isn't automatically
kept in sync with it.

`shared` is most-referenced fleet-wide but NOT a leaf — sits on the 5 Layer-0 libs above.
Most-referenced leaves: common-configuration, shared-http (5 dependents each). Libs
reference each other at PINNED published versions, not floating ranges, so each builds
independently against the currently-published packages — local multi-target edits in one
repo don't affect another's build until published.

## Search.Cache lives in the `search` repo (duplicate `search-cache` repo removed 2026-07-23)

`YourCompany.Product.Search.Cache` is published from the **`search`** repo, packed by its
own pipeline — not from the similarly-named `search-cache` repo, which used to publish the
SAME package ID at a stale, older version. That standalone repo was the duplicate and has
been removed (repo deleted; local clone + classification entry dropped). Consumers
(`cohortdata`, `export-cohort`, `fieldtablemapper`, `resultsprocessor`) reference the
package ID and resolve the newer version from CodeArtifact regardless, so the removal is
transparent to them.

The `search` repo is a 14-project solution mixing 3 published libs (Search.Shared,
Search.Cache, Search.ResultsProcessor) with lambdas/console exes — when upgrading
(deferred, PROJ-15145), multi-target only the published-lib ProjectReference closure,
leave exe/lambda projects single-TFM (multi-targeting an exe splits output into per-TFM
folders, breaks Makefile/publish paths).
