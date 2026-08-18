# Report templates — where report fields actually live

Repo `reports`, subpath
`YourCompany.Product.Reports/Database/Migrations/Repeatable/TemplateReports/Templates/`.
Resolve repo path via `bash ~/.claude/hooks/lib-harness-repos.sh path reports` — never
hardcode `~/Repos/AMA_APP`, other machines differ.

23 report JSONs (`channel.json`, `pool-data.json`, …) + `report-template-schema.json`
(schema ref). Sibling `../R__*.sql` = Evolve repeatable migrations, one per report:
`DELETE FROM public."TemplateReport" ... INSERT ... ('<id>', false, '${<id>}')` — JSON
injected as the `${<id>}` placeholder.

## Shape

Top-level keys: `name`, `label`, `Source`, `multiTableSetName`, `Index`, `Table`,
`canCreateCohort`, `Fields`, `FieldsGroup`, `Dimensions`, `CohortType`, `ReportType`,
`preReleaseLabel`. `Filters` also shows up in real templates (not in schema).

`Fields[]` entry: `{valid, field:{name, label, fieldType, columnType, hidden,
metaData…}, aggregationFunction, fullName, normalisedName}`. `field.label` doubles as
key for SQL-Template fields. `field.cteSource` = key into SQL Templates' CTEs, also
groups that field's block independently in grid + export.

## Gotcha 1 — not parseable JSON as-is

Templates embed Evolve placeholders (`${cpr_fields_latest_60_months}`,
`${mcpr_fields_60_months}`, `${four_months_date_filter}`, ~30 distinct). `jq` on
`channel.json` -> `Invalid numeric literal` — expected, not corruption. Placeholders
built by `YourCompany.Product.Reports.Domain/Builders/EvolvePlaceHolderBuilder.cs`
(date-relative CPR/SMM/RPB/prepay/delinquency blocks off `AggregationMetadata`),
substituted by `Builders/JsonBuilder.cs`. Want resolved JSON -> go through tests below,
not `jq`.

## Gotcha 2 — check the field isn't ALREADY there, hidden, before adding one

Templates carry many `hidden: true` fields (SQL-Template/weighted variants, e.g.
`template_wa_original_ltv` alongside a visible `loanperiodic_originalltv`). "Add field X"
is often a one-line `hidden: true` -> `false` flip, not a new `Fields[]` entry — grep the
template for the label AND the likely column before writing anything. Confirmed via a
blind test: "add Original LTV to Channel" turned out to already exist, visible, in both
`Fields[]` and `Dimensions[]`.

Field genuinely missing from the UI but present+visible in the template -> suspect a saved
grid layout or the `ALL_THE_TEMPLATE_REPORTS` cache, not the template.

## Gotcha 3 — adding field = JSON edit, not schema migration

`R__` = Evolve repeatable, re-runs on checksum change -> template edit republishes row
next deploy. New `R__..._Data.sql` only for a brand-new report.

## Gotcha 3a — deploying the change is NOT enough: run a cache update, per environment

`reports` caches templates and `search` caches the SqlTemplate set, both in Redis — a redeploy
does NOT clear them, so the API keeps serving the pre-change copy and your edit looks like it
did nothing. Worse, removing SqlTemplate columns can 500 the report outright (stale generated
`OTHERS_PCT` still sums the removed aliases → `42703 column ... does not exist`).

**Run a `main` cache update after EVERY deploy of such a change, in EVERY environment it
reaches** — qa, staging, production separately, it does not carry over.

Narrower single-type updates look attractive but carry a confirmed trap: a `sqltemplates`
*update* only re-runs export's migration and never clears `search`'s own Redis copy of the
set, so the report keeps failing on the stale SQL. Mechanism and the exact trigger/monitor
calls (**HTTP 200 only means "queued"** — confirm completion): [[ama-graylog-search]]'s
`CACHE-UPDATE-DEBUGGING.md`.

## Gotcha 3b — a cohort-type report can't be verified via its raw template URL

`ReportType: cohort` templates (e.g. MCF Header Export) never auto-query on
`/aggregations/<template-id>` — the grid sits on "Loading…" forever with NO request and, for a
RequestedDownloads-role user, a client `TypeError ... reading 'searchRequest'`
(`preLoadRequestedDownloadsData` gets the template id where a saved report id belongs).
That's not the deployed change failing — it's the wrong route. The real user path is
**Dynamic Cohorts → Cohort Reports → open an MCF Report**
(`/dynamic-cohorts/reports/mcf-header-export/view/<report-id>`), which queries per cohort.
For value assertions, grab the grid API via
`document.querySelector('.ag-root-wrapper').__agComponent.context.getBean('gridApi')` (+
`columnModel`) — the grid virtualizes ~226 columns, so DOM-reading headers misses most.

## Gotcha 3c — column requested but absent from `SqlTemplate` table: CSV cell DROPPED, not empty

ANY export (user-triggered or monthly download) requesting a template column with no row in
that env's export-DB `SqlTemplate` table writes the header but DROPS the data cell — rows
misalign, N-1 values under N headers. Diagnose: `SELECT "Column" FROM "SqlTemplate" WHERE
"Column" IN (...)` on the env's export DB ([[ama-postgres-access]]).

How an env gets there: metadata on the SHARED Redshift cluster advances the moment PROD
loads monthly files, but each env's `SqlTemplate` table only rebuilds on that env's own
cache update → qa/staging can reference (or auto-roll to, post-PROJ-15286) a month
their `SqlTemplate` set can't compute yet. Fix: `main` update on that env (per Gotcha 3a —
not `sqltemplates`-only), then re-export.

## Gotcha 4 — two tests gate every template edit

`YourCompany.Product.Reports.Tests`:
- `JsonTemplateTest` — per-file `[InlineData]` list. New template file silently
  untested unless added there. `aging-curve.json` currently commented out (known
  flaky, not maintained).
- `DisabledFiltersMustHaveACorrespondingDimensionTests` — every disabled `Filters`
  entry needs matching `Dimensions` entry, all templates.

## Confirming a field is real

A template's `Source: aggregation-db` + `Table` (e.g.
`loan_by_servicer_transfer_non_periods_source`) and each `field.name`
(`<table>.<column>`) resolve against the **main aggregation DB — Redshift, one shared
cluster for QA/Staging/Prod, read-only**. Every field and every possible value a report
can select from lives there, full stop — **never a Postgres DB** (`ama-postgres-access`
also covers per-service Postgres DBs like `exportproducer`'s, a completely different,
unrelated target — don't confuse the two).

**`Table` is legacy — don't reason from it.** Every report reads MULTIPLE tables now:
`multiTableSetName` (`loan`/`pool`) picks the table set, then FieldTableMapper maps each
field to whichever table in that set holds it, and `search` replaces the JSON's table
alias with its own. `Table` is also not a queryable name (logical, not physical — direct
query errors). A field absent from the `Table` table is NOT a missing field.

Read [[AGGREGATION-DB.md]] before writing any query — it has `ama_tables`, the
search-across-the-set recipe, the duplicate-field tiebreak, and which tables need LEFT
joins. [[ama-postgres-access]] has the access path (`rs-query.sh`, no Docker needed).

## Gotcha 5 — `label` is the SQL-Template key, `friendlyName` is only the output header

Adding/renaming a SQL-Template column touches up to 3 repos; header exists only if all agree:

- `reports` template JSON — `field.label` = lookup key into SqlTemplate. Optional
  `field.friendlyName` overrides header text WITHOUT changing the key.
- `export` `Database/Migrations/Level1/Level2/R__Add_Sql_Template_Data.sql` — one
  `INSERT INTO public."SqlTemplate" ("Column",...)` per header, `"Column"` must equal `label`.
- `resultsprocessor` `Domain/Files/McfPocHeaderDictionary.cs` — separate `label -> header` map.

Renaming a header is EITHER a `friendlyName`-only edit (no SQL change) OR `label` +
SqlTemplate `"Column"` in lockstep. Grep both keys first — MCF mixes both styles within one
group (`TPOBROKER` was a `friendlyName`, `TPONOTSPEC` a `label`).

Stale `SqlTemplate` rows exist for keys nothing references — a row existing ≠ it's live.

**MCF servicer `*_PCT` templates are GENERATED, not in the .sql** — `export`
`Domain/Services/McfServicersService.cs` holds `Dictionary<string, List<string>>` (MCF key ->
AMA servicer name(s)); `Builders/McfServicerFieldBuilder.cs` appends `_PCT` and emits
`OTHERS_PCT = 100 - sum(rest)`. Names match `lower()`-to-`lower()` against
`loanperiodic_servicer` → a misspelled name yields silent 0%, never an error. Verify every
name against the DB ([[AGGREGATION-DB.md]]) before shipping.

## Editing a template JSON or data-dictionary migration by script

- **These files are CRLF.** Regex built with `\n` matches nothing, silently — use `\r\n`.
- `R__Add_Data_Dictionary.sql` / `R__Add_LLM_Data_Dictionary.sql` embed one JSON doc per
  `(false, '{...}');`. Key name differs: `name` in the first, `label` in the second (plus
  `fieldNames`).
- **Escape every apostrophe in added text as `''`** (convention already in these files, cf.
  `borrower''s`). A bare `'` ends the SQL literal early → `42601 syntax error at or near
  <next word>`, and Evolve aborts the WHOLE repeatable set on the first failing script, so
  an unrelated template migration silently never applies and the API keeps serving its
  cached copy. Same trap for any name reaching SQL via C# (`Click n' Close, Inc.`).
- **`JSON.parse` CANNOT catch that** — `''` inside a JSON string is two valid characters, and
  a stray `'` still leaves parseable JSON. Validate the SQL literal FIRST (walk it, treating
  `''` as escaped, and check it closes where expected), THEN unescape `''`→`'` and parse.
- Their column lists are alphabetically sorted, `OTHERS_PCT` an ordinary key (not pinned
  last). Append then re-sort the whole list; positional insertion misplaces it.

## UserReport `Report` vs `Query`/`TemplateFields` — different consumers

`UserReport` (reports DB) carries per saved report:

- `Report` (jsonb) = report definition. Drives UI load/display. Monthly reports cache update
  (`Domain/Services/UpdateUserReportService.cs`) rolls its date fields/filters forward
  (`AutoUpdateFields=true` rows).
- `Query` (jsonb, `SearchQuery`/frontend SearchRequest shape) + `TemplateFields` (TEXT,
  JSON list of normalised names) = NOT used for UI load nor user-triggered exports — UI
  builds fresh query, sends straight to search/export API. Sole consumer: **monthly
  downloads** (report transfers) — full pipeline, S3 layout, targeted-run recipe in
  [MONTHLY-DOWNLOADS.md](MONTHLY-DOWNLOADS.md).
- FIXED as of hotfix/128.0.1 (PROJ-15286): cache update now rolls BOTH forward —
  any `_MM_YY`-suffixed column (month 01-12) in `Query.SqlTemplateColumns` +
  `template_*_MM_YY` entries in `TemplateFields`, all families (CPR1/CDR1/SMM/RPB/
  Paydowns/Moneyness/CPR{n}/CPR1_Curtail/delinquency-with-space). NormalisedName shifted
  in place (preserves UI prefix normalisation). Pre-hotfix stale rows do NOT self-heal —
  shift = row's `MetadataLatestCprYear/Period` vs latest metadata, not Query content →
  already-stale row stays exactly as many months behind. Datafix still needed per row:
  shift BOTH fields in step (jq shift + transactional UPDATE + stored-value equality
  check); fixing one alone exports a dangling empty column and drops the newest month.
- Testing the roll on a fresh report: UI stamps `MetadataLatestCprYear/Period` = current
  metadata at save → monthDifference 0 → deliberate no-op. Set the row's metadata columns
  back N months first, then trigger `cache-type=reports`.
- Reports-api DEPLOY runs the full reports migration at startup — a Graylog
  `Fetched User Reports`/`REPORTS MIGRATION` marker may belong to the startup run, not
  the one you triggered. Disambiguate by the correlation id in each line (the reports
  service mints its own, ≠ the cacheupdate trigger's) + timestamps.

## Related

- `Database/Migrations/Repeatable/R__Add_LLM_Data_Dictionary.sql` — Chat-AI field
  dictionary. New user-visible field may need an entry here too.
- Serving/cache: `Domain/Services/TemplateReportService.cs`
  (`ALL_THE_TEMPLATE_REPORTS` cache key), `TemplateFilesService.cs`.
