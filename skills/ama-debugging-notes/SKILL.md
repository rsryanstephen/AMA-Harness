---
name: ama-debugging-notes
description: Known, reoccurring BUG-CLASS patterns for the AMA_APP fleet. Use when debugging an error, crash or odd behaviour in shared, search, cohortdata, cohortreports, fieldtablemapper, manage or exporterplus (invalid cohort/SqlTemplate SQL, DI/connection-type crash, log redaction, ag-grid, reactive-forms validity, CI test-leg failure, stitched CPRn vs CPR1, blank measure cells) — check BEFORE re-diagnosing. ALSO before adding a defensive term to a condition, BEFORE changing a shared builder/base class/library output others inherit (regression check), and BEFORE writing or re-applying a DB migration, backfill, datafix or bulk update (IMigration, _migrations, UpdateMany, UPDATE…SET).
---

# AMA debugging notes

Known bug-CLASS patterns only (already-diagnosed root causes likely to reoccur) — NOT
architecture/structure facts, those live in [[ama-architecture-notes]]. Index — read only
the file(s) relevant to the current task, not all of them.

- **[DI-EAGER-CONSTRUCTION.md](DI-EAGER-CONSTRUCTION.md)** — `shared`/`search`/`fieldtablemapper`: why an unrelated, unconfigured connection type can crash a consumer app. Read this before touching connection-type registration or DI wiring in any consumer of `YourCompany.Product.Shared`.
- **[REDACTION-AND-LOGGING.md](REDACTION-AND-LOGGING.md)** — `shared`/`manage`: input sanitization exemption model, a known OOM-causing logging class, branch/version-verification gotchas.
- **[EXPORTERPLUS-FRONTEND.md](EXPORTERPLUS-FRONTEND.md)** — `exporterplus`: ag-grid v26 API surface gotchas, an Angular reactive-forms validity-caching trap.
- **[UNVERIFIED-GUARD-ASSUMPTIONS.md](UNVERIFIED-GUARD-ASSUMPTIONS.md)** — `shared-http`/`search`: `ResponseData.Success` is assigned NOWHERE, so `!response.Success` in a guard is always true and kills the path it "protects" (broke non-admin `client-loan-data` on prod, 7 weeks). Read before adding any extra term to an existing condition, and before calling an org-lookup failure a data problem.
- **[SHARED-CHOKEPOINT-CHANGES.md](SHARED-CHOKEPOINT-CHANGES.md)** — any repo: a change at a convergence point (select builder, base class, shared lib, template, mapper) valid in the shape tested, broken in a consumer that re-scopes/re-wraps/splits its output -- OR code that parses/rewrites input N producers feed it, assuming one shape (producer census, all-producers test). "It inherits the change" is a test case, not a conclusion. Read BEFORE changing a shared builder/library output, writing its regression note, or fixing a defect traced to an earlier change. Has the `rs-explain-shapes.sh` EXPLAIN sweep.
- **[PERSISTED-DATA-REWRITES.md](PERSISTED-DATA-REWRITES.md)** — any repo: a migration/backfill/datafix/bulk update is a chokepoint change on DATA — each step correct alone, the SEQUENCE wrong (1.0.10 re-split `value` into `rawValue` after 1.0.8 had formatted it; Spark builder rejected the cohort for six weeks, PROJ-15274 → 15835). Six checks: whole-sequence test, real-shape fixture census, per-doc dry-run diff, fleet-wide reader census, "test asserts the overwrite" red flag, rollback snapshot. Read BEFORE writing or re-applying one; nudged post-commit by `persisted-data-rewrite-nudge.sh`.
- **[COHORT-CRITERIA-SQL.md](COHORT-CRITERIA-SQL.md)** — `cohortdata`/`search`: cohort loan-selection SQL is consumed FROM+WHERE only, so a criterion must be a per-row predicate — an aggregate `SqlTemplate` column can't be one; and an unknown `Metadata.FieldType` NAME falls back to String → `LOWER(<boolean>)`, Redshift 42883. Read before touching cohort criteria, SqlTemplate columns, or adding a template field type.
- **Stitched CPRn contradicts CPR1 / top row / detail rows** — `search`/`AMA_ETL`: not a population or definition question first. The cprn table copies one projected balance onto every segment row, `search` divides by `rows_per_loan`, correct only unstitched → sellers read low, acquirers high (UWM CPR3 4.74 as coded vs ~9.7 month-valid, CPR1 8.15). Facts, tickets, fix rule: [[ama-architecture-notes]]'s `CPRN-STITCH-ARITHMETIC.md`; human version `developer-docs/docs/servicer-stitch.md`. Undated rows (both transfer dates NULL) are name rows, not segments — they hold nothing (PHH's 0.60, PROJ-15447); Nationstar is a dead book since its 2026 Rocket rename (15446). Neither is a data gap.
- **Measure cells blank / NULL on a finely-grouped report** — `search`: usually NOT a bug. `SingleLoanMaskBuilder` nulls every measure on a row covering exactly one loan (contractual, <one entry per line; this element only declares the type> — PROJ-15416). `# Loans`, group-bys, ungrouped queries and pool-set reports are exempt by design. Also expect NULL-sorting to change which rows a page returns. Before debugging a blank cell, check the row's loan count: [[ama-architecture-notes]]'s `SEARCH-SQL-PIPELINE.md` "Single-loan mask".
- **[CI-PIPELINES.md](CI-PIPELINES.md)** — any lib repo: multi-target test leg aborting in Bitbucket CI ("You must install or update .NET"), green test report on a FAILED step — mutated ECR pipeline image tag, one-line fix.

(Repo-naming/classification conventions live in [[ama-architecture-notes]]'s
`FLEET-CONVENTIONS.md`; git/SSH network fixes live in [[commit-ticket]] — neither is an
AMA_APP code bug, so neither belongs in this file.)

## Adding to this — see [[commit-ticket]]'s "Leave context for future agents" section

Architecture/repo-structure facts: add liberally. Bug-specific findings: only for a
genuinely generic, likely-to-reoccur class — always confirm with the user first, and
say why it's generic, not a one-off. A still-open bug found along the way is a Jira
ticket, not a note here.
