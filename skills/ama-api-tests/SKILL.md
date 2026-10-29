---
name: ama-api-tests
description: The AMA_APP API test suite -- xUnit integration tests hitting real deployed envs (QA/Staging), not unit tests. Use when user says "API tests" (no other qualifier), links a <repository>-api-testing pipeline, or asks to check/fix/run the API test suite.
---

# AMA API test suite

"API tests" (bare, no service named) = this repo. Not obvious from name alone -- gap
found 2026-08-13, user had to paste the Bitbucket URL.

- Local clone: `api-testing/` (repo root `AMA_APP/api-testing`).
- Bitbucket: `yourorg/<repository>-api-testing`.
- **One branch only: `master`.** No develop/feature branches, no PRs (solo repo, see
  `commit-ticket` skill's solo-no-PRs rule) -- runs against every env off the same code.
- xUnit fixtures under `Tests/`, drive real HTTP calls via `Workflows/` ->
  `Services/*Service.cs` -> deployed API. Not mocked -- a fixture failure can mean the
  target env's API genuinely changed behavior (see PROJ-15261 fix, below).

## Custom pipeline selectors -- not branch-triggered

Pipeline only runs on manual/custom trigger, selector = target env name:

```bash
curl -sS -u "<email>:$BITBUCKET_API_KEY" -X POST -H "Content-Type: application/json" \
  "https://api.bitbucket.org/2.0/repositories/yourorg/<repository>-api-testing/pipelines/" \
  -d '{"target":{"ref_type":"branch","ref_name":"master","type":"pipeline_ref_target","selector":{"type":"custom","pattern":"staging"}}}'
```
Selectors confirmed live: `staging`, `qa`. Swap `pattern` for other envs if added later.
Auth/pipeline-log-pull mechanics: see `ama-bitbucket-api` skill (Basic auth gotcha, `-L`
redirect gotcha for step logs) -- don't restate here.

## Reading a result

`POST .../pipelines/` returns `build_number`/`uuid` immediately (pipeline starts
`PENDING`/`PARSING`) -- poll `GET .../pipelines/{uuid}` until `state.name == COMPLETED`,
then check `state.result.name` (`SUCCESSFUL`/`FAILED`). Step log has the xUnit summary
line: `grep -E "Failed!|Passed:" step.log`.

## Known gotcha: local `dotnet build` fails with CS0579 duplicate AssemblyInfo

`DebugTools/LocalSearchDebug/` is untracked local scratch (a nested net10 csproj, 0 files
in `git ls-files DebugTools`) that CI never sees. If it (or a past build of it) has left an
`obj/`/`bin/` behind, the outer project's default `**/*.cs` glob sweeps in its *generated*
`obj/Debug/net10.0/*AssemblyInfo.cs` too -- same attribute names, different values --
causing `CS0579: Duplicate 'AssemblyXxxAttribute'` across ~8 attributes plus
`TargetFrameworkAttribute`, even though nothing in tracked source looks wrong. Renaming
`DebugTools` out of the way is NOT enough by itself -- the rename still globs into the
outer build. Fix: delete `DebugTools/LocalSearchDebug/obj` and `bin` (or move the whole
`DebugTools` dir out of the tree entirely) before `dotnet build`, then move/restore it back
after -- it isn't yours to delete, only its build output.

## Known gotcha: a validator/behavior change elsewhere breaks this suite silently-ish

`Services/*Service.cs` methods build request payloads that match the target API's
CURRENT contract. If a service repo tightens validation (e.g. querybuilder's
DynamicColumnConditionValidator, PROJ-15261, rejecting a `{}` condition that used
to be accepted), this suite's stale payload now gets a 400 -- and
`Helpers/JsonHelper.Deserialize` doesn't check status codes, so the 400's body gets
force-cast into the expected response type and throws a confusing
`JsonSerializationException` instead of a readable assertion failure. Symptom: many
fixtures for ONE feature area all fail with the same deserialization exception, error
text embeds a `"... failed. <validation message>"` string. Fix at the call site
(`Services/*Service.cs`), not the deserializer. Negative tests assert the raw 400 instead
(`*Response` service variants + `ShouldBeRejected`, PROJ-15826) -- querybuilder's
rejection body is a plain string now, not a `DynamicColumn`.

## Coverage = query SHAPES, not templates (PROJ-15825)

`api-testing/COVERAGE.md` = shape -> test table + open gaps. Adding a test:
- Request body COPIED from the real page on Staging, never hand-written. Capture recipe:
  harness `ama-ui-verify` + a `/search/` request recorder; lazy column groups (MCF quartiles,
  `l=cteSource`) fire only after scrolling the grid right, and answer in ~2 min.
- Hidden-by-default columns (`tobm_*` trend) never fire from a bare template page -- need a
  saved report that shows them.
- Slow shape -> `SearchService.DirectSearchClient` (`SearchClientUri`, ALB). `ExporterClientUri`
  = CloudFront, 504 after ~40s. Old skip "gateway timeouts on staging" = likely same cause.
- Cohort-backed tests: persistent find-or-create fixture by name (`McfHeaderExportReport`),
  never create+delete per run (Redshift space, why cohort tests are skipped since 2024-04).
- Search client gets `Results.Results[].Points[]`; browser gets flat rows -- parse accordingly.
  Client `FieldName` is DOTTED (`count_distinct.table.col`): server swaps alias `__` -> `.`
  for it; browser keys + name builders keep `__`. Match via `SearchComponent.ShapeRows`
  (normalises to `__`), never a dotted literal from a capture (15829: 3 tests matched nothing).
- Run: `run-pipeline.sh api-testing staging_no_publish` (no Slack post); whole suite ~4-6 min.
- Export content (PROJ-15829): capture the Export dialog POST (`button[title="Export Report"]`,
  `#export-report-confirm`), keep both `"Query":{}` + lowercase `query` (real one, Newtonsoft binds it).
  Download = S3 `<env>-v1-results-processor/<ExportFileLocation>` w/ Cognito identity-pool creds
  (`ExportFileService`), as web app does. NOT `resultsprocessor/download` -- 404s after first export.
  `staging_export_content` = `Category=ExportContent`, ~2 min. Channel export done in ~7s.
- Unedited template = QueryType 1 = search-cached, stale on Staging (~3% fewer loans than export).
  Never a reference for an export; compare only QueryType 0 (criterion edited) bodies.
- Most `Export_*` tests post + delete at once: green = request accepted, not file produced.
- Ownership/authz test (PROJ-15890) -> second user `automation_user_b` via `SecondUser.Ensure`
  (Tier3500, NO UserManagement/Admin -- either bypasses ownership; pw = `AMA_PASSWORD`; QA/Staging only).
  `automation_admin` is Admin = false PASS. Selectors `qa_ownership`/`staging_ownership`.
- Test for a still-open bug -> `Category=KnownBug` + `Trait("KnownBug","PROJ-N")`, out of
  FullRegression; never `Skip=` (skip ratchet). Green after fix -> move to FullRegression.
