# Shared-chokepoint changes — one change, every shape that consumes it

**Class**: change lands at a convergence point (select builder, base class, shared NuGet lib,
SqlTemplate, mapper, middleware, serializer, shared Angular component). Every consumer
"inherits" it — and some consumers RE-SCOPE, RE-WRAP, STRING-SPLIT or RE-ORDER its output. The
change is valid in the shape it was tested in, invalid in a shape nobody ran.

**Two directions, same class.** DOWNSTREAM: consumers re-wrap your output (below). UPSTREAM:
your code parses, rewrites or name-matches INPUT that N other components produce, assuming one
shape for all N. 15416's mask did both: 3 of its 5 follow-ups were upstream (inner CAST `AS`,
guessed `# Loans` alias, comma-joined trend/pivot entries). Not SQL-specific: JSON property
names, cache keys, column/alias names the frontend rebuilds (`buildTrendOfByDateColumnName` must
match the backend alias), CSV/path strings, an Angular `@Input` fed by several hosts.

**Same class on DATA**: a migration/backfill/datafix rewrites a field other code reads, and
sibling steps in the same run feed each other. Sequence test, real-shape census, dry-run diff,
reader census: [[PERSISTED-DATA-REWRITES.md]] (15274 → 15835).

## Inputs you don't own — before writing the transform

0. **Producer census.** Each value the change parses/rewrites/matches by name: list every
   producer (all implementers, DI registrations, callers, hand-written data like SqlTemplate
   rows). Capture ONE REAL output from each — call the real builder, or copy a logged value.
   Naming the producers is not sampling them: a9a7890b's message lists "the fourteen families";
   none was run, and the trend family returned `a AS x, b AS y` in ONE list entry.
0a. **All-producers test.** One test feeds every registered producer's real output through the
   change (resolve them from DI / enumerate implementers; build each the way production does).
   A hand-typed fixture encodes your assumption and passes forever (c26fcee3: fixtures used the
   same wrong alias the code did). Names used as contracts: read the real one, never guess.
0b. **Parsing structured text** (SQL, JSON, CSV, paths): split only at top level (parens,
   brackets, quotes) or use a real parser; "the last ` AS `" / "split on `,`" assume a shape.
0c. **Coverage is over the change's INPUT VARIANTS, not the outer query shape.** A shape sweep
   that is all OK while no trend/pivot column ever ran proved nothing about 15808.
   `rs-explain-shapes.sh` prints `FAMILY` lines for measure kinds the new build never emitted.

**Lesson written in a commit body = lost.** c26fcee3 (09-27) explained why its defects were
not caught; nothing read it, three more follow-ups shipped, and PROJ-15819 finally switched
the mask off in production. Record the generalised lesson in the harness the same turn.
`hooks/shared-input-contract-nudge.sh` fires on both (shared file gains text parsing / interface
change; postmortem wording in a commit body) right after the commit.

## Protocol — before push, again before Ready to Test, again before a hotfix ships

1. **Enumerate consumers by SHAPE, not by caller.** For each consumer: does it wrap the output
   in a new scope (CTE, sub-select, UNION, outer SELECT), split it as text (`" AS "`, `","`,
   `" AND "`), `.Replace` inside it, reference it by alias (GROUP BY/ORDER BY alias), or ship it
   to another runtime (UNLOAD, export, cache)? Each "yes" = a shape to run.
   **"X routes through the builder so it inherits the change" is a TEST CASE, never a conclusion.**
2. **Validate the EMITTED artifact.** The bytes the changed code produces — not hand-written
   SQL "of the same shape", not a mocked collaborator's output. Fixtures copied from real
   logged/production values (real aliases, verbatim templates), never invented.
3. **Run every shape against the real engine.** SQL → `EXPLAIN` (planner-only, any hour):
   `bash ~/.claude/skills/ama-postgres-access/scripts/rs-explain-shapes.sh graylog:<app>:<qa|staging> --build <2.0.0.N> --inventory-hours 336`
   after the build is running + the `main` cache update ran (crawls the report catalogue);
   `dir:<path>` for a golden-SQL corpus. JSON contract → real call per consumer. UI shared
   component → each host page. Regression note cites per-shape evidence (`ok=N fail=0 missing=0`).
4. **Fixing one shape of a chokepoint defect → sweep the rest BEFORE shipping that fix**
   (hotfix included). Same change, same class, other shapes.
5. **2nd follow-up defect traced to one change = stop patching instances; full shape sweep.**

Mechanical backstops: `release-preflight.sh` runs the sweep when the release/hotfix diff
touches SQL-emitting paths (findings deny the Production deploy via
`prod-deploy-preflight-gate.sh`); `octopus-staging-cache-update-reminder.sh` names it on push;
`error-signature-diff.sh` after a prod deploy catches what still escapes.

## Worked example

PROJ-15416 single-loan mask: 5 follow-ups, 4 of 5 planner rejections EXPLAIN catches (mocked
`ISqlSelectBuilder` unit tests missed them); chain ended with PROJ-15819 switching the
mask off in production. Shape table: `ama-architecture-notes/SEARCH-SQL-PIPELINE.md` § "Select list".
