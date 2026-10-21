// Replay an MCF (`mcf-header-export`) search request on an environment, headless, as the
// configured test user, and summarise the result -- settles "the grid shows masked / null
// quartiles" from the JSON, no ag-grid wait. Written for PROJ-15801 (grouped Quartiles
// rows null in Production, fixed on Staging) and kept as the template.
//
// Usage (run-ui-verify.sh --script sets the AMA_UI_* env for the environment and tier):
//   bash scripts/run-ui-verify.sh staging 3500 --script scripts/replay-mcf-request.mjs <reportId> <cohortId> [request.json]
//   request.json  the POST body captured from DevTools or Graylog (Windows-form path);
//                 CohortIds/ReportId are overwritten with the ids given. Omitted -> the
//                 built-in grouped-quartiles body below (edit `body()` to match the failing
//                 request). COARSE=1 -> group by Cohort + Agency only: many loans per row,
//                 so nothing may be masked.
// Prints per path (/search/... and /rowcount): status, seconds, rows, allQuartilesNull,
// masked, maskedRowCount, sample filled values, flatFilled (quartile strings with one value).
import fs from 'node:fs';
import { chromium, login, BASE } from './lib-ama-ui.mjs';

const [reportId, cohortId, requestFile] = process.argv.slice(2);
if (!reportId || !cohortId) { console.error('usage: replay-mcf-request.mjs <reportId> <cohortId> [request.json]'); process.exit(64); }

const T = 'loan_by_servicer_transfer_non_periods_source';
const f = (FriendlyName, col, FieldType = 'String') => ({
  FriendlyName, Name: `${T}.${col}`, Metadata: { FieldType, IsDynamicField: false }, FullName: `${T}__${col}`,
});
const gc = (name, fieldType = 'String') => ({ name, fieldType, metaData: { decimalPlaces: 2 } });
const q = (Column) => ({ Column, NormalisedName: `template_pct_quartiles_${Column.toLowerCase()}`, FieldType: 'String', CteSource: 'quartiles_cte' });

// The PROJ-15801 shape: six grouping columns, eight quartile template columns.
const body = (offset) => ({
  ReportTemplateName: 'mcf-header-export', Type: T, multiTableSetName: 'loan',
  Fields: [
    { FriendlyName: 'Cohort', Name: 'cohort_name_mapping_source.name', Metadata: { FieldType: 'String', IsDynamicField: false }, FullName: 'cohort_name_mapping_source__name' },
    f('Agency', 'security_agency'), f('Coupon Type', 'securityperiodic_coupontype'), f('MBS Coupon Band', 'securityperiodic_coupon_band'),
    f('First Payment Date Year', 'loanperiodic_firstpaymentdate_year', 'Number'), f('GNMA Agency', 'loanperiodic_governmentagency'),
  ],
  AggregatedFields: [], Criteria: [],
  GroupingColumns: [
    gc('cohort_name_mapping_source.name'), gc(`${T}.security_agency`), gc(`${T}.securityperiodic_coupontype`),
    gc(`${T}.securityperiodic_coupon_band`), gc(`${T}.loanperiodic_firstpaymentdate_year`, 'Number'), gc(`${T}.loanperiodic_governmentagency`),
  ],
  RequestType: 'cteSource', QueryType: 0, PercentageFields: [],
  SqlTemplateColumns: ['LSZQ', 'CSQ', 'LTVQ', 'DTIQ', 'WACQ', 'WAMQ', 'WALAQ', 'OTERMQ'].map(q),
  CprNFields: [], hierarchical: false,
  Metadata: { PageSize: 80, PageOffset: offset, OrderBys: [] },
});

const finalBody = () => {
  const b = requestFile ? JSON.parse(fs.readFileSync(requestFile, 'utf8')) : body(0);
  if (!requestFile && process.env.COARSE === '1') { b.Fields = b.Fields.slice(0, 2); b.GroupingColumns = b.GroupingColumns.slice(0, 2); }
  b.CohortIds = [cohortId]; b.ReportId = reportId;
  return b;
};

const browser = await chromium.launch();
const page = await browser.newPage();
try {
  await login(page);
  // The page's own first load reveals the search API origin (differs from the app host).
  let searchUrl = null;
  page.on('request', (r) => { if (!searchUrl && r.method() === 'POST' && /\/search\/mcf-header-export/.test(r.url())) searchUrl = r.url(); });
  await page.goto(`${BASE}/dynamic-cohorts/reports/mcf-header-export/view/${reportId}`, { waitUntil: 'domcontentloaded' });
  const t0 = Date.now();
  while (!searchUrl && Date.now() - t0 < 120000) await page.waitForTimeout(1000);
  if (!searchUrl) throw new Error('page never POSTed /search/mcf-header-export');
  const origin = new URL(searchUrl).origin;
  console.log('SEARCH_ORIGIN', origin);

  for (const path of ['/search/mcf-header-export?t=low&l=cteSource', '/search/mcf-header-export/rowcount']) {
    const started = Date.now();
    const res = await page.evaluate(async ({ url, b }) => {
      const k = Object.keys(localStorage).find((x) => x.endsWith('.accessToken'));
      const r = await fetch(url, { method: 'POST', headers: { Authorization: 'Bearer ' + localStorage.getItem(k), 'Content-Type': 'application/json' }, body: JSON.stringify(b) });
      const text = await r.text();
      let summary = null;
      try {
        const j = JSON.parse(text);
        const rows = j?.Results?.Results;
        if (rows) {
          const val = (row, name) => row.Points.find((p) => p.FieldName === name)?.Value?.Value ?? null;
          const lszq = rows.map((row) => val(row, 'template_pct_quartiles_lszq'));
          const allNull = rows.filter((row) => row.Points.filter((p) => p.FieldName.startsWith('template_pct_quartiles_')).every((p) => p.Value?.Value == null)).length;
          summary = { rows: rows.length, allQuartilesNull: allNull, masked: j.Results.Masked, maskedRowCount: j.Results.MaskedRowCount,
            sampleFilled: lszq.filter((v) => v != null).slice(0, 3),
            flatFilled: lszq.filter((v) => v != null && new Set(String(v).split(' ')).size === 1).length };
        }
      } catch { /* not json */ }
      return { status: r.status, text: summary ? JSON.stringify(summary) : text.slice(0, 600) };
    }, { url: origin + path, b: finalBody() });
    console.log(`REPLAY ${path} -> ${res.status} in ${Math.round((Date.now() - started) / 1000)}s`);
    console.log(res.text);
  }
} finally {
  await browser.close();
}
