---
name: ama-user-data-copy
description: Hand one AMA user's saved reports, cohorts, cohort reports and custom bands to another account (same person at a new company, "migrate a user's reports to a new account", "copy user data", "move user data", "switch the owner", "user moved companies"). Two paths -- move.sh (owner switch in place, no cohort regeneration, source left empty; the default since PROJ-15474) or run.sh (independent copies, source untouched). Inventory + dry run first, rehearse on QA with the harness test users, then production.
---

# ama-user-data-copy

Copy = independent clones under the target's name. Source untouched (fingerprinted before,
compared after). Reversible: every created id lands in one manifest, `rollback.sh` deletes
exactly those. First real case: PROJ-15474 (John Wang, Two Harbors -> Freedom Mortgage).

## Stores + owner keys (confirmed in code 2026-10-07)

| store | rows | owner key | copied how |
|---|---|---|---|
| reports Postgres (`<env>-v1-reports-api`) | `UserReport` (Report/Query/TemplateFields jsonb) | `OwnedBy` = Cognito **username** | SQL clone, one transaction |
| reports Postgres | `UserSavedReport`, `UserFolder` (folder tree jsonb) | `UserUid` = Cognito **sub** | row per copy in target's tree; customs recreated |
| export Postgres (`<env>-v1-export-api`) | `DynamicColumn` = custom bands | `UserName` = username | SQL clone (`INSERT..SELECT`, explicit cols) |
| Mongo db `cohort` | `cohort` | `user` = username | **real API** `POST /cohort` as temp test user, then `updateOne` user->target |
| Mongo db `cohort` | `cohortreport` | `user` = username | doc clone (new BinData-3 `_id`) |
| NOT copied | export history, notifications, UserState, ExportCohort jobs, shares received, soft-deleted rows, `client-loan-data` reports (another company's loan data) | | listed by `inventory.sh` |

Why cohorts go through the API: only `POST /cohort` allocates `MappingId`, writes the Redshift
`CohortNameMapping` row and queues cohortdata generation. Flip `user` ONLY after
`progress.status == 2` -- the progress handler `ReplaceOne`s the doc and would revert an early flip.

Ids embedded in JSON that MUST be rewritten old->new (both guid forms, `dc__<guid_with_underscores>`
too): `Report.Id/CohortIds`, `Query.CohortIds/ReportId/BandFields`, `cohortreport.cohorts[]`,
`searchRequest.*`, every `dc__` field. Search enforces cohort OWNERSHIP at query time; bands are
resolved by id with no owner check (a missed band remap silently keeps using the source's band).
`udc.py check-no-source-ids` + `verify.sh` assert nothing survives.

## Scripts (`scripts/`)

```bash
S=~/.claude/skills/ama-user-data-copy/scripts
bash $S/inventory.sh <env> <username> <sub>                 # READ-ONLY, run first for source AND target
bash $S/run.sh <env> <from> <from-sub> <to> <to-sub> --dry-run [--temp-user U]
bash $S/run.sh <env> <from> <from-sub> <to> <to-sub> [--batch N] [--resume] [--temp-user U] [--include-received-shares]
bash $S/verify.sh  <manifest>                                # DB truth: fidelity, ownership, no source ids, source fingerprint
bash $S/verify-as-target.sh <manifest>                       # app truth: log in as target AND source, list + open everything
bash $S/run-ui-check.sh <manifest> target|source             # real browser as a test user (dev server + Playwright), screenshots
bash $S/rollback.sh <manifest> [--dry-run]                   # undo exactly the manifest's ids
bash $S/rehearse.sh <qa|staging> <samples-dir> [--keep]      # seed -> copy -> verify x3 -> rollback -> clean? -> copy -> verify
```

## Move = owner switch (chosen for PROJ-15474, 2026-10-08: regenerating 127 cohorts is a waste)

```bash
bash $S/move.sh <env> <from> <from-sub> <to> <to-sub> [--dry-run] [--include-received-shares]
bash $S/move-rollback.sh <manifest> [--dry-run]       # exact pre-move rows back from the snapshot
bash $S/run-ui-check.sh <manifest> target              # same browser check; manifest shape is shared
```

Ids stay; owner changes in place: `UserReport.OwnedBy` (+ owner strings in Report/Query/TemplateFields),
`UserSavedReport.UserUid` + folder remapped into the target tree (customs merged, target row kept),
`DynamicColumn.UserName`, `cohort.user`, `cohortreport.user` -- deleted rows/docs too (whole account).
No Redshift work: MappingId and cohort rows untouched. Source ends EMPTY (its reports referencing
moved cohorts would break anyway -- RequireCohortOwnership). Skips `client-loan-data` reports.
Pre-checks: no cohort generating (progress handler would ReplaceOne the flip back), no live cohort
name clash on the target. Snapshots `move-<env>-<from>-<to>.snap/{before,after}-{src,tgt}` ->
`udc.py move-compare` (every item identical apart from owner strings; target's own items intact;
source holds none) + `verify-as-target.sh` (source must see NOTHING). Rollback restores from
`before-src` and re-checks both fingerprints. Plans: `<manifest>.plan.{reports,export}.sql`,
`.plan.{cohort,cohortreport}.js` (one updateOne per doc by `_id` AND current user).
QA pass 1 (2026-10-08): move + compare + as-user + browser all green; rollback needed two fixes (reverse
JS built 0 ops; store cleared on 0-of-0) -- both in. Traps: a source with Admin/UserManagement still
OPENS moved reports by id (AccessAllReports) -- listing is the assertion; every report view re-saves
`TemplateFields` (+blank entries) and bumps LastOpened/OpenedTally, so fingerprints drift after any
check -- the item compare excludes those for viewed reports and says so.

Received shares (`--include-received-shares`, step 5 = `copy-received-shares.sh`): re-grants to
the target every share the source RECEIVED from others -- UserSavedReport row in the target's
"Shared with me", ShareDynamicColumn row, `$addToSet sharedWith` on others' cohorts/cohort
reports. Nothing cloned, originals stay with their owners; rollback removes the grants.
Org-level band shares cannot follow a person. Opt-in only: a colleague shared with the source
as THEIR colleague -- extending that to another company's account is the client's decision.

Production rehearsal (before the real run): `ALLOW_PROD_TEST_USER=1 create-test-user.sh production
claude_prod_3500b claude_prod_3500`, then `run.sh production <real user> ... claude_prod_3500b`
(temp `claude_prod_3500`), `verify.sh`, `verify-as-target.sh`, `run-ui-check.sh ... target`,
`rollback.sh`. Both accounts must come out byte-identical to before (source fingerprint; target
inventory back to zero). Outside Mon-Fri 9-5 ET, PROD hatches set.

Manifest: `~/.claude/harness-state/logs/user-data-copy/copy-<env>-<from>-<to>.json`. Exists
-> run refuses without `--resume` (idempotency). Dry run writes `dryrun-*.json` + the SQL it would apply.

Order inside `run.sh`: bands -> cohorts (batched, waits for status 2, flips) -> cohort reports ->
saved reports -> verify. Each step skips what the manifest already has.

Temp user = `.users.<env>.tier3500` in `~/.claude/.ama-ui-credentials.json` (token via
`cognito-token.sh`, USER_PASSWORD_AUTH on the SPA's app client, no browser). Must differ from
source AND target -> rehearsal whose source is that user passes `--temp-user claude_<env>_1800`
(`Roles.DynamicCohorts = "Tier3500,Admin,UserManagement"`; every test user has UserManagement).

Rehearsal helpers: `create-test-user.sh <qa|staging> claude_<env>_3500b claude_<env>_3500`
(manage `POST /users` + permanent password; manage enums are INTS), `seed-fixture.sh <env> <samples-dir> <out>`
(`FIXTURE_PREFIX` on a re-seed: the band name-exists check ignores IsDeleted).

## Gates

Writes: `AMA_ALLOW_PG_WRITE=1` + `AMA_ALLOW_MONGO_WRITE=1` (qa/staging) or
`AMA_ALLOW_PROD_PG_WRITE=1` + `AMA_ALLOW_PROD_MONGO_WRITE=1` (production) in Claude Code's OWN
environment (relaunch with them set). Inline `VAR=1 bash` never reaches the hook. Dry run,
inventory, API creates need none.

## Production rules

- Outside Mon-Fri 9am-5pm ET: each cohort = one report-scale generation on the shared Redshift
  cluster (QA pace 2026-10-07: cohort-data Lambda drained ~1 cohort / 10 min). Self-enforced:
  `lib-redshift-window.sh` stops `copy-cohorts.sh` creating (exit 3, `--resume` later) inside the
  window or from 08:15 ET on a weekday -- production always, qa/staging when >10 pending;
  `COHORT_IGNORE_WINDOW=1` overrides. In-flight cohorts are still flipped.
- Deferring: `reminder.sh add` for next weekday 08:00 LOCAL (PC off at 17:04 ET; 17:04 ET only if user asks) + keep the session OPEN. A sleeping
  background `bash` waiter dies with the Claude Code process (2026-10-07: nothing ran, no log line).
- Re-run `inventory.sh` on the day; `--dry-run`; user confirms; run; `verify.sh`.
- No target credentials in prod: verify via `claude_prod_3500` direct-URL opens (Admin/AccessAllReports
  bypass) + Mongo flags, then the user confirms through the client contact.
- Roles: diff `aws cognito-idp admin-list-groups-for-user` old vs new. Enforced ones to grant:
  `McfHeaderCohortReport` (MCF cohort reports), `PoolLoanView` (`pool-data` reports). CMO templates
  need only Tier3500 -- `CmoMegaViewer`/`CmoServicingTransferViewer` are inert (see
  `ama-architecture-notes/AUTH-AND-SECURITY.md`). Admin UI assigns MCF + PoolLoanView
  (PROJ-15475); John.Wang granted both via CLI 2026-10-07. Token refresh/re-login needed.
- Tell the client contact (business level): Monthly Downloads is OFF on copies (re-enable per
  report once the role exists), `client-loan-data` reports and received shares not copied.

## Rehearsal findings (QA, 2026-10-07)

- Full copy 3500 -> 3500b: 3 bands, 4 cohorts (status 2, criteria/type identical), 5 cohort reports
  (incl. bonds-only), 13 reports + 1 custom folder; `verify.sh`, `verify-as-target.sh`, browser
  check all green for BOTH users; source fingerprint unchanged before/after copy AND after rollback.
- Rollback = one pass to a clean target (0 items, default 3-folder tree). Its Postgres steps clear a
  manifest section ONLY on `COMMIT` -- a rolled-back transaction keeps the ids for the retry.
- `--resume` is real: bands/cohorts/cohort reports already on the target are skipped by id, never re-inserted.
- A cohort report whose cohort is soft-deleted at the source (`[Deleted <ms>] ...`) is SKIPPED and listed
  in `.skippedCohortReports` -- it is already broken for the source; tell the client which ones.
- Dashboard text check is informational: subfolders collapse and long lists sit below the fold; the
  `/report/all` listing is the assertion. Screenshots: `<manifest>.ui/`.
- Cohort generation pace = the env's cohort-data Lambda, not us: QA drained ~1 cohort / 10 min.

## Traps hit while building (2026-10-07)

- jq 1.5 CRLF: every `jq -r` goes through `jr()`; a `1\r` count silently emptied an array slice.
- mongosh 7 `JSON.stringify(BinData)` = bare base64 string; legacy 4.0 shell = `{"$binary","$type"}`. `udc.py mongo-id` takes both.
- `Content-Type: application/json;v=2.0` only for `PUT /report` + rename; every other route 400s on it (`API_CT` in `api.sh`).
- `/aws/lambda/...` log group names need `MSYS_NO_PATHCONV=1` or git-bash rewrites them.
- Cohort `dataAvailable` is a create-time flag (all 127 prod cohorts false); completion = `progress.status 2`.
- Prod `UserReport` lacks `HasMonthlyDownloadsData`; columns are read live from information_schema per env.

## Status (update as the work moves)

- 2026-10-07: QA rehearsals #1 and #2 green (copy, 3 verifications, single-pass rollback to an
  empty target, source fingerprint identical); `--include-received-shares` exercised with a report
  shared 1800 -> 3500 (re-granted to 3500b, removed by rollback). `claude_prod_3500b` created for
  the prod rehearsal; prod dry run for PROJ-15474 (jiong.wang -> test user) previews 15 bands,
  127 cohorts, 50 cohort reports (3 skipped: deleted cohorts), 52 reports.
  NEXT: prod rehearsal onto `claude_prod_3500b` AFTER 17:00 ET with the PROD hatches, verify both,
  rollback; then the real run onto `John.Wang`; reply to Dan.
- 2026-10-08: the 17:00 ET waiter died with the session (no prod writes). Window guard added. Roles:
  `John.Wang` granted PoolLoanView + McfHeaderCohortReport (PROJ-15475 adds PoolLoanView to
  the Admin UI, on develop/QA). User then chose the OWNER SWITCH (`move.sh`) over the copy: QA dry
  run clean (14 reports, 3 bands, 74/65 Mongo docs). QA passes 1+2 green (move, compare, as-user,
  browser, rollback byte-identical). PROD MOVE DONE 2026-10-08 14:14-14:40 UTC: jiong.wang -> John.Wang
  with received shares; compare ALL PASS; admin opens OK. Hiccup: one 144-op Mongo call went silent at
  67 -> re-run completed it; Mongo ops now chunked (`mongo-apply.sh`). NEXT: Dan's reply on the 13
  org-shared reports; John confirms; ticket Done.
