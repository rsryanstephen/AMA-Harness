#!/usr/bin/env node
// Headless Cognito login + drive a page, for a running agent with no --chrome session.
// Reads creds from env (AMA_UI_USERNAME/AMA_UI_PASSWORD), never prints them.
//
// Usage: node verify-ui.mjs [--expect-grid] <url> <screenshot-out-path> [css-selector] [css-property]
// Prints computed <css-property> of <css-selector> if both given, always saves a screenshot.
// Exits non-zero on login failure or selector-not-found.
//
// --expect-grid: the page is a report/grid. Wait for at least one rendered ag-grid cell
// before the screenshot, and exit 2 if none appears within 30s. Without it this script
// screenshots on `networkidle`, which fires long before the grid's data call resolves --
// so a grid URL yielded a correct app shell with an EMPTY grid and still exited 0
// (2026-08-13, /aggregations/agency-marketshare, misread as a broken report). A
// verification that cannot fail on its commonest target is worse than none; the flag is
// opt-in only because the same wait would time out on the non-grid pages this is mostly
// used for.

import { chromium } from 'playwright';

const args = process.argv.slice(2);
const expectGrid = args.includes('--expect-grid');
const [url, screenshotPath, selector, cssProp] = args.filter((a) => a !== '--expect-grid');
if (!url || !screenshotPath) {
  console.error('usage: verify-ui.mjs [--expect-grid] <url> <screenshot-out-path> [css-selector] [css-property]');
  process.exit(1);
}

const username = process.env.AMA_UI_USERNAME;
const password = process.env.AMA_UI_PASSWORD;
if (!username || !password) {
  console.error('AMA_UI_USERNAME/AMA_UI_PASSWORD not set -- source the gitignored creds file first');
  process.exit(1);
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();

try {
  await page.goto(url, { waitUntil: 'networkidle' });

  // In-app Angular login form (aws-amplify Auth.signIn), not a hosted-UI redirect --
  // confirmed at exporterplus's login.component.ts. Same form shape for admin.
  const usernameField = page.locator('input[name="username"], input[formcontrolname="username"]');
  await usernameField.first().waitFor({ state: 'visible', timeout: 15000 });
  await usernameField.first().fill(username);
  await page.locator('input[name="password"], input[formcontrolname="password"]').first().fill(password);

  // exporterplus's Sign-in button has no type="submit" -- relies on the form's (ngSubmit),
  // confirmed at login.component.html. Try that shape first, fall back to a real submit button.
  await page.locator('button[name="login"], button[type="submit"]').first().click();

  // networkidle after the click fires too early -- the Cognito auth call itself is still
  // in flight ("Attempting to sign you in" spinner), and the "User Sessions" multi-login
  // dialog (title exact, buttons CANCEL/CONTINUE) can appear at any point in that window --
  // confirmed it can show up well after a single 5s check would catch it. Poll for both
  // navigation away from /login AND the dialog appearing, in the same loop.
  const multiLoginContinue = page.getByRole('button', { name: /continue/i });
  const deadline = Date.now() + 20000;
  while (page.url().includes('/login') && Date.now() < deadline) {
    if (await multiLoginContinue.isVisible().catch(() => false)) {
      await multiLoginContinue.click();
    }
    await page.waitForTimeout(500);
  }
  await page.waitForLoadState('networkidle');

  if (page.url().includes('/login')) {
    console.error('still on /login after submit -- credentials rejected or form shape changed');
    await page.screenshot({ path: screenshotPath });
    process.exit(1);
  }

  if (expectGrid) {
    // Non-empty .ag-cell set = the grid rendered rows. Same waitForFunction the skill's
    // "Bootstrapping test data" section prescribes for READING a grid.
    const gridOk = await page
      .waitForFunction(() => document.querySelectorAll('.ag-cell').length > 0, null, { timeout: 30000 })
      .then(() => true)
      .catch(() => false);
    if (!gridOk) {
      await page.screenshot({ path: screenshotPath, fullPage: true });
      console.error('--expect-grid: no ag-grid cells rendered within 30s -- the screenshot is an EMPTY grid, not evidence');
      process.exit(2);
    }
    console.log(`grid rendered: ${await page.locator('.ag-cell').count()} cells`);
  }

  await page.screenshot({ path: screenshotPath, fullPage: true });

  if (selector && cssProp) {
    const el = page.locator(selector).first();
    await el.waitFor({ state: 'attached', timeout: 10000 });
    const value = await el.evaluate((node, prop) => getComputedStyle(node)[prop], cssProp);
    console.log(`${selector} computed ${cssProp}: ${value}`);
  }
} finally {
  // Close gracefully (page/context first, wait for any in-flight request) before
  // browser.close() -- a bare browser.close() while a proxied request is still mid-flight
  // resets that socket, and webpack-dev-server's http-proxy 1.18.1 re-emits an unguarded
  // 'error' on it, crashing the whole dev server (confirmed root cause of a recurring
  // ECONNRESET crash, <harnessEpicKey>). This ordering is the actual fix, not the dev
  // server's flags.
  await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
  await page.close().catch(() => {});
  await page.context().close().catch(() => {});
  await browser.close();
}
