# Aggregation DB — the main DB behind every report field and value

Amazon **Redshift** (not Postgres), cluster `your-redshift-cluster`, database `dev`,
schema `public`. Every field a report can select and every possible value it can filter
on lives here. QA/Staging/Prod share ONE cluster, read-only user per env — see
[[ama-postgres-access]] for access (use `rs-query.sh`, no Docker/password needed).

Reports the DB does NOT serve: per-service Postgres DBs (`exportproducer` hangfire,
`export` API's DynamicColumn/custom-band data). Different targets entirely.

## Trap 1 — a template's `Table` is legacy AND not a real table

Two separate things wrong with reasoning from `channel.json`'s
`Table: loan_by_servicer_transfer_non_periods_source`:

**(a) It's mostly legacy.** Every report reads MULTIPLE tables now. The template's
`multiTableSetName` (`loan` / `pool`) picks the table SET; **FieldTableMapper then maps
each field individually to whichever table in that set actually holds it**. The table
alias in the report JSON is irrelevant at runtime — `search` replaces it with its own
alias pointing at the field's real table. Never conclude "field X doesn't exist" from
looking at the `Table` table alone.

**(b) The name isn't queryable either.** It's a logical name, not physical:

```
ERROR: relation "public.loan_by_servicer_transfer_non_periods_source" does not exist
```

Logical -> physical lives in **`public.ama_tables`** (`multi_table_set_name`,
`table_name`, `redshift_table_name`) — that's the registry FieldTableMapper reads
(`MultiTableSettings.TableSource`).

```bash
bash ~/.claude/skills/ama-postgres-access/scripts/rs-query.sh \
  "select multi_table_set_name, table_name, redshift_table_name from public.ama_tables order by 1,2"
```

`public.aggregation_metadata` is a DIFFERENT, still-live thing — a single-row table of
snapshot pointers + `latest_cpr_field`/`_year`/`_period`, `last_updated`,
`gnm_available`/`fhl_fnm_available`, per-agency counts. Used for CPR/date placeholders
(`MetadataDapperRequestBuilder`), **not** for field->table resolution. Don't conflate the
two.

## Trap 2 — physical tables are dated ETL snapshots, never hardcode one

Naming: `<name>_v8_<YYYYMMDD>_<HHMM>` (e.g. `collateralview_v8_20260805_0629`), ~30 days
retained, new set per ETL run. Today's resolved name is wrong tomorrow. Re-read
`ama_tables` every time — that's the whole point of the indirection.

## Trap 3 — `collateral_cte` is not in `ama_tables` at all

`cmo-mega-view.json` / `cmo-mega-servicing-transfer.json` declare `Table: collateral_cte`.
It's a **CTE name defined in SQL Templates**, not a table and not an `ama_tables` row —
looking it up returns nothing, with no error to explain why. `search`'s `TableNameService`
special-cases it by name.

## Trap 4 — stable-named views can be pinned to a STALE snapshot

`public` holds 903 base tables + 160 views. The views have stable names (`cohort`,
`cohort_agency`, `clientloan_mapping`, …) which looks like the fix for Trap 2 — it isn't.
Confirmed: view `cohort` is defined over `truist_cohort_v8_20251103_0229`, months behind
the then-current `_20260709_1035` snapshot. Trust `ama_tables`, not a view name.

## Where the fields are — a SET of tables, not one

A field can be in any table of its set. Measured column counts (`loan` set, ~2,421
columns total):

| logical table | cols |
|---|---|
| `loan_by_servicer_transfer_periods_source` | 1046 |
| `loan_by_servicer_transfer_cprn_source` | 623 |
| `loan_by_servicer_transfer_non_periods_source` | 501 |
| `loan_by_servicer_transfer_moneyness_source` | 149 |
| `collateral_tranche_view_source` | 48 |
| `clientloan_mapping_source` | 27 |
| `collateralparentview_source` | 13 |
| `loan_history_by_periods_source` | 10 |
| `cohort_mapping_source` | 4 |

`pool` set: 10 tables (`pool_loan_view_source`, `collateralview_source`,
`poolcashflowview_{1,3,6,12,24,life}_source`, `poolembs{cpr,field}historyview_source`).

Note `..._non_periods_source` is NOT the biggest — searching only it (its 501 columns,
~155M rows, ~109M distinct `loan_id`) misses over 3/4 of the set. Confirmed examples that
exist ONLY in `..._periods_source`: `balance_at_transfer`, `delinquent_months_count`, and
the whole **`f<YYYYMM>_*` period-column family** (`f202105_current_rpb`,
`f202105_delinq_pmt`, `f202105_delmonths`, `f202105_historical_loan_age`, …) — that `f`
prefix is the same form as `aggregation_metadata.latest_cpr_field` (e.g. `f202606`). Search
only the `Table` table and you'd wrongly report these as nonexistent.

`bond-fields.json` has no `Source`/`Table` at all (fragment, not a standalone report).

Column families on `..._non_periods_source` (first token, count): `loanperiodic_` 159,
`securityperiodic_` 76, `current_` 45, `peer_` 36, `security_` 34, `forbearance_` 24,
plus `transfer_`, `cpr_`, `chronological_`, `arm_`, `dti_`, `delinquency_`, `balance_`,
`note_`, `age_`, `last_`, `latest_`, `servicer_`. Ids/joins: `loan_id`,
`loanperiodic_cusip`, `security_cusip`, `loanperiodic_sellerid`, `loanperiodic_servicerid`,
`security_embssecid`.

**Template `label` is a UI name, not a column.** `channel.json`'s "Channel" dimension is
column `loanperiodic_tpo`. `field.name`/dimension `name` = `<logical table>.<column>` —
strip the prefix for the real column, and treat the prefix as a legacy hint only
(`…non_periods_source.current_rpb_fedowned` → `current_rpb_fedowned`, `numeric`).

## How FieldTableMapper resolves a field — matters for hand-written queries

`FieldTableMappingService.GetMappings` (fieldtablemapper repo) walks every table in the
set, reads its columns, and emits field->table mappings, cached per set
(`CacheKey.FieldTableMapping`, `__AMA_FIELDS_IN_TABLE_*`). Three behaviours worth knowing:

- **Duplicate fields have a hardcoded tiebreak** — prefer
  `loan_by_servicer_transfer_non_periods_source`, and NEVER `cohort_mapping_source`
  (moved to end of list deliberately). Current duplicates per its own comment: `loan_id`,
  `transfer_date`, `transfer_end_date`.
- **`GetCachedMapping` uses `Single()`** — 0 mappings or 2+ mappings THROW, by design
  ("early warning"). A field missing from every table in the set surfaces as an exception,
  not a null.
- **Two tables are deliberately excluded** (`TableService.InaccessibleTables`):
  `loan_by_servicer_transfer_cprn_hist_source`, `loan_by_servicer_transfer_periods_hist_source`.

**Grain: one row per servicer-transfer EVENT, not per loan** — ~155M rows vs ~109M distinct
`loan_id` in both `..._non_periods_source` and `..._periods_source` (identical row counts).
So joining two tables on `loan_id` alone can MULTIPLY rows for any loan with >1 transfer —
add `transfer_date` (or a latest-transfer filter) when the report's grain is per loan.
There's also a `<col>_unique` sibling family (77 such columns in `..._non_periods_source`,
2 in `..._periods_source`) — the dedup variants; check which one a report actually wants
rather than defaulting to the plain column.

`search`'s `MultiTableJoinBuilder` then emits aliased JOINs per field's real table. Three
tables get **LEFT** JOINs because they don't contain every loan:
`loan_history_by_periods_source`, `collateralparentview_source`,
`collateral_tranche_view_source`. Inner-joining those in a hand-written query silently
drops rows.

## Recipe — find a field across the whole set (two steps, not a join)

Redshift **refuses** to join `ama_tables` (a real table) against `information_schema` —
`ERROR: Specified types or functions (one per INFO message) not supported on Redshift
tables`. So read the set first, then loop:

```bash
Q=~/.claude/skills/ama-postgres-access/scripts/rs-query.sh
mapfile -t TABLES < <(bash $Q "select redshift_table_name from public.ama_tables where multi_table_set_name='loan'")
for t in "${TABLES[@]}"; do
  bash $Q "select '$t'||': '||column_name||' :: '||data_type from information_schema.columns
           where table_schema='public' and table_name='$t' and column_name like '%tpo%'" < /dev/null
done
```

**Why `mapfile` + `< /dev/null`:** piping the table list into `while read` lets the
inner `bash $Q` swallow the loop's stdin — the loop dies after one iteration, prints
nothing, exit 0, no error. `mapfile` avoids the pipeline; `< /dev/null` makes the inner
call incapable of eating stdin either way.

Expect ~10s per call, so a 9-table sweep is ~90s — background it rather than reading the
delay as a hang.

**Zero rows + exit 0 is the failure mode to distrust here.** A stray `\r` in a chained
value (`table_name='foo\r'`) matches no row and Redshift reports no error — `rs-query.sh`
strips the CRLF this environment's jq emits, but if a chained query returns nothing,
check for `\r` before believing the data.

## Recipe — enumerate a field's possible values

```bash
bash ~/.claude/skills/ama-postgres-access/scripts/rs-query.sh \
  "select coalesce(loanperiodic_tpo,'<NULL>'), count(*)::varchar
   from public.<resolved table> group by 1 order by 2 desc limit 20"
```

Real result (Channel): `Retail` 79.7M, `Correspondent` 39.6M, `Broker` 18.6M, `Unknown`
11.9M, `Not Specified` 4.5M, `TPO` 398k, `Not TPO` 257k. Note `TPO`/`Not TPO` coexist
with `Retail`/`Broker` — values are messier than the label implies, so enumerate, don't
assume.

**Always keep the `limit`, never `select *`** — every scan hits ~155M rows on a cluster
shared with Prod.

**The data dictionaries' prose is NOT authoritative for a field's enum values** —
`R__Add_Data_Dictionary.sql`'s numbered "Available values:" lists drift from the column
(seen: a documented value absent from the data, and a real value the prose never mentions).
Enumerate the column; treat the prose as a hint only.

## Recipe — measure a month-over-month shift in a per-loan field

**PAIR ON `loan_id`. An unpaired aggregate understates the real shift.** Loans enter and
leave between periods/snapshots, and that composition churn dilutes the delta.

Measured, GNM remterm Jun→Jul 2026 (the Ginnie scheduled-UPB basis change):
- unpaired `sum(remterm*current_rpb)/sum(current_rpb)` per period → GNM excess over
  FNM/FHL looked like **~0.3 months**
- paired, self-join on `loan_id`, 17,696 GNM loans → **−1.92 vs −0.92/−0.99**

Understated by roughly two thirds. Pattern:

```sql
from loanhistorybyperiods_<snap> j
join loanhistorybyperiods_<snap> n on n.loan_id=j.loan_id and n.period='<prior>'
where j.period='<later>'
```

Always carry FNM/FHL as controls — an agency-specific change is only visible against
agencies that didn't change.

**Redshift `avg()` on an integer column TRUNCATES.** `avg(datediff(month,...))` returned
`1` while 81.5% of rows were `2`. Cast (`cast(x as float8)`) or compute fractions with
`sum(case when ... then 1.0 else 0.0 end)/count(*)`.

**Non-ASCII values now come back verbatim** — `rs-query.sh` exports `PYTHONUTF8=1`
(previously they mangled to `?`/replacement bytes; en-dash `–` is common in these
descriptions). If a value still looks corrupt, identify the char with
`ascii(substring(col from <n> for 1))` and match it via `like 'prefix%suffix'` to keep
the literal out of migration files.

## Query-writing constraints

- **Redshift on an ancient PG dialect** — reports `PostgreSQL 8.0.2 ... Redshift
  1.0.377293`. No modern PG conveniences; cast explicitly (`count(*)::varchar`).
- **Catalog access is partial for the read-only users.** `svv_table_info` →
  `ERROR: permission denied for relation svv_table_info`, so dist/sort-key introspection
  isn't available — don't plan around it. `information_schema.*` and `pg_tables`/`pg_views`
  work. `information_schema.views.view_definition` returns `<NULL>`; use `pg_views.definition`.
- **Two external schemas**: `dynamic_cohorts` (federated query into the `dynamiccohorts`
  **Aurora RDS** cluster, via `SECRET_ARN` + `hs-redshift-role`) and `waybackwhen_spectrum`
  (S3/Glue). Cross-schema joins reach outside Redshift — expect different performance.

## The code that does this for real

- `fieldtablemapper` repo — `Domain/Services/FieldTableMappingService.cs` (field->table +
  duplicate tiebreak), `TableService.cs` (reads `ama_tables`, excludes inaccessible ones).
- `search` repo — `Builders/MultiTable/MultiTableJoinBuilder.cs` (aliased/LEFT joins via
  `IFieldTableMapperClient`), `TableNameService` (Trap 3's special case),
  `AggregationDatabaseTableService`, `AggregationDatabasePossibleValueService`,
  `Field.GetTableName`/`DenormaliseFieldName`, `MetadataDapperRequestBuilder`
  (`aggregation_metadata` read).
- Template side: [[REPORT-TEMPLATES.md]].
