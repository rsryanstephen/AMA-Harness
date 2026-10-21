# DI eager-construction gotcha — Shared, search, fieldtablemapper

## Root cause (in `product-service-shared`)

Commit `cddff8c1` ("Change database connection classes to use NpgsqlDataSource") moved
connection-string validation from **lazy** (only inside `CreateConnection()`, when a
connection type is actually used) to **eager** (constructor calls
`new NpgsqlDataSourceBuilder(conn).Build()`, validating immediately at construction).
Fixed in Shared version `46.3.5.68` — anything a consumer still references below that
version can hit this.

## Why this crashes consumers for connection types they never even use

Several consumers register ALL `IConnectionType` implementations via Autofac
`RegisterAssemblyTypes(...).AsImplementedInterfaces()` — a blanket assembly scan, not a
deliberate per-type registration. Anything depending on `IList<IConnectionType>`
(typically `ConnectionManager`, often a singleton) triggers eager construction of EVERY
registered type the moment it's first resolved, including types that consumer never
configures or uses. A previously-harmless unconfigured connection (null connection
string, never touched) becomes an app-breaking crash on startup/first request.

Confirmed error signature: `System Exception` failing to activate along
`...AggregationMetadata.MetadataFacade` → `AggregationDatabaseMetadataService` →
`AggregationDatabaseRepository` → `ConnectionManager` (or `PossibleValueServiceFactory` →
`IPossibleValueService`). See `~/.claude/skills/ama-graylog-search/KNOWN-SIGNATURES.md` for
the Graylog-side triage rule.

## Confirmed instances, two different fix shapes

- **`search`**: `Startup.cs:161`, `RegisterAssemblyTypes(assembly).AsImplementedInterfaces()`.
  Fixed by the Shared version bump alone (no app-level change needed) — `search` had no
  Postgres config of its own to work around.
- **`fieldtablemapper`**: `Startup.cs:135-148` blanket-scans every `YourProduct.*.dll`,
  eagerly building all 7 Postgres connection types via `ConnectionManager`
  (`Startup.cs:152`) even though FieldTableMapper is Redshift-only. Fixed **app-level**,
  not via version bump: exclude any `IConnectionType` whose ctor needs
  `IPostgreSqlConfigurationReader` via a predicate, not hardcoded `.Except<T>()` calls —
  so a future new Postgres type added in Shared won't silently re-break this. Ticket
  PROJ-15115, commit `db6b366` on `develop`.

**Before assuming a new hit of this signature is a fresh bug**: check the affected repo's
`YourCompany.Product.Shared` version first (`>= 46.3.5.68` → different/new issue, investigate
fresh; below it → likely this same regression, check [[ama-library-version-sync]]'s
cascade status rather than re-diagnosing).
