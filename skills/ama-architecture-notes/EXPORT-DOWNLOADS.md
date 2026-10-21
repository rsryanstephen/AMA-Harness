# User-initiated report exports — where the file lands, and how to verify it

The "Export" button in exporterplus. **Claude can verify an export end-to-end unattended**
— drive the grid, trigger the export, pull the zip from S3, diff the CSV against the grid.
Don't hand a "a human needs to run the export and eyeball the columns" back to the user;
that was a real miss. Sibling of [[MONTHLY-DOWNLOADS.md]] — that one is the scheduled
SFTP pipeline, this one is a user clicking Export.

## Two buckets, don't confuse them

| Bucket | Holds | Key shape |
|---|---|---|
| `<env>-v1-results-processor` | **the user-facing download** | `<guid>/<Report Name>.zip` |
| `<env>-v1-results-processor-redshift` | raw Redshift `UNLOAD` parts, intermediate | `export-<exportId>/...` |

`<env>` = `qa`/`staging`/`production`. Verified live 2026-08-18 by listing
`staging-v1-results-processor`: real keys look like
`000549f3-1c35-4175-a76e-b1897cdefe4b/Custom Loan Pool View.zip`.

The zip name is the **report name with invalid filename chars stripped** (not slugified,
not the report id) — `FileStorage.Complete()` in
`resultsprocessor/…Domain/Files/FileStorage.cs`. A report named `Agency Marketshare - test6 - 123 - `
really does land with the trailing spaces/dashes. Match on the guid prefix or
`LastModified`, **not** on a name you predicted.

The Redshift bucket's `UNLOAD TO 's3://<bucket>/export-<exportId>` is built in
`Query/QueryExecutors/UnloadQueryBuilder.cs`. Useful when the download zip never appears
and you need to know whether the query even unloaded.

## Finding the export you just triggered

Exports accumulate for years — `staging-v1-results-processor` held **28,336** objects on
2026-08-18 — so getting "the newest" right matters. Two traps, both hit live:

1. `--max-items N` returns the first N in **key order**, not the newest. A fresh export
   will not be in it (it returned 2021–2024 objects).
2. `--query 'reverse(sort_by(Contents,&LastModified))'` sorts **per page**, not globally,
   because the CLI paginates and applies `--query` to each page. Output looks
   plausibly sorted then jumps backwards mid-list. Confirmed live.

Sort globally in `jq` instead — one call, CLI auto-paginates the JSON:
```bash
MSYS_NO_PATHCONV=1 aws s3api list-objects-v2 --bucket staging-v1-results-processor --output json \
  | jq -r '[.Contents[]] | sort_by(.LastModified) | reverse | .[:5][]
           | "\(.LastModified)\t\(.Size)\t\(.Key)"'
```

Then fetch and unpack:
```bash
MSYS_NO_PATHCONV=1 aws s3 cp "s3://staging-v1-results-processor/<guid>/<Name>.zip" "$TMP/exp.zip"
unzip -o "$TMP/exp.zip" -d "$TMP/exp/"
```

## Two ways to get the exported file

1. **S3 directly** (above) — no browser, no waiting on UI state. Default for verification.
2. **The My Downloads page** (route `/status`, not `/downloads`) in exporterplus — the same
   zip, via `export.service.ts` `download()` → `S3DownloadService.getBySignedUrl` (5-min
   presigned getObject, filename in `response-content-disposition`) → hidden-anchor click,
   browser download manager streams it. PROJ-15402 (2026-09-14) replaced the old
   `getObject().promise()` + `FileSaver.saveAs` path: 30-min XHR timeout + ~2 GB ArrayBuffer
   cap, big zips died at exactly 30:00. `page.waitForEvent('download')` fires for this path
   (Playwright: `acceptDownloads: true`). This is a
   *separate, later* user action from the export dialog, and the only route that exercises
   the app's download path. Use it when the thing under test IS that path (presigned URL,
   permissions, `RequestedDownloads` role) rather than the file's contents. A Playwright run
   here needs `acceptDownloads: true` on the browser context — the scripts below don't set
   it, because they read from S3 instead.

## Per-column export rules ride on INDEXES, not names

No .NET pass over export rows exists — Redshift `UNLOAD`s straight to S3 (`UnloadQueryBuilder`),
exportproducer joins the parts. So a "treat column X specially" rule = resultsprocessor
`CsvColumnService` computes indexes over `GetVisibleTemplateFields(query)` (same space as the
Header), publishes them on the export message, `FilesJoinerJob.WriteLineAsync` applies them.
Precedents: `FormatColumnIndexes`, `ExcludeColumnIndexes*`, `NotApplicableColumnIndexes`
(PROJ-11854). `LineJoiner.SortColumns` forces the joined line into that same order via
`ColumnOrderKeys`; identity keys return early, harmless because High-then-CPR physical order
already matches grid order then. Don't rewrite the SQL instead — CPRn criteria re-emit the
expression in a HAVING CTE, so a literal there breaks filtering/sorting.

**The High/Cpr join is POSITIONAL (`LineJoiner.Zip`), so every grouping column must be in
BOTH queries' ORDER BY** — a tie left unordered is broken arbitrarily per UNLOAD and the two
files pair up the wrong rows. Symptom: CPR columns on the wrong group row, SUM/count columns
right, intermittent from one export to the next (PROJ-15470, Bob's ClientTwo exports:
`DynamicFieldOrderByBuilder` returned "" for export queries sorted by a custom band and the
group-by tail skipped the band as "already ordered"). Diagnose from Graylog's
`BuildQueryForExport::SQL` ORDER BY, or diff `cut -d'|' -f1-N` of the `_High000`/`_Cpr000`
parts in `<env>-v1-results-processor-redshift`. Exports order bands by label text, the grid
by `_order` — a different row order with the same per-row values is NOT this bug.

## Verifying columns and data against the grid

Column **order** is part of the contract, not just column presence — check the CSV header
row's order, don't just assert set membership.

What the grid renders is **identity-independent** (same columns, criteria, data as the
owner) — see [[ama-ui-verify]]'s note. So a Claude test user's grid IS a valid comparison
baseline. The one exception is `tier1800`, which can't see other organisations' data; use
`tier3500` for anything cross-org.

## MCF Header Export specifically

It's a **dynamic cohort report**, not a plain aggregation: route is
`dynamic-cohorts/reports/mcf-header-export/view/<reportId>` and it needs an existing saved
report id (`dynamicCohortReportService.getById`). The raw template route
(`/aggregations/mcf-header-export`, no id) is a different, id-less path — hitting it with a
`RequestedDownloads`-role user is what PROJ-15278's guard commit fixed.

**Servicer percentages are ZERO on both QA and Staging — you cannot validate MCF values
outside Production.** Confirmed 2026-08-18 across three cohort reports (two Staging, one
QA): every `_PCT` column returned `"0"` while the searches returned `200` with rows and a
working Export. The zeros include `FREE`, `GUARR`, `NSTAR`, `MOVEM`, `FIFTH`, `USB`, `PHH` —
so it is **missing servicer data in non-prod**, not a broken report. Consequence: a
pre-production run can prove the column *contract* (names, order, presence, no `42703`) and
nothing about whether the numbers are right. Don't report "verified on Staging" for anything
value-related; say which of the two you actually checked.

Its servicer columns are `<CODE>_PCT` (e.g. `CLKCL_PCT`) plus a computed `OTHERS_PCT`.
Those come from the C# dictionary in `export`'s `McfServicersService.cs`, and reach the DB
as `SqlTemplate` rows — **not** from anything in the `Template` body text. Searching
`SqlTemplate."Template"` for a servicer code returns nothing and is a **vacuous** check,
not a pass. Assert on the `"Column"` value. `OTHERS_PCT` sums `template_pct_<code>`
aliases; if it references a code with no live row, reports 500 with
`42703: column … does not exist` — so alias-count must equal live-servicer-count.

## The three scripts that do this end-to-end

In [[ama-ui-verify]]'s `scripts/`. Run them in order:

```bash
# 1. drive the grid + click Export -> grid snapshot & exportId as JSON
bash <run-mjs wrapper> staging 3500 verify-export-vs-grid.mjs <reportUrl> <out.json> [exportName]
# 2. pull the newest matching zip and unpack it
bash fetch-export-zip.sh staging <out-dir> [name-substring] [since-iso]
# 3. ordered column diff + value cross-check
node diff-export-vs-grid.mjs <out.json> <out-dir>/unzipped/<file>.csv [--max-rows N]
```

Exit codes carry the diagnosis, so don't just look at stdout: `3` grid never loaded,
`4` Export button stayed disabled, `5` `POST /export` never seen, `6` a diff check failed.

**Proof status**: exercised end-to-end against Staging 2026-08-18 (MCF Header Export, 218
columns) — grid driven, Export clicked, `POST /export` → `{Id}`, zip pulled from S3, ordered
diff run. It found two genuine pre-existing defects (PROJ-15316), which is the point of
it. `diff-export-vs-grid.mjs` also has a standing fixture test, `bash selftest-diff-export.sh`
(no network/browser/AWS): faithful export, preamble rows before the header, reordered columns,
missing column, values absent from the grid. The **reorder case is the point** — a
set-comparison implementation passes it.

**The S3 `<guid>` prefix IS the exportId** returned by `POST /export` — confirmed
(`exportId=0d4daace-…` → key `0d4daace-…/claude-mcf-15278-verify.zip`). So you can address
the object directly instead of guessing from `LastModified`.

**Column order must be read per ag-grid container, not by `style.left` alone.** ag-grid
renders pinned-left / centre / pinned-right in three containers, *each starting at
`left: 0`*. Sorting one merged list by `left` interleaves the pinned group-by columns into
the middle of the centre columns and reports a bogus order mismatch at position 1 — hit live,
and it looked exactly like a product bug. Bucket by container first, then sort by `left`
within each. `verify-export-vs-grid.mjs` does this; the fix moved the reported divergence
from position 1 to position 44, where a real one-pair defect was waiting.

**Export is not a browser download.** The toolbar button `button[title='Export Report']`
opens a MatDialog; `#export-report-confirm` POSTs `/export` → `{Id}` and resultsprocessor
writes the zip to S3 **asynchronously**. `page.waitForEvent('download')` hangs forever.
`GET /export/status/<id>` returns `{Status, ExpectedNoDocs, CurrentNoDocs, ExportFileLocation}`.
Leave `#new-export-save-report-checkbox` **off** — it also creates a saved report.

**The Export button is disabled until the grid has data** (`isExportsEnabled()` needs
`pagedGridTreeRequestModelChange.size > 0`), so the grid wait gates the click.

**ag-grid virtualises columns**, so `.ag-header-cell-text` only holds the viewport — reading
headers straight from the DOM silently checks only the visible handful. `verify-export-vs-grid.mjs`
scrolls `.ag-body-horizontal-scroll-viewport` and merges on `col-id`, ordering by
`style.left`. Cell **values** come from the `POST /search/*` bodies (`{id, results[], FromCache}`,
`results[0]` keys are raw aggregation column ids) — complete and unvirtualised.

## Still open

- Whether the S3 `<guid>` prefix is the export id, the download id, or the user id.
- **No MCF Header Export report exists on Staging** (confirmed 2026-08-18: `mcf-header-export`
  is absent from every `UserReport.BasedOn` value, though the template row *is* present and
  not deleted). So MCF is driven via its raw template route
  `/aggregations/mcf-header-export`; the saved-report route is `dynamic-cohorts/reports/mcf-header-export/view/<reportId>`.
