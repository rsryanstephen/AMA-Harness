#!/usr/bin/env node
// Post-fix validation: drive a template report twice on deployed Staging and print the
// FromCache flag from every /search/* POST response body (the user's DevTools check).
import { pathToFileURL } from 'url';
const { chromium } = await import(
  pathToFileURL('C:/Users/your.windows.username/.claude/skills/ama-ui-verify/scripts/node_modules/playwright/index.mjs').href
);

const [, , reportUrl, outPrefix] = process.argv;
const username = process.env.AMA_UI_USERNAME;
const password = process.env.AMA_UI_PASSWORD;

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
let batch = [];
page.on('response', async r => {
  const u = r.url();
  if (/\/search\/[a-z-]+\?/.test(u) && r.request().method() === 'POST') {
    try {
      const j = await r.json();
      batch.push({ q: u.replace(/^https?:\/\/[^/]+/, '').slice(0, 70), status: r.status(), fromCache: j?.FromCache ?? '(absent)' });
    } catch { batch.push({ q: u.slice(0, 70), status: r.status(), fromCache: '(non-json)' }); }
  }
});

const waitForRealRows = (timeout = 120000) =>
  page.waitForFunction(() => {
    const cells = document.querySelectorAll('.ag-cell');
    return cells.length > 0 && [...cells].some(c => c.textContent.trim().length > 0);
  }, { timeout });

try {
  await page.goto(reportUrl, { waitUntil: 'networkidle' });
  const userField = page.locator('input[name="username"], input[formcontrolname="username"]');
  await userField.first().waitFor({ state: 'visible', timeout: 20000 });
  await userField.first().fill(username);
  await page.locator('input[name="password"], input[formcontrolname="password"]').first().fill(password);
  await page.locator('button[name="login"], button[type="submit"]').first().click();
  const cont = page.getByRole('button', { name: /continue/i });
  const deadline = Date.now() + 25000;
  while (page.url().includes('/login') && Date.now() < deadline) {
    if (await cont.isVisible().catch(() => false)) await cont.click();
    await page.waitForTimeout(500);
  }
  await page.waitForLoadState('networkidle').catch(() => {});
  if (page.url().includes('/login')) { console.error('LOGIN_FAILED'); process.exit(1); }

  batch = [];
  await page.goto(reportUrl, { waitUntil: 'domcontentloaded' });
  await waitForRealRows();
  await page.waitForTimeout(3000); // let auxiliary search calls land
  console.log('LOAD1 search responses:');
  batch.forEach(r => console.log(' ', JSON.stringify(r)));
  const load1 = batch.splice(0);

  await page.reload({ waitUntil: 'domcontentloaded' });
  await waitForRealRows();
  await page.waitForTimeout(3000);
  await page.screenshot({ path: `${outPrefix}-load2.png` });
  console.log('LOAD2 search responses:');
  batch.forEach(r => console.log(' ', JSON.stringify(r)));

  const hit = n => n.filter(r => r.fromCache === true).length;
  console.log(`SUMMARY load1: ${hit(load1)}/${load1.length} fromCache; load2: ${hit(batch)}/${batch.length} fromCache`);
} catch (e) {
  console.error('ERROR:', String(e).slice(0, 300));
  process.exitCode = 2;
} finally {
  await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
  await page.close().catch(() => {});
  await page.context().close().catch(() => {});
  await browser.close();
}
