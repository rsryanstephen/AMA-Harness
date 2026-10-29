# Cohort-report bonds — how a bond becomes a grid row, and how to debug when it doesn't

**Not MCF-only since 2026-09-04 (PROJ-14876).** Bonds work on a PLAIN cohort report
(`cohort-report`) too; ADD BOND is no longer gated on `CohortReportType.Mcf` (that enum and
its whole gate chain are gone from exporterplus). The pipeline below is unchanged — the
visitor always keyed off `IsCohortReport`, not MCF.

One extra rule for the non-MCF case: `CohortReportUserQueryVisitor` adds a
`cohort_mapping_source.cohort_id` grouping to every cohort report EXCEPT MCF, and it runs
BEFORE the union visitors — so a bond arm inherited that column, then `RemoveCohortIds`
made the from/join factories drop the cohort tables, leaving a dangling alias (42P01, one
per bond arm). Fixed by suppressing cohort_id whenever the query carries bond criteria,
matching what PROJ-14444 already did for MCF. **Any new per-arm column must survive
`RemoveCohortIds`, or it dangles the same way** — and UNION arms render independently
(`AggregationDatabaseSqlQueryBuilder.Build`) with NO column reconciliation, so every arm
must end up the same width.

Established live 2026-08-19 (PROJ-15321). A "bond" on an MCF cohort report is NOT a
cohort: it's a report-level criterion on the report document
(`cohortreport.criteria[] = {field: "collateral_tranche_view_source.cusip", operator,
value: ["<cusip>"], fieldLabel, isBond: true}`).

## The pipeline

1. **exporterplus** hydrates bond criteria from `report.criteria` + the `bond-fields`
   template (`getBondCriteria`), pushes them into `gridState.criteria`; every `/search/
   <template>` POST carries them in `Criteria[]` with `field.Metadata.isBond: true`
   (camelCase key beside PascalCase siblings — fine, search deserializes Newtonsoft,
   case-insensitive).
2. **search** maps `Field.Metadata.IsBond` → `UserQueryCriteria.IsBond`
   (`UserQueryBuilderService.cs:75`), then `CohortReportBondVisitor` (union visitor,
   Autofac assembly-scan registered) clones the query per distinct bond field, REPLACES
   the `cohort_name_mapping_source.name` grouping with the bond field, drops CohortIds
   on the bond arms, and UNIONs them onto the cohort query. Bond rows surface in the
   same "Cohort" column, labeled with the criterion's `fieldLabel`
   ("Tranche CUSIP is 3137FNR36").
3. Bond arm SQL joins tranche→loans via the CMO shape (see
   `search/...CurveAnalyser.Tests/Expectations/CmoCte.sql`):
   `loanbyservicertransferview ⋈ (collateralparentview ⋈ collateraltrancheview ON
   issuemnemonic=issuemnem AND issuecollgroup=collgroup) ON
   secmnemonic=security_securitymnemonic AND is_unique_loan`.

## Debugging: no bond row?

Work the layers in this order — each has a cheap discriminator:

1. **Request**: does every `/search/...` POST carry the bond criterion?
   (PROJ-15321 fixed the race that dropped it; assert-bond-in-requests pattern.)
2. **Visitor**: POST the body with `CohortIds: []` (bond-only). Visitor ran → 200 with
   empty/real results (cohort grouping replaced, no mappings needed). Visitor did NOT
   run → 500 `"No cohort mappings found"` (query still groups by cohort name).
   **Do NOT judge the visitor from `/search/<template>/hql`** — that endpoint does not
   reflect the live union pipeline on master (returned union-less SQL while the live
   path unioned fine; cost an hour chasing a phantom master-vs-develop delta).
3. **Data**: picker values ≠ joinable data. The tranche VALUE picker reads the tranche
   view (`AggregationDatabasePossibleValueService`); a row needs the full CMO join to
   loans. Testing envs (QA/Staging) lack data for OLDER cohorts/tranches — ETL doesn't
   backfill (user-confirmed). Find data-carrying tranches on the env directly
   ([[ama-postgres-access]] `rs-query.sh`, resolve dated tables via
   `aggregation_metadata` / newest `collateraltrancheview_*`):

   ```sql
   WITH cmo AS (
     SELECT DISTINCT p.secmnemonic, t.cusip
     FROM collateralparentview_v8_<newest> p
     JOIN collateraltrancheview_v8_<newest> t
       ON p.issuemnemonic=t.issuemnem AND p.issuecollgroup=t.collgroup)
   SELECT cmo.cusip, count(*) FROM loanbyservicertransferview_v8_<newest> l
   JOIN cmo ON cmo.secmnemonic=l.security_securitymnemonic AND l.is_unique_loan=true
   GROUP BY cmo.cusip ORDER BY 2 DESC LIMIT 12;
   ```
   (2026-09-04 QA, re-run: MBS CUSIP `36179WBX5` → 151k loans, `36179WDQ8` → 141k;
   Tranche CUSIP `3136BTD59` → 4.17M, `3136BWAB2` → 4.10M. Beware `31281BMQ0` /
   `31281BMH0` — real but only 10 and 8 loans, so a near-empty row is a weak signal.
   Earlier 2026-08-19 staging: `3137FNR36` → 1.14M loans; the `3128HU*` tranches → zero, which
   is why they never rendered. An empty arm contributes NOTHING — no placeholder row;
   that UX gap is PROJ-15323.)
4. A bond with data renders as MULTIPLE rows when it spans grouping values (one per
   Agency × Coupon Type combination) — 2 rows for one bond is correct, not a bug.

## Related

- Bond UI plumbing in exporterplus (chips, customize, save round-trip):
  `cohort-report-aggregation.component.ts`, `bonds$` on gridState,
  `checkAndFillDiscrepancies` reconciliation band-aid.
- Driving the ADD BOND dialog headless: [[ama-ui-verify]]
  `references/chrome-driving-pitfalls.md` (a11y refs, mat-select-search typing,
  200-result cap).
