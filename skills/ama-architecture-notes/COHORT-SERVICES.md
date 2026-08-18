# cohortdata & cohortreports

Both actively maintained (commits within the last day or two, unlike some of the fleet).
Known bugs found while surveying both are tracked as tickets (PROJ-15172 through
15175), not repeated here — this file is architecture/structure only.

## cohortreports is NOT purely an ECS task — it's dual-mode

`Program.cs` branches at startup: no `AWS_LAMBDA_FUNCTION_NAME` env var → normal Kestrel
host; env var set → boots as an `Amazon.Lambda.AspNetCoreServer.APIGatewayProxyFunction`
instead, via `LambdaEntryPoint.cs`. Same `Startup` class serves both. Don't assume
"long-lived process with background services" conventions apply without checking which
mode is actually deployed in a given environment.

## cohortreports adds SignalR — the only repo in the fleet that does

Real-time push channel (`services.AddSignalR()`, hub at `{prefix}/cohorts-notification/connect`)
used to progress-report cohort-data generation to connected clients. No other API service
has this.

## The messaging chain: cohortreports → SQS → cohortdata → HTTP callback back

`cohortreports` publishes cohort-data generate/delete messages to `cohortdata` via raw SQS
(see [[ama-architecture-notes]]'s `MESSAGING-AND-LIBRARIES.md` for the wire format).
`cohortdata` processes them, calls out to `search`'s `search/build-sql/compressed` endpoint
to get generated SQL text, resolves the target Redshift table via
`IFieldTableMapperClient.GetRedshiftTableName(...)`, then runs that server-generated SQL
directly (no parameterization — the text itself is the query) against `AggregationDB`.
Completion/failure is reported back to `cohortreports`/`curve-analyzer` via HTTP callback,
not SQS. **`cohortdata` has a hard synchronous runtime dependency on `search` being
reachable** — if `search` is down, cohort generation fails for that message.

## Cache invalidation is direct Redis, not the cache-update Lambda pipeline

`InvalidateSearchCacheEventHandler` calls `ICacheManager.ClearByAsync` (Redis) directly, in
`cohortreports`'s own process — confirms neither `cohortdata` nor `cohortreports` is part
of the cache-update Step Functions pipeline (also confirmed: no cache-invalidation
dispatch step in either repo's `bitbucket-pipelines.yml`).

## Both write to the same AggregationDB table from two different repos

`cohortdata` writes loan mappings via server-generated SQL (above). `cohortreports`
separately reads/writes/deletes a `CohortNameMapping` table in the same `AggregationDB`
via its own parameterized SQL builders (`Domain/Builders/Sql/`). Two repos, one shared
table, two different SQL-generation strategies — keep both in sync if the table shape ever
changes.

## Custom auth-service stand-ins in cohortdata, because Lambdas have no HttpContext

`CohortDataRoleService`/`CohortDataOrgService`/`CohortDataAuthService` explicitly replace
`YourCompany.Product.Auth.Security`'s defaults (`ConfigurationExtensions.cs`) — the real
defaults depend on `IHttpContextAccessor`, unavailable in a Lambda. Worth knowing before
adding new search/auth-dependent code to this Lambda.

## Retry semantics are inconsistent per-handler in cohortdata

`Function.ProcessMessageAsync` only allows 1 attempt overall. `DeleteCohortDataCommandHandler`
internally retries twice then rethrows (caught by the outer 1-attempt wrapper anyway).
`MapLoansToCohortCommandHandler`'s inner retry defaults to 1 attempt too. None of this is a
deliberate tiered strategy — check the actual handler before assuming retry behavior.

## Dead code, left in deliberately and by accident

- **Input sanitization was built, wired into DI, then explicitly disabled**:
  `IInputValidator`/`InputValidator` (PROJ-14908) is still registered in Autofac and
  constructed in `Function`, but its only call site is commented out
  (`Function.cs:66`, reverted in a later commit). A future agent grepping for
  `IInputValidator` will find live DI registration and a class doing nothing.
- **Seven zero-byte orphaned `.cs` files** in `cohortreports`, emptied (not deleted) by an
  October 2025 "Roll back" commit — e.g. `MongoSerializerInitializer.cs`,
  `SearchQueryMongoSerializer.cs`, `PascalCaseFormatterFilter.cs`. Zero references anywhere
  in the codebase; harmless but will confuse anyone who opens one expecting real code.

## `export-cohort` is a separate sibling repo, not covered here

Similar name to `cohortreports`, own `bitbucket-pipelines.yml` — see `api-services.md` in
`developer-docs/repos-overview` and `API-SERVICE-CONVENTIONS.md`'s own entry for it. Not the same repo,
don't conflate the two.
