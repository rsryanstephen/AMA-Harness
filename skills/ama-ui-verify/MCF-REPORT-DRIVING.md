# Driving an MCF report headless (fixture recipe)

MCF (`mcf-header-export`) reports need a cohort first. Test users own none, so create one.
Proven on Staging 2026-10-05 (PROJ-15467) as `claude_st_3500`. Script:
`scripts/mcf-report-fixture.mjs` (phases `peek | create | verify <reportId> | contrast |
cleanup <reportId> <cohortId> | check <reportId> <cohortId>`); env as `run-ui-verify.sh`.

## Prerequisites
- Role `McfHeaderCohortReport` (or Admin). `tier3500` test users have it; `tier1800` do not.
- Same-origin API from the logged-in page: `api(page, method, path, body)` in `lib-ama-ui.mjs`.

## Steps
1. **Cohort** -- `POST /cohort` with
   `{name, description, criteria:[{field, operator, value:[], isBond:false}]}` -> 201.
   Known-good criterion: `field: "loan_by_servicer_transfer_non_periods_source.ga_unique_in_pool"`,
   `operator: 5` (In), `value: ["(NA)","FHA"]`. Poll `GET /cohort/{id}` until
   `progress.status == 2` (3 = failed); ~12s.
2. **Report** -- `POST /cohort/report` with
   `{name, description:null, template:"mcf-header-export", cohorts:[cohortId], criteria:[]}` -> 201, returns `id`.
   UI equivalent: `/dynamic-cohorts/reports/mcf-header-export/new` (dashboard tile
   `a[href*="mcf-header-export/new"]`); bonds are optional.
3. **View** -- `/dynamic-cohorts/reports/mcf-header-export/view/<id>`. Grid (`.ag-cell` non-empty)
   took 33-37s; allow 120s. First load POSTs `/search/mcf-header-export` and `/rowcount`.
4. **Clean up** -- `DELETE /cohort/report/{id}` then `DELETE /cohort/{id}`, both 200.

## Replaying a failing request (PROJ-15801, 2026-10-14)

Prod report fails, Staging has the fix → replay the exact `/search/mcf-header-export` POST on
Staging as the test user, headless. The JSON summary answers masked / null quartiles directly;
no grid wait.
`bash scripts/run-ui-verify.sh staging 3500 --script scripts/replay-mcf-request.mjs <reportId> <cohortId> [request.json]`
- `request.json` = the body captured from DevTools or Graylog (Windows-form path); omitted →
  the built-in grouped-quartiles template (edit `body()`). `COARSE=1` groups by Cohort +
  Agency only: many loans per row, so nothing may be masked.
- Ids come from `mcf-report-fixture.mjs create` (fixture first).
- Per path: status, seconds, rows, allQuartilesNull, masked, sample values.

**Mon-Fri 9-5 ET**: a report-scale Redshift query on the shared cluster (AGENTS.md "No
Redshift-heavy work"). Urgent prod bug → ask the user; explicit yes → run it ONCE (one
request, not a matrix). The Production deploy after it still needs its own yes
(`AMA_ALLOW_PROD_DEPLOY=1`, [[ama-hotfix]] Step 4).

## Traps
- **Deletes on `/cohort` and `/cohort/report` are SOFT** (`IsDeleted=true`): a GET still returns
  200 afterwards. Confirm cleanup by absence from `/cohort/report/summary?ownership=0` and
  `/cohort/summary`, never by a 404.
- A grid sort lives at `body.Metadata.OrderBys` on the `/search/*` POST, not top-level.
- ag-grid sort state: read `aria-sort` / the `ag-header-cell-sortable` class on `.ag-header-cell`;
  counting sort icons reads 0 even when sorted on this ag-grid version.
- Name fixtures `claude-verify-<ticket>-<random>` so a leftover is recognisable.
