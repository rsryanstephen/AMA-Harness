# Repo → Graylog `application` field — confirmed mapping

Queried directly from real Graylog messages (`application` field values seen across
production/qa/staging + targeted keyword searches), not guessed from repo names — several
of these do NOT follow the obvious `<repo>-api` pattern. Check here before free-text
searching to pin down an app name; saves the token cost of re-discovering it.

## API services

| Repo | Graylog `application` |
|---|---|
| search | `product-service-search-api` |
| reports | `product-service-reports-api` |
| fieldtablemapper | `product-service-fieldtablemapper-api` |
| resultsprocessor | `product-service-resultsprocessor-api` |
| querybuilder | `product-service-querybuilder-api` |
| manage | `product-service-manage-api` |
| notifications | `product-service-notifications-api` |
| feedback | `product-service-feedback-api` |
| export | `product-service-export-api` |
| exportproducer | `product-service-exportproducer` (no `-api` suffix) |
| export-cohort | `product-service-export-cohort` (no `-api` suffix) |
| cohortreports | `product-service-cohort-reports` — **note the hyphen**, doesn't match the repo name `cohortreports` |

## Lambdas

| Function | Graylog `application` |
|---|---|
| selenium-crawlers | `selenium-caching-crawler` — **neither "product-service-" prefixed nor matching the repo name** |
| cacheupdate-infrastructure: APIGateway.Lambda | `product-service-cacheupdate-apigateway-lambda` |
| cacheupdate-infrastructure: CacheClear.Lambda | `product-service-cacheclear-lambda` — **no `cacheupdate-` infix**, unlike its sibling lambdas below |
| cacheupdate-infrastructure: Cascade.Lambda | `product-service-cacheupdate-cascade-lambda` |
| cacheupdate-infrastructure: Start.Dequeue.Lambda | `product-service-cacheupdate-start-dequeue-lambda` |
| cacheupdate-infrastructure: UpdateCacheState.Lambda | `product-service-cacheupdate-updatecachestate-lambda` |
| fieldtablemapper's cache-update lambda | `product-service-fieldtablemapper-cacheupdate-lambda` |
| export's SqlTemplates cache-update lambda | `product-service-export-cacheupdate-lambda` |
| export's report-transfers lambda | `product-service-report-transfers-lambda` |
| reports' cache-update lambda | `product-service-reports-cacheupdate-lambda` |

## Confirmed NOT present in Graylog — don't waste time searching for these

- **`admin`, `exporterplus`** — S3-hosted static frontends, no backend app to emit logs.
- **`mappingtool-service`** — empty shell repo, no code shipped yet.
- **`lambda-cognitologging`** — dormant since 2019, unlikely to have recent log volume.

## Not yet confirmed — don't guess, search fresh if needed

- **`cohortdata`** (Lambda) — no distinct `application` value found across a 90-day
  keyword search. May log too infrequently to have shown up, or may share another
  service's app name.
- **`notifications`'s cache-update lambda** and **`search`'s `curve-cacheupdate`
  (Curve step) lambda** — not found distinctly in the same sweep. Confirm fresh rather
  than assuming a `product-service-<name>-cacheupdate-lambda` pattern — the table
  above already shows that pattern isn't universal (`cacheclear-lambda` breaks it).

## Not AMA_APP at all — this Graylog instance is shared with other systems

Seen and ignorable for AMA_APP work: `collateral-build`, `orchestrator-engine`,
`EXTRACTION v3: Data Feed Ingestion`, `YourProduct ETL PRODUCTION: DataTransfer`,
`dynamic-cohorts-build`, `daily-dynamic-cohorts-loader`.
