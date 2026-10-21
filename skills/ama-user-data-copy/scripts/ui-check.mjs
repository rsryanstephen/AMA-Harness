// ui-check.mjs -- open the copied items IN THE REAL UI as a given user and screenshot them.
// Usage: node ui-check.mjs <manifest.json> <target|source> <out-dir>
//   env: AMA_UI_USERNAME / AMA_UI_PASSWORD (resolve from ~/.claude/.ama-ui-credentials.json +
//        claude_ama_pw in the wrapper, never inline), AMA_UI_BASE (dev server, default :4210)
// Run through ama-ui-verify's with-dev-server.sh so the dev server (proxying to the env) is
// started and torn down around this one check -- see run-ui-check.sh next to this file.
// Checks: My Reports dashboard lists every copied report name; one aggregation report view
// renders grid cells; the cohorts list shows every copied cohort; one regular and one MCF
// cohort report render rows. Each page is screenshotted into out-dir. Exit 1 on any FAIL.
import { readFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { pathToFileURL } from 'url';

const lib = await import(pathToFileURL(join(homedir(), '.claude/skills/ama-ui-verify/scripts/lib-ama-ui.mjs')).href);
const { chromium, login, api, shutdown, BASE } = lib;

const [manifestPath, role, outDir] = process.argv.slice(2);
if (!manifestPath || !role || !outDir) { console.error('usage: node ui-check.mjs <manifest.json> <target|source> <out-dir>'); process.exit(2); }
mkdirSync(outDir, { recursive: true });
const M = JSON.parse(readFileSync(manifestPath, 'utf8'));
const key = role === 'target' ? 'new' : 'old';
// .deleted entries exist only in a move manifest (the whole account moves): never visible in the UI
const reports = (M.reports || []).filter((r) => !r.deleted).map((r) => ({ id: r[key], name: r.name }));
const cohorts = (M.cohorts || []).filter((c) => !c.deleted && (role === 'source' || c.flipped)).map((c) => ({ id: c[key], name: c.name }));
const crs = (M.cohortReports || []).filter((c) => !c.deleted).map((c) => ({ id: c[key], name: c.name }));

let fail = 0;
const P = (ok, msg) => { console.log((ok ? 'PASS  ' : 'FAIL  ') + msg); if (!ok) fail = 1; };
const shot = (page, name) => page.screenshot({ path: join(outDir, `${role}-${name}.png`), fullPage: false });
const waitCells = async (page, timeout = 120000) => {
    try { await page.locator('.ag-cell').first().waitFor({ state: 'visible', timeout }); } catch { return 0; }
    return page.locator('.ag-cell').count();
};

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
try {
    const who = await login(page);
    console.log(`logged in as ${who} (${role})`);

    // 1. My Reports: the dashboard lists saved reports by name (API truth cross-checked too)
    await page.goto(BASE + '/aggregations', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);
    await shot(page, 'my-reports');
    // The dashboard shows the Home folder's rows (subfolders collapsed, long lists below the fold), so the
    // visible-name count is informational; the API listing is the assertion.
    const text = await page.locator('body').innerText();
    const visible = reports.filter((r) => text.includes(r.name)).length;
    console.log(`INFO  ${role}: My Reports page text shows ${visible}/${reports.length} copied report names (others are in subfolders or below the fold)`);
    const listed = await api(page, 'GET', '/report/all');
    const ids = new Set((listed.body || []).map((r) => (r.Id || r.id || '').toLowerCase()));
    P(reports.every((r) => ids.has(r.id.toLowerCase())), `${role}: /report/all as this user returns every copied report id`);
    // custom folders: open each one the copy created and screenshot it
    for (const f of (M.folders || []).slice(0, 3)) {
        const link = page.getByText(f.name, { exact: true }).first();
        if (await link.isVisible().catch(() => false)) {
            await link.click();
            await page.waitForTimeout(2000);
            await shot(page, `folder-${f.name.replace(/[^a-z0-9]+/gi, '_').slice(0, 40)}`);
            const inFolder = await page.locator('body').innerText();
            const expected = reports.filter((r) => (M.reports.find((x) => x.new === r.id || x.old === r.id) || {}).folderPath === f.path);
            console.log(`INFO  ${role}: folder '${f.name}' opened` + (expected.length ? `, ${expected.filter((r) => inFolder.includes(r.name)).length}/${expected.length} expected names visible` : ''));
        }
    }

    // 2. one aggregation report renders grid cells (first non-CMO report, CMO needs roles the target may lack)
    const pick = reports.find((r) => !/CMO/i.test(r.name)) || reports[0];
    if (pick) {
        await page.goto(`${BASE}/aggregations/view/${pick.id}`, { waitUntil: 'networkidle' });
        const cells = await waitCells(page);
        await shot(page, 'report-view');
        P(cells > 0, `${role}: report '${pick.name}' renders ${cells} grid cell(s)`);
    }

    // 3. cohorts list
    await page.goto(BASE + '/dynamic-cohorts', { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);
    await shot(page, 'cohorts');
    const ctext = await page.locator('body').innerText();
    const cmissing = cohorts.filter((c) => !ctext.includes(c.name));
    P(cmissing.length === 0, `${role}: cohorts page shows ${cohorts.length - cmissing.length}/${cohorts.length} copied cohort names`);

    // 4. one regular + one MCF cohort report render rows
    const regular = crs.find((c) => !/UWM|FN MA4877|MCF/i.test(c.name));
    const mcf = crs.find((c) => /UWM/i.test(c.name)) || crs.find((c) => /MCF/i.test(c.name));
    if (regular) {
        await page.goto(`${BASE}/dynamic-cohorts/reports/view/${regular.id}`, { waitUntil: 'networkidle' });
        const cells = await waitCells(page);
        await shot(page, 'cohort-report');
        P(cells > 0, `${role}: cohort report '${regular.name}' renders ${cells} grid cell(s)`);
    }
    if (mcf) {
        await page.goto(`${BASE}/dynamic-cohorts/reports/mcf-header-export/view/${mcf.id}`, { waitUntil: 'networkidle' });
        const cells = await waitCells(page);
        await shot(page, 'mcf-report');
        P(cells > 0, `${role}: MCF cohort report '${mcf.name}' renders ${cells} grid cell(s)`);
    }
} finally {
    await shutdown(page, browser);
}
console.log(fail ? 'ui-check: FAILURES above' : 'ui-check: ALL PASS');
process.exit(fail);
