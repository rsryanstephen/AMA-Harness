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
(`Services/*Service.cs`), not the deserializer -- some fixtures (e.g.
`CreateDynamicBandWithNoDescription`) deliberately deserialize a 400 body and assert on
it, so a status-code guard in `JsonHelper` would break those.
