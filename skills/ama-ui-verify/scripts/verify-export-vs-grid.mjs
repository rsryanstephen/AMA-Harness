#!/usr/bin/env node
// Drive a report on a deployed env, capture what the GRID shows, trigger the Export
// button, and emit everything needed to diff the exported CSV against the grid.
//
// Why it works the way it does (all confirmed live 2026-08-18, see EXPORT-DOWNLOADS.md):
//   * Export is NOT a browser download. The toolbar button opens a MatDialog; confirming
//     it POSTs /export -> {Id}, and resultsprocessor writes the zip to S3 asynchronously.
//     page.waitForEvent('download') would hang forever.
//   * ag-grid virtualises columns, so .ag-cell / .ag-header-cell-text only ever hold the
//     viewport. Column ORDER is part of the export contract, so headers are collected by
//     scrolling the grid horizontally and merging by col-id.
//   * Cell VALUES come from the POST /search/* response bodies ({id, results[], FromCache}),
//     which are complete and unvirtualised. results[] keys are raw aggregation column ids.
//   * The Export button is [disabled]="!enableExports || isLoading", and isExportsEnabled()
//     requires loaded grid data -- so the grid wait is load-bearing, not cosmetic.
//
// Usage: verify-export-vs-grid.mjs <reportUrl> <outJsonPath> [exportName]
// Env:   AMA_UI_USERNAME, AMA_UI_PASSWORD (see run-ui-verify.sh for resolution)
// Exit:  0 ok | 1 login failed | 3 grid never loaded | 4 export button stayed disabled
//        5 export dialog/POST failed | 2 unexpected error
import { chromium } from 'playwright';
import { writeFileSync } from 'fs';

const [, , reportUrl, outJsonPath, exportNameArg] = process.argv;
if (!reportUrl || !outJsonPath) {
  console.error('usage: verify-export-vs-grid.mjs <reportUrl> <outJsonPath> [exportName]');
  process.exit(64);
}
const username = process.env.AMA_UI_USERNAME;
const password = process.env.AMA_UI_PASSWORD;
if (!username || !password) {
  console.error('AMA_UI_USERNAME / AMA_UI_PASSWORD must be set');
  process.exit(64);
}
// No Date.now()-derived default: keep runs reproducible and let the caller name it.
const exportName = exportNameArg || 'claude-export-verify';

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();

const searches = [];
let exportPost = null;
const statusPolls = [];
page.on('response', async r => {
  const u = r.url();
  const path = u.replace(/^https?:\/\/[^/]+/, '');
  const method = r.request().method();
  try {
    if (method === 'POST' && /\/search\//.test(path)) {
      searches.push({ path: path.slice(0, 120), status: r.status(), body: await r.json() });
    } else if (method === 'POST' && /\/export(\?|$)/.test(path)) {
      exportPost = { path, status: r.status(), body: await r.json() };
    } else if (/\/export\/status\//.test(path)) {
      statusPolls.push({ path, status: r.status(), body: await r.json() });
    }
  } catch { /* non-json body: ignore */ }
});

// The NOTIFICATIONS dialog respawns -- re-dismiss before every interaction block, not once.
const dismissDialogs = async () => {
  for (const rx of [/not now/i, /^no thanks$/i]) {
    const b = page.getByRole('button', { name: rx });
    if (await b.first().isVisible().catch(() => false)) {
      await b.first().click({ force: true }).catch(() => {});
      await page.waitForTimeout(300);
    }
  }
};

const waitForRealRows = (timeout = 180000) =>
  page.waitForFunction(() => {
    const cells = document.querySelectorAll('.ag-cell');
    return cells.length > 0 && [...cells].some(c => c.textContent.trim().length > 0);
  }, { timeout });

// Collect the FULL ordered header list despite column virtualisation: read what's
// rendered, scroll right, repeat, merging on col-id and keeping first-seen order.
const collectAllHeaders = async () => {
  const seen = new Map();
  // style.left is per-CONTAINER, not per-grid: ag-grid renders pinned-left, centre and
  // pinned-right columns in three separate containers each starting at left:0. Sorting a
  // merged list by `left` alone interleaves the pinned group-by columns into the middle of
  // the centre columns and silently reports a bogus order mismatch (hit live 2026-08-18).
  // So bucket by container first, then sort by left within each bucket.
  const snapshot = () => page.evaluate(() => {
    const containers = [
      ['.ag-pinned-left-cols-container, .ag-pinned-left-header', 0],
      ['.ag-header-container, .ag-center-cols-container', 1],
      ['.ag-pinned-right-cols-container, .ag-pinned-right-header', 2],
    ];
    const out = [];
    for (const [sel, bucket] of containers) {
      for (const root of document.querySelectorAll(sel)) {
        for (const el of root.querySelectorAll('.ag-header-cell[col-id]')) {
          out.push({
            colId: el.getAttribute('col-id'),
            bucket,
            left: parseFloat(el.style.left || '0') || 0,
            text: (el.querySelector('.ag-header-cell-text')?.textContent || '').trim(),
          });
        }
      }
    }
    // Any header cell not inside a recognised container still gets captured, in the centre
    // bucket, rather than being dropped.
    for (const el of document.querySelectorAll('.ag-header-cell[col-id]')) {
      const id = el.getAttribute('col-id');
      if (!out.some(c => c.colId === id)) {
        out.push({
          colId: id, bucket: 1,
          left: parseFloat(el.style.left || '0') || 0,
          text: (el.querySelector('.ag-header-cell-text')?.textContent || '').trim(),
        });
      }
    }
    return out;
  });

  const viewportSel = '.ag-body-horizontal-scroll-viewport';
  const hasScroller = await page.locator(viewportSel).count() > 0;
  let guard = 0;
  let lastScrollLeft = -1;
  for (;;) {
    for (const c of await snapshot()) if (!seen.has(c.colId)) seen.set(c.colId, c);
    if (!hasScroller || guard++ > 60) break;
    const pos = await page.evaluate(sel => {
      const v = document.querySelector(sel);
      if (!v) return null;
      const before = v.scrollLeft;
      v.scrollLeft = Math.min(before + Math.max(200, v.clientWidth - 100), v.scrollWidth);
      return { before, after: v.scrollLeft, max: v.scrollWidth - v.clientWidth };
    }, viewportSel);
    if (!pos) break;
    await page.waitForTimeout(250);
    if (pos.after === lastScrollLeft || pos.after >= pos.max) {
      for (const c of await snapshot()) if (!seen.has(c.colId)) seen.set(c.colId, c);
      break;
    }
    lastScrollLeft = pos.after;
  }
  // Visual order = container bucket first (pinned-left, centre, pinned-right), then left.
  return [...seen.values()].sort((a, b) => (a.bucket - b.bucket) || (a.left - b.left));
};

let exitCode = 0;
const out = { reportUrl, exportName, grid: {}, export: {}, notes: [] };

try {
  // ---- login ----
  await page.goto(reportUrl, { waitUntil: 'networkidle' });
  const userField = page.locator('input[name="username"], input[formcontrolname="username"]');
  await userField.first().waitFor({ state: 'visible', timeout: 20000 });
  await userField.first().fill(username);
  await page.locator('input[name="password"], input[formcontrolname="password"]').first().fill(password);
  await page.locator('button[name="login"], button[type="submit"]').first().click();
  const cont = page.getByRole('button', { name: /continue/i });
  const loginDeadline = Date.now() + 25000;
  while (page.url().includes('/login') && Date.now() < loginDeadline) {
    if (await cont.isVisible().catch(() => false)) await cont.click().catch(() => {});
    await page.waitForTimeout(500);
  }
  await page.waitForLoadState('networkidle').catch(() => {});
  if (page.url().includes('/login')) { console.error('LOGIN_FAILED'); process.exit(1); }

  // ---- load the report ----
  page.setDefaultTimeout(180000);
  searches.length = 0;
  await page.goto(reportUrl, { waitUntil: 'domcontentloaded' });
  await dismissDialogs();
  try {
    await waitForRealRows();
  } catch {
    out.notes.push('GRID_NEVER_LOADED: no non-empty .ag-cell within 180s');
    out.grid.searchCount = searches.length;
    writeFileSync(outJsonPath, JSON.stringify(out, null, 2));
    console.error('GRID_NEVER_LOADED (searches seen: ' + searches.length + ')');
    process.exit(3);
  }
  await page.waitForTimeout(4000); // let auxiliary /search legs land
  await dismissDialogs();

  out.grid.headers = await collectAllHeaders();
  out.grid.searchResponses = searches.map(s => ({
    path: s.path, status: s.status,
    fromCache: s.body?.FromCache ?? null,
    rowCount: Array.isArray(s.body?.results) ? s.body.results.length : null,
    columns: Array.isArray(s.body?.results) && s.body.results[0] ? Object.keys(s.body.results[0]) : [],
    results: Array.isArray(s.body?.results) ? s.body.results : [],
  }));
  out.grid.headerCount = out.grid.headers.length;

  // ---- trigger the export ----
  const exportBtn = page.locator("button[title='Export Report']");
  if (await exportBtn.count() === 0) {
    out.notes.push("EXPORT_BUTTON_MISSING: no button[title='Export Report'] "
      + '(title becomes "Exporting is not available for trial users" for trial users)');
    writeFileSync(outJsonPath, JSON.stringify(out, null, 2));
    process.exit(4);
  }
  // enableExports flips only once grid data is in; poll rather than assume.
  const enabledBy = Date.now() + 60000;
  while (await exportBtn.first().isDisabled().catch(() => true) && Date.now() < enabledBy) {
    await page.waitForTimeout(1000);
  }
  if (await exportBtn.first().isDisabled().catch(() => true)) {
    out.notes.push('EXPORT_BUTTON_DISABLED after grid load - isExportsEnabled() false '
      + '(trial user, or pagedGridTreeRequestModelChange.size === 0)');
    writeFileSync(outJsonPath, JSON.stringify(out, null, 2));
    process.exit(4);
  }

  await dismissDialogs();
  await exportBtn.first().hover().catch(() => {});
  await exportBtn.first().click({ force: true });

  const nameInput = page.locator('#new-export-report-name-input');
  await nameInput.waitFor({ state: 'visible', timeout: 30000 });
  await nameInput.fill(exportName);

  // isSave also creates a saved report as a side effect -- keep it OFF.
  const saveCb = page.locator('#new-export-save-report-checkbox input[type=checkbox], #new-export-save-report-checkbox');
  if (await saveCb.first().isChecked().catch(() => false)) {
    await saveCb.first().click({ force: true }).catch(() => {});
    out.notes.push('unchecked #new-export-save-report-checkbox (would have saved a report)');
  }

  const confirm = page.locator('#export-report-confirm');
  await confirm.waitFor({ state: 'visible', timeout: 15000 });
  const confirmDeadline = Date.now() + 20000;
  while (await confirm.isDisabled().catch(() => true) && Date.now() < confirmDeadline) {
    await page.waitForTimeout(500);
  }
  await confirm.click({ force: true });

  // ---- wait for POST /export to come back with an id ----
  const postDeadline = Date.now() + 60000;
  while (!exportPost && Date.now() < postDeadline) await page.waitForTimeout(500);
  if (!exportPost) {
    out.notes.push('EXPORT_POST_NOT_SEEN within 60s of confirming the dialog');
    writeFileSync(outJsonPath, JSON.stringify(out, null, 2));
    process.exit(5);
  }
  out.export.post = { status: exportPost.status, body: exportPost.body };
  out.export.exportId = exportPost.body?.Id ?? null;

  const snack = await page.locator('.mat-mdc-snack-bar-label').first().textContent()
    .catch(() => null);
  out.export.snackbar = snack ? snack.trim() : null;

  // Give the app's own status polling a chance to reveal terminal state / file location.
  await page.waitForTimeout(20000);
  out.export.statusPolls = statusPolls.map(p => ({ path: p.path, status: p.status, body: p.body }));

  writeFileSync(outJsonPath, JSON.stringify(out, null, 2));
  console.log('OK exportId=' + out.export.exportId
    + ' headers=' + out.grid.headerCount
    + ' searchResponses=' + out.grid.searchResponses.length
    + ' snackbar=' + JSON.stringify(out.export.snackbar));
} catch (e) {
  out.notes.push('ERROR: ' + String(e).slice(0, 400));
  try { writeFileSync(outJsonPath, JSON.stringify(out, null, 2)); } catch { /* ignore */ }
  console.error('ERROR:', String(e).slice(0, 400));
  exitCode = 2;
} finally {
  // page -> context -> browser, with a networkidle settle: an abrupt close resets a
  // proxied socket and kills a local webpack-dev-server (http-proxy 1.18.1). House pattern.
  await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
  await page.close().catch(() => {});
  await page.context().close().catch(() => {});
  await browser.close().catch(() => {});
  if (exitCode) process.exitCode = exitCode;
}
