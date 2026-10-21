// Debug variant of verify-ui.mjs: login, open failing report, dump console errors,
// page errors, and non-2xx API responses (with bodies). PROJ-15261.
import { chromium } from 'playwright';

const [, , url, screenshotPath] = process.argv;
const username = process.env.AMA_UI_USERNAME;
const password = process.env.AMA_UI_PASSWORD;
if (!username || !password) { console.error('creds not set'); process.exit(1); }

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();

page.on('console', msg => {
  if (msg.type() === 'error' || msg.type() === 'warning') {
    console.log(`[console.${msg.type()}] ${msg.text().slice(0, 2000)}`);
  }
});
page.on('pageerror', err => console.log(`[pageerror] ${String(err).slice(0, 2000)}`));
page.on('requestfailed', req => console.log(`[requestfailed] ${req.method()} ${req.url()} -- ${req.failure()?.errorText}`));
page.on('response', async res => {
  if (res.status() >= 400) {
    let body = '';
    try { body = (await res.text()).slice(0, 3000); } catch {}
    console.log(`[http ${res.status()}] ${res.request().method()} ${res.url()}\n${body}`);
  }
});

try {
  await page.goto(url, { waitUntil: 'networkidle' });

  const usernameField = page.locator('input[name="username"], input[formcontrolname="username"]');
  await usernameField.first().waitFor({ state: 'visible', timeout: 15000 });
  await usernameField.first().fill(username);
  await page.locator('input[name="password"], input[formcontrolname="password"]').first().fill(password);
  await page.locator('button[name="login"], button[type="submit"]').first().click();

  const multiLoginContinue = page.getByRole('button', { name: /continue/i });
  const deadline = Date.now() + 20000;
  while (page.url().includes('/login') && Date.now() < deadline) {
    if (await multiLoginContinue.isVisible().catch(() => false)) {
      await multiLoginContinue.click();
    }
    await page.waitForTimeout(500);
  }
  await page.waitForLoadState('networkidle');
  if (page.url().includes('/login')) { console.error('login failed'); process.exit(1); }

  console.log(`[nav] landed on ${page.url()}`);
  // give the grid/API calls extra time after networkidle (lazy chunks, retries)
  await page.waitForTimeout(15000);
  await page.waitForLoadState('networkidle').catch(() => {});
  console.log(`[final-url] ${page.url()}`);
  await page.screenshot({ path: screenshotPath, fullPage: true });
} finally {
  await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
  await page.close().catch(() => {});
  await page.context().close().catch(() => {});
  await browser.close();
}
