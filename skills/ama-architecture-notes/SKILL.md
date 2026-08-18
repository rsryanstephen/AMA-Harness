---
name: ama-architecture-notes
description: Architecture facts about the AMA_APP fleet — how libraries/API services/frontend/infra actually work, non-obvious conventions/gotchas. Use in shared, common-*, auth, manage, search, reports, resultsprocessor, exporterplus, admin, selenium-crawlers, cacheupdate-infrastructure, cohortdata, cohortreports, pipelines, octopus, config, or when investigating DI/connection-type wiring, auth, ASP.NET Core Startup, async messaging, frontend UI architecture, CI/CD pipeline versioning, report templates/fields, or external client IP whitelisting / security groups on the production endpoints.
---

# AMA_APP architecture notes

Index — read only the file(s) relevant to the current task, not all of them. Companion
to [[ama-debugging-notes]] (bug-class patterns) — this skill is architecture/structure.

**New to AMA or need the fleet-wide map first?** Start at
`~/Repos/AMA_APP/developer-docs/repos-overview/README.md` — repo-by-repo category lists plus
`RELATIONSHIPS.md` (how the categories connect). This skill's files below are the
deep-dive detail behind that map, not a replacement for it.

- **[CORE-LIBRARIES.md](CORE-LIBRARIES.md)** — `shared`, `common-configuration`, `common-cqrs`, `common-lambda`, `common-logging`, `common-models`, `common-mongo`, `common-swagger`. Read before touching logging, MediatR commands/queries, Lambda DI bootstrapping, or Mongo connections.
- **[AUTH-AND-SECURITY.md](AUTH-AND-SECURITY.md)** — `auth` and how JWT/HMAC auth is wired into API services. Read before touching `[Authorize]`, middleware pipeline order, or anything identity-related.
- **[API-SERVICE-CONVENTIONS.md](API-SERVICE-CONVENTIONS.md)** — the common (and NOT-common) ASP.NET Core Startup.cs shape across `manage`/`search`/`reports`/`resultsprocessor`/etc. Read before assuming any convention (health checks, Hangfire, ProblemDetails, DB migration timing) is fleet-wide — several aren't.
- **[SELENIUM-CACHE-CRAWLER.md](SELENIUM-CACHE-CRAWLER.md)** — `selenium-crawlers`: how the cache-warming Lambda actually works (Firefox-in-Lambda, DOM-based "ready" detection, silent-failure modes).
- **[FRONTEND-ARCHITECTURE.md](FRONTEND-ARCHITECTURE.md)** — `exporterplus` and `admin`: module structure, shared component/grid layer, config-loading mechanism, why the two apps diverge.
- **[MESSAGING-AND-LIBRARIES.md](MESSAGING-AND-LIBRARIES.md)** — the smaller libraries (`cohortcontracts`, `exportproducer-messages`, `featureflags`, `*-client` libs, `webhooks`, `caching`, `search-cache`, `shared-http`) and the fleet's (plural) async messaging patterns.
- **[SHARED-INFRA-AND-PIPELINES.md](SHARED-INFRA-AND-PIPELINES.md)** — `common`, `config`, `octopus`, `pipelines`, `shared-configuration`: what's actually alive, what's dead, and why a change here often needs manual propagation.
- **[FLEET-CONVENTIONS.md](FLEET-CONVENTIONS.md)** — repo naming vs Bitbucket remote names, the `libraries`/`api-services`/`ui-projects`/`shared-infra`/`testing` classification convention. Read first if you need to construct a clone URL or aren't sure whether a repo counts as a "library."
- **[TESTING-REPOS.md](TESTING-REPOS.md)** — `api-testing`, `ui-testing`, `shared-testing`: what each actually tests, the fuller negative-test-noise picture, and why none of them run automatically post-deploy.
- **[COHORT-SERVICES.md](COHORT-SERVICES.md)** — `cohortdata`, `cohortreports`: the SQS→Lambda→HTTP-callback chain, cohortreports' dual ECS/Lambda mode and SignalR usage, shared AggregationDB table, known dead code.
- **[REPORT-TEMPLATES.md](REPORT-TEMPLATES.md)** — where report definitions and their fields actually live (`reports` repo template JSONs), the Evolve placeholder mechanism, and the two tests that gate an edit. Read before adding/changing a report field.
- **[MONTHLY-DOWNLOADS.md](MONTHLY-DOWNLOADS.md)** — report transfers / monthly SFTP downloads: the admin-trigger → cacheupdate state machine → report-transfers lambda → export → S3 SFTP-bucket pipeline, which UserReport columns feed it, and the targeted single-report invoke. Read before triggering report transfers or debugging a wrong/missing monthly download.
- **[AGGREGATION-DB.md](AGGREGATION-DB.md)** — the main Redshift DB behind every report field/value: the `aggregation_metadata` indirection (a template's `Table` is NOT a real table), dated ETL snapshots, where the 501-column fact table's fields live, and recipes for finding a column or enumerating its possible values. Read before writing any query against report data.

## Adding to this — see [[commit-ticket]]'s "Leave context for future agents" section

Architecture/repo-structure facts: add liberally. Bug-specific findings belong in
[[ama-debugging-notes]] instead, and only for a genuinely generic, likely-to-reoccur
class — always confirm with the user first.
