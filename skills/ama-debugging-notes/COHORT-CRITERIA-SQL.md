# Dynamic-cohort criteria that build invalid Redshift SQL

Two confirmed classes, both from `cohortdata` asking `search` to build a cohort's loan
selection (PROJ-14563 → `search` develop `a5421070`, PROJ-14658 → `018e10a6`,
both 2026-09-22).

**Premise — stated here because nothing else records it.** `cohortdata` calls `search`'s
`search/build-sql/compressed` (or `.../cmo-cohort`) and keeps only the FROM and WHERE of
the SQL that comes back, as `LoanSelection.FromStatement`/`WhereStatement`. The SELECT and
any GROUP BY are discarded. Which service calls which:
[[ama-architecture-notes]] `COHORT-SERVICES.md` — it documents the call, not this
FROM+WHERE-only consumption.

## 1. A cohort criterion must be a PER-ROW predicate — aggregates are structurally impossible

Report templates define columns as aggregate SQL (`SqlTemplate`), e.g. Last Moneyness =
`round(avg(<table>.last_moneyness_unique) / 0.125) * 0.125`. A report can group; a cohort
cannot — its output is a WHERE clause, and an aggregate in WHERE is invalid SQL, so
Redshift rejects it. Before the fix the criterion also reached SQL as the bare normalised
name (`template_last_moneyness = 0.375`), a column that exists nowhere.

Fix shape: `CohortLoanSelectionTemplateCriteriaVisitor` — only when
`ReportTemplateName == "cohort-data-mapping"`, resolve a `template_`-prefixed criterion
FieldName to its template, unwrap ONE outer aggregate (`avg|sum|min|max`, balanced-paren
scan, leading `distinct` stripped), emit the per-row expression, clear `IsDerivedCriteria`.
`count`/`listagg`/`median`/`percentile`/`stddev`/`var` cannot be unwrapped at all and throw.

Read before touching cohort criteria, `SqlTemplate` columns, or `CriteriaStrategyService` —
and any new SqlTemplate whose expression is an aggregate is unusable as a cohort criterion
until that aggregate has a per-row form.

**NOT covered**: the `dc__` dynamic-column / custom-band path (PROJ-14564). The visitor
matches `template_` only, so a custom band still fails the same way.

## 2. An unrecognised `Metadata.FieldType` NAME silently becomes String → `LOWER(<boolean>)`

Generic, not cohort-specific. `SearchFieldMetadataBuilder.GetTypeFromName` falls back to
`FieldType.String` for any name it does not know, and `UserQueryBuilderService` read the
numeric `Metadata.Type` for criteria while already trusting the NAME for fields. String
sends the criterion through `EqualsOperator`'s string branch, which emits
`LOWER(<field>) = 'true'` — Redshift 42883, `function lower(boolean) does not exist`.

Confirmed instance: template field type `NullableBoolean` (TBA Eligibility). Fixed in BOTH
places — the cache metadata builder maps `NullableBoolean` → `Boolean`, and the criteria
path honours the name, matching what `GetFieldType` already did for fields.

Rule for the next new template field type: adding a name to a template is not enough. Check
`Search.Cache`'s name → `FieldType` map, or it lands as String and every operator treats the
column as text.
