# Testing repos (`testing.md` classification — newer category)

Three repos: `api-testing` (Bitbucket `<repository>-api-testing`), `ui-testing`,
`shared-testing`. `api-testing` DOES run on a real recurring schedule — confirmed via
Bitbucket pipeline history, builds 208/215/216/220/221/222 all show trigger type
SCHEDULE (2026-08-23). Corrected 2026-08-25 (<harnessEpicKey>): the earlier "on-demand
only, no schedules" claim here checked only for a `schedules:` block inside
`bitbucket-pipelines.yml` — Bitbucket's repo-level Settings > Pipelines > Schedules
feature configures a recurring trigger without ever touching the yml, so that check
proved nothing. Don't assume a scheduled trigger will show up in the yml file for ANY
repo — check the pipeline run history's trigger type instead. [[ama-cut-release-branch]]'s
verification stage should still trigger these explicitly rather than assuming a
schedule will cover a specific release window in time.

## `api-testing` — pure API-level tests against real deployed environments

xUnit + `RestSharp`, no mocks, hits real qa/staging/production URLs picked by a required
`TEST_ENVIRONMENT` env var (throws if unset — no silent default). Exercises search,
querybuilder, reports, manage, notification, export, cohort, feedback, fieldtablemapper,
resultsprocessor.

**Known negative-test noise** (see [[ama-graylog-search]]'s `KNOWN-SIGNATURES.md` for the
original 5-pattern list) is bigger than first documented — confirmed present in **10 of
~14 fixtures**, not a handful. Additional confirmed negative-scenario tests beyond the
original list: `Deleting_Organization_Negative_Scenarios`/`Delete_User_Negative_Scenarios`
(manage), `Verify_Invalid_Template`/incorrect-column-description tests (reports),
`Delete_Token_Negative_Scenarios` (notifications), 6 more variants in querybuilder. If a
future session extends `KNOWN-SIGNATURES.md`'s list, check here for the fuller picture
first. One test is permanently disabled: `Querying_Sql_Templates` —
`[Fact(Skip = "getting gateway timeouts on staging")]`.

**Expected runtime ~2 min** (148 tests, confirmed build 206: 1m43s). **>10 min → stop the
run, check logs — something's wrong, don't wait it out.** Threshold assumes current test
count; re-check if the suite grows a lot.

## `ui-testing` — real browser E2E (Selenium, not Playwright/Cypress)

Page-object model against qa/staging via a Bitbucket-service Selenium container (not a
per-test spin-up). Two fixture files are NOT real regression tests — recognize them,
don't trust their pass/fail:
- `FlakyFixture.cs` — a parking lot for tests removed from normal suites pending
  investigation (`//TODO: Delete this class once we've resolved Flaky tests`).
- `DummyFixture.cs`/`EmptyFixture.cs` (class `HotFixFixture`, filename/classname
  mismatch) — literal scratch templates for engineers to paste one-off tests into.

## `shared-testing` — a test-utility library, not a test suite (naming mismatch, note it)

**3-way naming mismatch**: repo dir `shared-testing`, internal namespace
`YourCompany.Playtest.*`, published NuGet package id `Test.Automation.Shared` (what
`api-testing`/`ui-testing` actually reference). Grepping for any one of these three won't
find the others. Ships Selenium abstractions, Cognito SRP auth helper (used by
api-testing/ui-testing to authenticate against real services), fake-data generators, an
ExtentReports wrapper. Its own `.Tests` projects are genuine mocked unit tests of the
library itself — no negative-test noise pattern like the other two.
