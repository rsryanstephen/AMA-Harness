# Guard added on an unverified assumption — the always-true term

Bug class: a "defensive" term added to a live `if`, testing a flag nobody assigns. Term is
a constant. Condition inverts. Feature dies silently for the paths that used to work.

Generic rule + the pre-flight checklist: [[karpathy-guidelines]] §3. This file is the
confirmed AMA instance — read it before adding ANY `!response.X ||` to a working guard.

## `ResponseData.Success` is ALWAYS false — fleet-wide, every version

`YourCompany.Product.Shared.Http.Models.ResponseData<T>`:

```csharp
public bool Success { get; set; }   // auto-property, NEVER assigned
```

`HttpClientWrapper.ReadResponse<T>` sets `Data` on 2xx, `ErrorMessage` on throw. Never
`Success`. Confirmed across full history of `shared-http` (`git log -S".Success ="` → zero
hits), local master == origin/master. Only ONE `ResponseData` exists fleet-wide (plus an
unrelated `resultsprocessor` copy).

So:
- `!response.Success` → **always true**. Any guard containing it always throws/short-circuits.
- Real success signal = `response.Data != null`. Real failure detail = `response.ErrorMessage`
  (holds the status/exception text — `ReadResponse` swallows everything into it).
- Correct convention, predating the bug:
  `NonAdminClientLoanPossibleValuesSqlBuilder.GetOrganization()` returns `response.Data`, and
  its test mocks `new ResponseData<Organization> { Data = ... }` with NO `Success`. Copy that.

## What it broke (PROJ-15226 / -15254)

`search` commit `d8f84c45` (2026-07-28, hotfix/128.0.1 → master) null-guarded a real NRE in
`ClientLoanDataUserQueryVisitor` — correct — but ALSO added `!response.Success ||`:

```csharp
if (!response.Success || organization == null || string.IsNullOrEmpty(organization.Name))
    throw new ApplicationException($"The name of the Organization with id '{organizationId}' could not be found. ...");
```

Effect on production from the 2026-08-27 deploy: EVERY non-admin, non-HMAC
`/search/client-loan-data` request threw. Admin + internal-HMAC callers return early, so the
report kept "working" for the people most likely to test it. Undetected 7 weeks.

`34d81187` (PROJ-15254, 2026-09-09, develop-only) copied the same term into
`NonAdminClientLoanPossibleValuesCacheKeyGenerator` + `NonAdminClientLoanPossibleValuesSqlBuilder`,
citing 15226 as precedent. **Three sites carry it on develop, one on master.**

## Why CI never caught it — the self-validating mock

`ClientLoanDataUserQueryVisitorTests.GetClient` builds
`new ResponseData<Organization> { Success = success, Data = data }` — hand-setting a field
production never sets. The success-path test passes `success: true`, a state the real wrapper
cannot produce. The one test whose job was to prove the happy path still worked instead
encoded the false premise and stayed green.

## Recognising it live

- Graylog: `"The name of the Organization with id"` on `product-service-search-api`.
- Confirm the success path RAN, positively — don't infer it from an absence. On success the
  visitor injects `clientloan_mapping_source.client = '<the org's name>'`, so search the
  window for the **org name literal** and check it lands on an `ExecuteAsync::SQL` /
  `Partial SQL Query Built` line: `environment:<env> AND application:product-service-search-api AND "<OrgName>"`.
  The request body never contains the org name (the server adds it), so a hit is proof the
  guard passed; no hit on a request you just made is proof it did not.
- **Do NOT use `full_message:"clientloan_mapping_source.client"` returning 0 as the signal.**
  Tried it 2026-09-14 and it reads as damning on any env: `full_message` is not populated for
  these SQL lines at all in QA, and the production "control" hits for the bare table name were
  error payloads (the logged `Request Body:` embeds field names), not SQL. Absence there
  measures the logging pipeline, not the guard.
- Rule out bad data before blaming code: `manage` DB (`production_v4_exporter_admin_db`,
  QA `qa_v2_exporter_admin_db`), lowercase snake_case table —
  `select uuid, name, enabled from organization where uuid = '<guid>'`.
- The test identity must be NON-admin, non-HMAC or the check is vacuous — both return before
  the guard. Prove it from the token's `cognito:groups`, and confirm an `Admin` group actually
  exists in that pool so a missing match means "not an admin", not "wrong role name".
