# Persisted-data rewrites — migrations, backfills, datafixes, bulk updates

Reference for [[ama-debugging-notes]]. Read BEFORE writing, re-applying or re-ordering any
code that rewrites stored data (Mongo `IMigration`, SQL migration, backfill script, one-off
datafix, bulk `UpdateMany`/`UPDATE … SET`, cache rewrite). Nudged post-commit by
`hooks/persisted-data-rewrite-nudge.sh`.

Concept: a data rewrite is [[SHARED-CHOKEPOINT-CHANGES.md]] applied to DATA. Every reader of
the rewritten field is a consumer. Every sibling step in the same run is a producer whose
output a later step can destroy. "Each step is idempotent and guarded" says nothing about
the sequence.

## The six checks — evidence in the ticket, not "it should be fine"

1. **Sequence, not units.** Test the WHOLE ordered run (every step above the current
   high-water mark) on ONE fixture set. A later step that writes a field an earlier step
   formatted = mandatory composition case. Reflection-load the steps the same way the runner
   does; never hand-pick.
2. **Real-shape fixtures.** Census the live shapes of every field touched (read-only
   `ama-mongo-access` `docdb-query.sh` / `ama-postgres-access` `pg-connect.sh`): single,
   multi, delimiter-joined, missing, null, legacy encoding. One hand-typed happy shape tests
   the assumption against itself.
3. **Dry-run diff before deploy.** Run against a prod-shaped copy/sample; read the per-document
   BEFORE/AFTER of every write. "N actual writes" in a log is a list to inspect, not a count
   to note.
4. **Consumer census of rewritten fields.** Grep the FLEET (AMA_APP, AMA_ETL,
   yourproduct-spark-jobs), not the owning repo. For each reader: expected shape/type, then run
   or type-check the rewritten value against it.
5. **A test that asserts the overwrite is a red flag.** `rawValue == value` on a field that
   has a formatter → the test enforces the bug.
6. **Rollback artefact.** Snapshot ids + prior values of the affected docs before a prod run
   (scratch file, kept until the ticket closes). Mongo: `_migrations` is a high-water mark —
   re-running one step means deleting its record AND every higher one.
7. **Hotfix carrying a migration = leapfrog risk.** High-water mark → a hotfix migration
   numbered above unreleased develop ones makes the next release SKIP them, silently
   (`Version > max applied`; 3-part ints, no slot between). `git ls-tree origin/master` vs
   `origin/develop` on the migrations dir first. Gap → datafix the few prod docs, ship the
   migration with the release (15835, 2026-10-28: 1.0.16 would have skipped 15388's 1.0.14/15).

## Worked example — PROJ-15274 → PROJ-15835 (cohortreports, release 130.0.0)

Re-apply migrations `_1_0_7`..`_1_0_13`. `_1_0_8` formats year-quarter `rawValue`
(`2023-Q4` → `20234`). `_1_0_10` re-runs `_1_0_4`: splits a `|`-joined `value` and copies the
split DISPLAY values into `rawValue`. Order 1.0.8 → 1.0.10 → one prod cohort's formatted
`rawValue` replaced by display text → Spark `dynamic-cohorts-build` rejects it daily
(`Error parsing values (2023-Q4,…) to the type ShortType`), cohort dropped from the loan
mapping. Six-week gap to detection; nobody read the "4 actual writes" line.

| Check | Would have caught it |
|---|---|
| 1 sequence | yes — 1.0.7→1.0.13 on a `\|`-joined year-quarter doc ends unformatted |
| 2 real shapes | yes — 1 of 23 prod year-quarter cohorts was `\|`-joined; fixtures had none |
| 3 dry-run diff | yes — the 4 writes of 1.0.10 on QA included the clobber |
| 4 consumer census | yes — only reader is the Spark builder; its parser is `ShortType` |
| 5 overwrite assert | yes — `ReapplyMigrationsIntegrationTests.cs` asserted `rawValue == value` |
| 6 rollback | partial — repair needed a hand datafix + a new migration 1.0.15 |

Fix shape: the splitting step formats through the app's own `CriterionRawValueFormatter`;
a forward repair migration (`rawValue != Format(value)` → set) rather than un-flagging
`_migrations`; the sequence test added.

## Related
- One-row datafix recipe (backup → transform → diff → assert, one txn):
  [[ama-postgres-access]] "Single-row datafix". Anything bigger → this file.
- Mongo write hatches + `_migrations` layout: [[ama-mongo-access]].
- cohortreports migration logs reach Graylog only (not CloudWatch):
  `memory/cohortreports-migration-logs-graylog-not-cloudwatch.md`.
