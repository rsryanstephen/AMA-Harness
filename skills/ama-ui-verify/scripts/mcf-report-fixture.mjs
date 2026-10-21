// PROJ-15467 verify: MCF (mcf-header-export) cohort report columns not sortable.
// Phases (argv[2]): peek | create | verify <reportId> | contrast | cleanup <reportId> [cohortId]
// Env: AMA_UI_BASE + AMA_UI_USERNAME/AMA_UI_PASSWORD (see run-ui-verify.sh). Phases: peek | create | verify <reportId> | contrast | cleanup <reportId> <cohortId> | check <reportId> <cohortId>. Recipe: ../MCF-REPORT-DRIVING.md
import { chromium, login, api, BASE } from 'file:///C:/Users/your.windows.username/.claude/skills/ama-ui-verify/scripts/lib-ama-ui.mjs';

const phase = process.argv[2];
const arg1 = process.argv[3];
const arg2 = process.argv[4];
const rnd = Math.random().toString(36).slice(2, 8);
// Screenshot dir: pass your session scratchpad as AMA_UI_OUT (was hardcoded to one old session's).
const OUT = process.env.AMA_UI_OUT ?? (await import('os')).tmpdir();

const short = (o, n = 500) => JSON.stringify(o).slice(0, n);

async function waitGrid(page, ms = 90000) {
  const t0 = Date.now();
  await page.waitForFunction(() => {
    const cells = document.querySelectorAll('.ag-cell');
    return cells.length > 0 && [...cells].some((c) => c.textContent.trim().length > 0);
  }, null, { timeout: ms });
  return Date.now() - t0;
}

function trackSearch(page, sink) {
  page.on('request', (req) => {
    const u = req.url();
    if (req.method() !== 'POST' || !/\/search\//.test(new URL(u).pathname)) return;
    let ob = null;
    // sort lives in SearchRequestMetadata: body.Metadata.OrderBys (QueryModels.ts)
    try { const b = JSON.parse(req.postData() || '{}'); ob = b?.Metadata?.OrderBys ?? b?.metadata?.OrderBys ?? b.OrderBys ?? `keys:${Object.keys(b).join(',')}`; } catch {}
    const rec = { t: Date.now(), path: new URL(u).pathname, orderBys: ob, status: null };
    sink.push(rec);
    req.response().then((r) => { rec.status = r ? r.status() : 'none'; }).catch(() => { rec.status = 'err'; });
  });
}

async function headerInfo(page) {
  return page.evaluate(() => [...document.querySelectorAll('.ag-header-cell')].map((h) => ({
    colId: h.getAttribute('col-id'),
    text: (h.querySelector('.ag-header-cell-text')?.textContent || '').trim(),
    sortableClass: h.classList.contains('ag-header-cell-sortable'),
    ariaSort: h.getAttribute('aria-sort'),
    sortIconsShown: [...h.querySelectorAll('.ag-sort-indicator-icon')].filter((i) => !i.classList.contains('ag-hidden')).length,
  })));
}

async function errorText(page) {
  return page.evaluate(() => {
    const t = document.body.innerText;
    return ['Error getting data', "couldn't be loaded", 'could not be loaded', 'Something went wrong'].filter((s) => t.includes(s));
  });
}

async function clickHeader(page, h, reqs, label) {
  const before = reqs.length;
  const loc = page.locator(`.ag-header-cell[col-id="${h.colId}"] .ag-header-cell-label`).first();
  await loc.hover().catch(() => {});
  await loc.click({ force: true });
  await page.waitForTimeout(8000);
  const after = await headerInfo(page);
  const me = after.find((x) => x.colId === h.colId);
  const newReqs = reqs.slice(before).map((r) => ({ path: r.path, status: r.status, orderBys: r.orderBys }));
  const rows = await page.evaluate(() => [...document.querySelectorAll('.ag-center-cols-container .ag-row')].length);
  const errs = await errorText(page);
  console.log(`CLICK ${label} col=${h.colId} "${h.text}" -> ariaSort=${me?.ariaSort} sortIconsShown=${me?.sortIconsShown} rows=${rows} errors=${short(errs)} newSearchPOSTs=${short(newReqs, 1500)}`);
}

const browser = await chromium.launch();
try {
  const ctx = await browser.newContext({ viewport: { width: 1800, height: 1000 } });
  const page = await ctx.newPage();
  await login(page);
  await page.goto(BASE + '/dynamic-cohorts/reports', { waitUntil: 'networkidle' });

  if (phase === 'peek') {
    const s = await api(page, 'GET', '/cohort/summary?pageSize=50');
    const id = s.body.items[0]?.id;
    const c = await api(page, 'GET', `/cohort/${id}`);
    console.log('COHORT', short(c.body, 2500));
    const rs = await api(page, 'GET', '/cohort/report/summary?pageSize=50&ownership=0');
    console.log('REPORTS', short(rs.body, 1500));
  }

  if (phase === 'create') {
    // 1. throwaway cohort -- same body shape the UI's create-cohort screen POSTs (CreateCohortCommand)
    const cohortBody = {
      name: `claude-verify-15467c-${rnd}`,
      description: '\nWhere 100% Single Gov Agency is (NA)-FHA',
      // operator 5 = In (criteriaOperator enum). Builds in ~15s on staging.
      criteria: [{ field: 'loan_by_servicer_transfer_non_periods_source.ga_unique_in_pool', fieldLabel: '100% Single Gov Agency', operator: 5, value: ['(NA)', 'FHA'], isBond: false }],
    };
    const c = await api(page, 'POST', '/cohort', cohortBody);
    console.log('POST /cohort ->', c.status, short(c.body, 400));
    const cohortId = c.body.id;
    const t0 = Date.now();
    let st = null;
    while (Date.now() - t0 < 15 * 60000) {
      const g = await api(page, 'GET', `/cohort/${cohortId}`);
      st = g.body?.progress?.status ?? g.body?.status;
      if (st === 2 || st === 3) break;
      await page.waitForTimeout(10000);
    }
    console.log(`COHORT_BUILD status=${st} after ${Math.round((Date.now() - t0) / 1000)}s id=${cohortId}`);
    if (st !== 2) throw new Error('cohort did not build');
    // 2. MCF report -- same body CreateCohortReportComponent.buildNewCohortReport() POSTs
    const repBody = { name: `claude-verify-15467-${rnd}`, description: null, template: 'mcf-header-export', cohorts: [cohortId], criteria: [] };
    const r = await api(page, 'POST', '/cohort/report', repBody);
    console.log('POST /cohort/report ->', r.status, short(r.body, 600));
    console.log(`CREATED reportId=${r.body?.id} cohortId=${cohortId}`);
  }

  if (phase === 'verify') {
    const reqs = []; trackSearch(page, reqs);
    const url = `${BASE}/dynamic-cohorts/reports/mcf-header-export/view/${arg1}`;
    const t0 = Date.now();
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    const ms = await waitGrid(page, 120000);
    await page.waitForTimeout(3000);
    console.log(`GRID_READY ${Math.round((Date.now() - t0) / 1000)}s (grid wait ${Math.round(ms / 1000)}s)`);
    console.log('INITIAL_SEARCH_POSTS', short(reqs.map((r) => ({ path: r.path, status: r.status, orderBys: r.orderBys })), 1500));
    const hs = await headerInfo(page);
    console.log('HEADERS', JSON.stringify(hs));
    await page.screenshot({ path: `${OUT}/mcf-15467-before.png` });
    const groupBy = hs.filter((h) => /agency|coupon|cohort/i.test(h.text)).slice(0, 2);
    const measure = hs.find((h) => h.text && !/agency|coupon|cohort/i.test(h.text));
    for (const h of groupBy) await clickHeader(page, h, reqs, 'GROUPBY');
    if (measure) await clickHeader(page, measure, reqs, 'MEASURE');
    await page.screenshot({ path: `${OUT}/mcf-15467-after.png` });
  }

  if (phase === 'contrast') {
    const reqs = []; trackSearch(page, reqs);
    await page.goto(BASE + '/aggregations/agency-marketshare', { waitUntil: 'domcontentloaded' });
    await waitGrid(page, 120000);
    await page.waitForTimeout(3000);
    const hs = await headerInfo(page);
    console.log('HEADERS', JSON.stringify(hs.slice(0, 6)));
    const h = hs.find((x) => /agency/i.test(x.text)) || hs.find((x) => x.text);
    await clickHeader(page, h, reqs, 'CONTRAST');
  }

  if (phase === 'cleanup' || phase === 'check') {
    // NOTE: deletes are SOFT -- GET still 200; confirm isDeleted/deletedAtUtc + absent from summaries.
    const g1 = await api(page, 'GET', `/cohort/report/${arg1}`);
    console.log('CHECK report', g1.status, short({ isDeleted: g1.body?.isDeleted, deletedAtUtc: g1.body?.deletedAtUtc, deletedBy: g1.body?.deletedBy }));
    if (arg2) { const g2 = await api(page, 'GET', `/cohort/${arg2}`); console.log('CHECK cohort', g2.status, short({ isDeleted: g2.body?.isDeleted, deletedAtUtc: g2.body?.deletedAtUtc })); }
    const rs = await api(page, 'GET', '/cohort/report/summary?pageSize=50&ownership=0');
    const cs = await api(page, 'GET', '/cohort/summary?pageSize=50');
    console.log('SUMMARIES reports=', short(rs.body?.items?.map((x) => x.name)), 'cohorts=', short(cs.body?.items?.map((x) => x.name)));
  }
  if (phase === 'cleanup') {
    const d1 = await api(page, 'DELETE', `/cohort/report/${arg1}`);
    console.log('DELETE /cohort/report ->', d1.status);
    const g1 = await api(page, 'GET', `/cohort/report/${arg1}`);
    console.log('GET /cohort/report after delete ->', g1.status);
    if (arg2) {
      const d2 = await api(page, 'DELETE', `/cohort/${arg2}`);
      console.log('DELETE /cohort ->', d2.status);
      const g2 = await api(page, 'GET', `/cohort/${arg2}`);
      console.log('GET /cohort after delete ->', g2.status);
    }
  }
} finally {
  for (const c of browser.contexts()) { for (const p of c.pages()) await p.close().catch(() => {}); await c.close().catch(() => {}); }
  await browser.close();
}
