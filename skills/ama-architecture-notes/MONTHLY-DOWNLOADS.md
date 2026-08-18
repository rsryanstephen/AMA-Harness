# Monthly downloads / report transfers — saved reports exported to client SFTP

The one consumer of `UserReport.Query` + `UserReport.TemplateFields` (see
[REPORT-TEMPLATES.md](REPORT-TEMPLATES.md) "UserReport `Report` vs `Query`"). Repos:
`export` (lambda + API service), `cacheupdate-infrastructure` (trigger plumbing),
`exportproducer` (file write).

## Scope boundary — Monthly Downloads is NOT the only export path

Monthly Downloads covers **saved reports only** (`UserReport`, Postgres — the reports-api DB).
**Cohort reports are not in it at all**: they live in **Mongo** and reach clients via
**Requested Downloads** (`export` repo,
`YourCompany.Product.Export.Domain/Services/RequestedDownloads/` — `CohortReportsService`
fetches them from cohortreports' `/cohort/report/internal/{id}`, JWT-authed, `RequestedDownloads`
or `Admin` role; see that folder's `Usage Docs/RequestedDownloads Usage.md`). A missing or wrong
cohort export is a Requested Downloads question — don't debug it here, and don't go looking for
cohort data in the Postgres DBs.

## Trigger chain

admin `/update` "TRIGGER REPORT TRANSFERS" → `PUT {cacheupdate-apigw}/cache/update?cache-type=reportTransfers`
→ SQS `<env>-v1-cacheupdate-waiting` → Start.Dequeue lambda → state machine
`<env>-v1-cacheupdate-statemachine` → lambda `<env>-v1-report-transfers` (confirmed live
names, all three envs).

- State machine Choice matches `$.CacheType` `StringEquals "ReportTransfers"` — cache-update
  messages serialize enums as STRINGS (`StringEnumConverter`). An integer `CacheType` falls
  through to the FieldTableMapper branch silently.
- `cache-update-shared`'s `Environment` enum values are lowercase (`production`, `qa`, …).
- ReportTransfers branch has no Retry/Catch/timeout — plain lambda invoke, then Succeed.

## What a run does

1. Lambda `YourCompany.Product.ReportTransfers.Lambda`: GET reports `/report/monthly-downloads`
   (every non-deleted `MonthlyDownloadsActivated=true` report, HMAC-authed) → per report builds
   `ScheduleExportRequest` (throws if `TemplateFields` empty, `Query` null, or `Query.Type`
   null) → org per user via manage → POST export `/export/monthly-downloads`.
   Lambda overwrites `message.Environment` from its own env var — caller's value ignored.
2. Export API `MonthlyDownloadsExportService`: schedules per user, **serially**, polling
   `ExportStatus` every 60s per user → full run is slow. Per user: in-app notification
   "Monthly SFTP Downloads Ready" (to the report OWNER only); per org: report-transfers
   webhook. Internal completion SQS message closes the cacheupdate step — not a notification,
   never suppressed.
3. exportproducer `FileUploadJob` writes
   `s3://yourproduct-client-sftp-accounts/<org-uuid>/monthly-downloads/<username>/<MMM yyyy>/<ReportName> - <MMM yyyy>.zip`
   — **`.zip` not `.csv`**; same key overwritten on re-run (idempotent destination).
   Clients pull via SFTP under their org uuid.

## Targeted run (report-id filter + notification suppression)

Since PROJ-15286 (`hotfix/128.0.1`, export repo): invoke the lambda directly —

```bash
aws lambda invoke --function-name <env>-v1-report-transfers --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"CorrelationId":"<guid>","Task":"Cache Update","ReportIds":["<uuid>"],"SuppressNotifications":true}' out.json
```

- Omitting both new fields = the normal full run (state machine payload does exactly that).
- Needs BOTH deployables at that version: lambda sends `SuppressNotifications`, export API
  honours it. Old API silently drops the flag → notifications fire (fails open).
- No filter at all = fleet-wide: every org, every flagged report, one notification per owner.
- Filtered-run proof: lambda logs "Report id filter matched N of M fetched reports".

## Locating a client's/user's files in the bucket

Bucket `yourproduct-client-sftp-accounts` (us-east-1). Root = mix of org UUIDs
(monthly-downloads orgs) + named client folders (ClientOne, ClientTwo, … — other transfer
types). Per-org: `<org-uuid>/monthly-downloads/<username>/<MMM yyyy>/<ReportName> - <MMM yyyy>.zip`;
some orgs also have older `<org-uuid>/downloads/<username>/…`. Usernames are `first.last` —
a nickname may not substring-match (Bob → `robert.smith`), search the full listing:
`aws s3 ls s3://yourproduct-client-sftp-accounts/ --recursive | grep -i <name-variants>`.
`aws s3 ls` timestamps print LOCAL time, not UTC — convert before correlating with deploys/logs.

**Verifying a month's files landed correctly**: diff report set vs previous month's folder,
then unzip + CSV-check each: no rows shorter than header, no all-empty columns, no literal
`_MM_YY` header, and newest CPR column suffix matches the folder month (`Jul 2026` →
`CPR1_07_26`; latest = prior month's suffix ⇒ file was generated BEFORE that month's
column roll — stale, needs the targeted re-run above).

## Newest-month column present but EMPTY — check the agency before debugging

Symptom: exports carry the right window (e.g. newest `CPR1_07_26`) but that one column is
blank, everything older populated. **Split the affected files by agency before assuming a
bug** — confirmed live 2026-08-10: 30/30 Ginnie (`GOV`/`GNM`) reports blank, 19/19
Conventional (`CONV`) populated. Cause was simply that FNM/FHL July data had loaded and GNM
July had not; the two arrive on **different eMBS dates** (see [[ama-embs-reminders]]). Not a
defect, and no code change fixes it — re-run the transfers once that agency's file lands.

Ruled out fast, in this order, before reaching for anything deeper:
- Is the column in the env's `SqlTemplate` table (export DB, `"Column"`, `"IsDeleted"`)? If
  yes it isn't Gotcha 3c.
- Do `Query.SqlTemplateColumns` and `TemplateFields` agree on that month? If yes it isn't
  the column-semantics mismatch below.
- **Decisive test: re-run ONE report that already had that month populated.** Still
  populated ⇒ the pipeline resolves the column fine right now and the blanks are a data-
  availability question, not a query/cache one. Cheap, and it settles the whole thing.

Careful comparing against a report you deliberately EXCLUDED from a re-run — its file is the
older artefact, so identical values prove the data existed *then*, not now. Re-run it to test
current state.

## Column semantics (why an export can be wrong while the UI looks fine)

`TemplateFields` (TEXT column, JSON list of normalised names) = the requested column list;
`Query.SqlTemplateColumns` = what the query can resolve. Export merges them via search's
`BuildUserQuery(query, templateFields)`. Mismatch symptom in the CSV: a header printed as the
raw normalised name (`template_cpr1_MM_YY`) with an empty data column, and/or a resolvable
column silently missing. Fix = keep both fields in step (same month-shift).

## CSV rows shorter than the header

Not transfers-specific — ANY export drops the data cell for a template column absent from
the env's `SqlTemplate` table. See [REPORT-TEMPLATES.md](REPORT-TEMPLATES.md) Gotcha 3c
(symptom, diagnosis, env-metadata-lag root cause, `main`-update fix).
