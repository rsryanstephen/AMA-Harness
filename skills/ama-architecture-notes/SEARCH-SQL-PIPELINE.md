# `search` — request → SQL → memory: the gates that decide LIMIT, stitch, and heap

All paths `YourCompany.Product.Search.Shared/` unless noted; line numbers as of `develop`
2026-08-27 (Search.Shared 19.1.3). Companion to [AGGREGATION-DB.md](AGGREGATION-DB.md) Trap 5
(the `_unique` dedup convention the stitch is often confused with).

## Request → SQL

`SearchController.SearchV2` → `Domain/Services/SearchFacade.ExecuteSearch` (`:79-85`: `maxRowCount
= DefaultSearchSize` (40), forced to 0 when `Metadata.PageSize > 0`) → `SearchService.ExecuteUserQuery`
→ `Builders/SqlUserBuilder/SqlQueryBuilderLocator.Get` (`:20`; first `ISqlQueryBuilder.IsValid`,
default `AggregationDatabaseSqlQueryBuilder`; the CTE builder wins iff any `SqlTemplateColumn.CteSource`
is set, `CommonTableExpressionSqlQueryBuilder.cs:63`) → `Executor/AggregationDatabaseSearchExecutor
.ExecuteRawQuery` → `ResultSetMaterialiser.Materialise(rows, SqlSettings.MaxMaterialisedRows)`
(Search.Shared ≥19.2.0; throws `ResultSetTooLargeException` past the cap. **Library default 0 =
unlimited**; only search-api opts in, `appsettings.json` 100000 — never set it in `export-cohort`
or anything that legitimately reads big sets. `buffered:false` only drops Dapper's second copy, it
does not stream; exports stream via `AggregationDatabaseRawSearchExecutor` instead).

## Select list — the one place every measure converges

`Builders/Select/SqlSelectBuilder.BuildSqlList` is the chokepoint. It collects **14 measure
families** (aggregated, SqlTemplate, CprN, calculated, bucket, percentage, cprCalculated,
trendOfByDate, percentageChange, the three pivots, band, dynamic), THEN adds the row-id, THEN
the grouping columns via `ISqlFieldListBuilder`. So measures and group-bys are cleanly
separable by position — that split is load-bearing, keep it.

**Anything that must apply to every measure goes here, not in `export`'s field builders** —
those cover only the `$(...)` placeholder families, a small minority of all columns
([[REPORT-TEMPLATES.md]]). Existing rewrite hooks to copy: `ISelectFieldSqlVisitor` (chain run
by `SqlAggregatedFieldBuilder`; `LoanHistoryAggregationVisitor` already does a
`CASE WHEN … ELSE NULL` rewrite) and `ISqlCoalesceWrapper` in `SqlFieldListBuilder`.

**Changing it = changing every shape below.** "They route through it, so they inherit it" is
the reasoning that shipped PROJ-15416's five follow-up defects — inheriting is the risk.
Each consumer re-shapes the list differently; run each (protocol + EXPLAIN sweep:
[[ama-debugging-notes]]' `SHARED-CHOKEPOINT-CHANGES.md`). Only group-by lists (`BuildForCte`) bypass it.

| Consumer (`Builders/…`) | What it does to the select list | Known break |
|---|---|---|
| list entries themselves | trend-by-date / dimension-pivot / pct-change-pivot return ONE entry of comma-joined columns | 15808: wrapper around `a AS x, b` → 42601 |
| `SqlUserBuilder/AggregationDatabaseSqlQueryBuilder` | verbatim; `UNION`; `BuildRowCount`/`BuildGroupByQuery` wrap `FROM (…) sq`; top row appends `, rowcount` | — |
| `SqlUserBuilder/CommonTableExpressionSqlQueryBuilder` (any `CteSource`, MCF quartiles) | `BuildDictionary` splits on `" AS "` (>2 parts throws), outer `SELECT … FROM all_rows` LEFT JOIN quartiles_cte, `.Replace`s text | 15801: loan alias out of scope → 42P01 |
| `SqlUserBuilder/HierarchicalSqlQueryBuilder` | several builds `UNION ALL`, wrapped in `SUM(rowcount)` | — |
| `CommonTableExpression/CollateralCteBuilder` (CMO) | loan table only inside `collateral_cte` | 15463: 42P01 |
| `HavingCriteriaCteBuilder` | re-wrapped as `having_cte AS (…)`; top row `.Replace("pct__","pctfilter__")` | — |
| `ServicerStitch/RowIdCteBuilder` | re-wrapped as `CteRow_Ids AS (…)` | — |
| `SqlSelectBuilder.OrderedSql`/`Compare`, GROUP BY by alias | split on `" AS "`; band `_order` keys grouped by alias | da198cdd: aggregate in GROUP BY → 42803 |
| `ResultsProcessor/UnloadQueryBuilder` | whole query inside `UNLOAD('…')`, quotes doubled | — |

Tests mock `ISqlSelectBuilder` in every builder test above — a select-list change is invisible to
them. Full-SQL-through-real-container tests: `Search.Shared.Tests/Integration/*RegressionTests.cs`
(aggregation shape only).

## Single-loan mask — why a measure cell is blank

`Builders/Select/SingleLoanMaskBuilder` (PROJ-15416) wraps each measure in
`CASE WHEN COUNT(<alias>.loanperiodic_originalloanamount_unique) = 1 THEN NULL ELSE <expr> END`
— a row covering exactly one loan must not present that loan's figures (contractual, <one entry per line; this element only declares the type>).
COUNT over a `_unique` column is a DISTINCT-loan count (AGGREGATION-DB Trap 5). Predates it:
`export`'s `HistoricalRpbFieldBuilder` guards historical RPB the same way (PROJ-11297),
now redundant but harmless.

Deliberately NOT masked, each for a reason — don't "fix" these:
- `count__loanperiodic_originalloanamount` (**# Loans**) — a loan count is not loan-level data,
  and PROJ-14925's notice needs it.
- Queries with no `GroupingColumns` — no GROUP BY is emitted, so a row is not a group of loans
  and adding an aggregate would change what the query returns.
- Pool-set reports — no per-loan count column; a pool row aggregates a pool, not a loan.

Consequence to expect: `ORDER BY` on a masked measure sorts NULLs, so at `PageSize` 80 it can
change WHICH rows are returned. Filtering is unaffected — HAVING is emitted from the criteria
expressions, not the select aliases, so it still evaluates the true aggregate.

## Where the LIMIT comes from — and the one case it is deliberately absent

`Builders/Limit/SqlLimitBuilder.cs` → `AggregationDatabaseLimitBuilder.cs`:

| request | LIMIT |
|---|---|
| `Metadata.PageSize > 0` (UI, default 80) | `LIMIT {PageSize} OFFSET {PageOffset}` (`:37-42`) |
| `PageSize` 0/absent | `LIMIT {DefaultSearchSize}` (=40) via `Take` (`:30`) |
| exports, row-count, `BuildSqlWithNoLimit` (`Take=0`, `PageSize=0`) | none — by design |
| `Metadata.ForTopRow` | none |
| servicer-stitch CTE built | none on the outer query; the LIMIT sits **inside `CteRow_Ids`** |

`SqlLimitBuilder` drops the outer LIMIT only when `IsStitchBeingApplied && HasStitchOnHighRequest`
— the same pair `RowIdCteBuilder` / `RowIdCteJoinBuilder` gate the CTE on. Before 19.1.3 it checked
the first gate alone; a query that passed it but not the second got no CTE and no LIMIT → whole loan
universe materialised (PROJ-15349). Since PROJ-15352 the first implies the second (one
criterion, below), but keep using the *pair* in limit-affecting code — it documents the dependency.

## Servicer stitch — one criterion, decided at UserQuery-build time (PROJ-15352)

Plain-language why/what (data shape, worked loan, why the row-id CTE exists):
`developer-docs/docs/servicer-stitch.md` — read that first if the *purpose* is unclear; this file
is gate mechanics only. The CPRn ARITHMETIC under the stitch (what `cprN_sched_rpb` is, the
`rows_per_loan` divisor, the month-valid pro-rata rule, the rule tickets):
[CPRN-STITCH-ARITHMETIC.md](CPRN-STITCH-ARITHMETIC.md).

The criterion: **a measure reads a per-servicing-period source** (`loan_by_servicer_transfer_periods_source`,
`…_moneyness_source`, `…_cprn_source`). Measures = aggregated fields + SqlTemplate columns + CprN
fields; grouping/criteria tables deliberately excluded. Decided in
`Builders/MultiTable/MultiTableJoinTableSelector.ReadsPerPeriodSource` (the only place every
template's SQL is already resolved — `SqlTemplateColumn` carries a name, not SQL) and stored by
`MultiTableUserQueryBuilder.Build` into `UserQueryMetadata.ApplyStitch` (a shared-package property
that was dormant until then). Survives `DeepClone`, so the CTE's cloned query sees the same verdict.

`Builders/ServicerStitch/Validation/RequestValidator.cs`:

| gate | true when | controls |
|---|---|---|
| `HasStitchOnHighRequest` | `Metadata.ApplyStitch` | `CteRow_Ids` CTE + `INNER JOIN` (`RowIdCteBuilder`, `RowIdCteJoinBuilder`) |
| `IsStitchBeingApplied` | `ApplyStitch` AND a replaceable servicer column grouped (`loanperiodic_servicer`, `loanperiodic_serviceratissuance`, `buying/selling_servicer`) AND no transfer column grouped | SELECT/GROUP BY swap `loanperiodic_servicer` → `servicer`, `row_id`, `WhereStitcher` transfer-criteria strip, outer LIMIT/HAVING moved into the CTE |

`IsStitchBeingApplied` now implies `HasStitchOnHighRequest`, so the old "half-stitched" state
(swap without CTE) cannot occur. The sites that still check the pair (`SqlLimitBuilder`,
`SqlFieldListBuilder`, `RowIdFieldBuilder`, `WhereStitcher`) are correct, just redundant. The
`hasPaydowns`/`hasCpr` carve-outs in `SqlLimitBuilder`/`SqlHavingBuilder` are gone — Paydowns is
stitched like any per-period measure.

**History.** Until 2026-10 the two gates were name heuristics — a request-type list
(`cpr/mcpr/ctcpr/delinquency`, `ServicerStitchRequestTypeList`) and five column-name regexes
(`FieldIdentifierList`), all deleted. Both false for SMM, Historical RPB, CDR1, Moneyness, New
Inactive Loans and Paydowns, which read the same per-period tables CPR does → month values credited
to today's servicer (PROJ-15351 = audit; PROJ-15352 = fix; anchor loan
`3133KPES39989544631` Freedom→Truist 2024-11; Truist/WY June-2024 SMM 0.449%→0.467%, $28M foreign
book out of the denominator). Point-in-time delinquency (`cpr`-typed request, non-periods SQL) was
the first-true-second-false half-stitch (PROJ-15349 OOM, PROJ-15351 `# Loans = 0` rows);
under the SQL criterion it is simply not stitched. `RequestType == "IS CPR MAGIC STRING HACK"` is
still the sentinel the CTE's inner query sets so builders skip re-stitching/re-limiting inside it.

## Where a month-stamped column comes from — three repos must agree

1. **`reports`** — template JSON carries `${cpr_fields_latest_60_months}`-style placeholders;
   `Reports.Domain/Builders/EvolvePlaceHolderBuilder.cs` expands them into fields whose `name` is
   `template_<label>_MM_YY` lower-cased (`MonthYearFieldUtils.BuildSqlTemplateName`). That `name`
   is what the UI sends as `SqlTemplateColumn.NormalisedName`; `search` resolves the SQL by it.
2. **`export`** — `Export.Domain/Builders/*FieldBuilder.cs` generate the matching `SqlTemplate`
   rows (Column label `SMM_MM_YY`, `RPB_MM_YY`, `CDR1_MM_YY`, `Moneyness_MM_YY`, `Paydowns_MM_YY`,
   `% GNM RPB del90D+_MM_YY` …; SQL reads `_periods_`/`_moneyness_`). `search` looks the SQL up by
   that label.
3. **`exporterplus`** — `grid-search-request-builder.service.ts:411-421` routes each column to a
   request type by Column-label *prefix* (`cpr1_`/`paydowns` → cpr, `smm` → smm, `sum_current_rpb_`
   → historicalRPB, ` del` → delinquency, `moneyness` → moneyness, `_isinactive` aggregated →
   newInactiveLoans, else **`other`** — `main` is only the top-row request). CDR1 (`cdr1_`) and the
   export's RPB label (`RPB_MM_YY`, not `sum_current_rpb_`) have no rule → `other`.
A new month-based family needs reports + export to agree on the name; the stitch itself follows
from the SQL (PROJ-15352), so the request type no longer matters to it — it only decides which
request the column rides on.

## Testing whether a family is stitched — replay recipe

Servicer Rankings body, `GroupingColumns=[loanperiodic_servicer]`, criterion State=WY (cache-buster),
one `SqlTemplateColumns` entry `{Column:'SMM_07_26', NormalisedName:'template_smm_07_26',
FieldType:'Number'}`, `RequestType` per step 3, POST `search-<env>[-a|b|c].example-app.com/
search/servicer-rankings?t=low&l=<type>` (in-page fetch, see ui-verify pitfalls). Then
`bash ~/.claude/skills/ama-graylog-search/scripts/classify-stitch-sql.sh 12 900` — one line per
logged SQL: `fam= cte= swapToPeriodServicer= periodsJoined= GROUP BY …`. Stitched = `cte=1
swap=1 GROUP BY row_ids_stitch_…`; unstitched = `cte=0 swap=0 GROUP BY …__loanperiodic_servicer`.
Always include CPR1 as the positive control. A hand-built New-Inactive aggregated field 500s
(`_unique` suffix path) — the SQL still logs, which is all the check needs.

## Caching and in-process state

Results → Redis (`Startup.cs:165` `RedisCacheManager`), never in-process. Only in-proc state:
`AddMemoryCache` (`:374`, HMAC nonces) and `CurveAnalyser/SqlQuery/GnmAgeBasisBoundaryService.cs:27`'s
static dictionary. A fat heap is therefore *not* cached search results.

## Runtime memory model — read the graphs against the GC cap, not 100 %

Task def env (prod 16 GB, staging 8 GB): `DOTNET_GCHeapHardLimitPercent=70`, `GCHeapCount=2`,
`GCLOHThreshold=100000`. `System.OutOfMemoryException` fires at ~70–77 % `MemoryUtilized` — a
graph that "never reached 100 %" is consistent with an OOM, not evidence against one. The GC
releases only under pressure: prod (cap ≈11.5 GB) can idle at ~9 GB for hours after one big read
while staging (cap ≈5.6 GB) drops to baseline in minutes — retention, not a leak
(PROJ-15350). `YourCompany.Product.Search.csproj:7 RetainVMGarbageCollection=false` does not
force release. Health checks keep passing on a fat task; only a further burst gets it replaced.

## Graylog handles for a search request

- `ExecuteAsync::SQL` (Debug) — complete SQL in `full_message` (20 k+ chars fine); read the
  **tail** to see whether a LIMIT was emitted.
- `System Exception : … Payload: Request Url: … Request Body: {…}` (Error) — the **complete JSON
  request body** (~20 KB), valid as-is for replay on Staging
  ([ama-ui-verify pitfalls](../ama-ui-verify/references/chrome-driving-pitfalls.md)).

## Deploy topology

One `search` push → releases in **two** Octopus projects: `YourProduct_Exporter_Search_API_ECS`
(Projects-95) and `YourProduct_Exporter_Search_CacheUpdate_Lambda` (Projects-96). The Lambda
(`YourCompany.Product.Search.Lambda/UpdateCacheCommandHandler.cs:39`) only `POST`s
`{SearchServiceUrl}/search/cache/update/internal` and references `Search.Cache` — a SQL-builder
fix ships in the API alone. The API links `Search.Shared`/`Search.Cache` via `HintPath` to the
sibling projects' `bin` (source, not NuGet); `Domain` uses a `ProjectReference`. The NuGets publish
from `develop` only ([[ama-search-shared-version-sync]]).
