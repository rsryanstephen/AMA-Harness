// Reusable pieces for driving exporterplus/admin headless over MULTIPLE steps, where
// run-ui-verify.sh (one-shot: navigate, screenshot, read one computed style) is not enough:
// open a dialog, click something, assert, click again.
//
// Import from a scratchpad script -- a throwaway script cannot resolve `playwright` as a
// bare specifier, so this module resolves it by absolute path and re-exports `chromium`.
//
//   import { chromium, login, api, shutdown, BASE } from
//       'file:///C:/Users/<you>/.claude/skills/ama-ui-verify/scripts/lib-ama-ui.mjs';
//
// Creds come from AMA_UI_USERNAME/AMA_UI_PASSWORD -- never hardcode or print them. See
// SKILL.md for resolving the test username out of ~/.claude/.ama-ui-credentials.json and
// the password out of the claude_ama_pw env var.
import { pathToFileURL } from 'url';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));

// index.mjs, never index.js -- the CJS entry resolves under ESM but yields undefined.
export const { chromium } = await import(pathToFileURL(join(here, 'node_modules/playwright/index.mjs')).href);

// Default local dev-server port for exporterplus in this skill (admin uses 4211).
export const BASE = process.env.AMA_UI_BASE || 'http://localhost:4210';

/**
 * Signs in through the in-app Cognito form and ASSERTS which account was reached.
 * Throws rather than continuing if it is not `username` -- a real browser profile can hold
 * a stale token for somebody else, and silently acting as them is the worst outcome here.
 */
export async function login(page, username = process.env.AMA_UI_USERNAME, password = process.env.AMA_UI_PASSWORD) {
    if (!username || !password) throw new Error('AMA_UI_USERNAME/AMA_UI_PASSWORD not set');

    await page.goto(BASE + '/', { waitUntil: 'networkidle' });

    const usernameField = page.locator('input[name="username"], input[formcontrolname="username"]');
    await usernameField.first().waitFor({ state: 'visible', timeout: 20000 });
    await usernameField.first().fill(username);
    await page.locator('input[name="password"], input[formcontrolname="password"]').first().fill(password);
    // exporterplus: button[name="login"]. admin: a bare <button mat-raised-button>Sign in</button>
    // inside the form -- no name, no explicit type attribute -- so match it by text as well.
    await page.locator('button[name="login"], button[type="submit"], form button:has-text("Sign in")').first().click();

    // The "User Sessions" multi-login dialog can appear well after submit -- poll for it.
    const multiLoginContinue = page.getByRole('button', { name: /continue/i });
    const deadline = Date.now() + 30000;
    while (page.url().includes('/login') && Date.now() < deadline) {
        if (await multiLoginContinue.isVisible().catch(() => false)) await multiLoginContinue.click();
        await page.waitForTimeout(500);
    }
    await page.waitForLoadState('networkidle');

    if (page.url().includes('/login')) {
        throw new Error('still on /login after submit -- credentials rejected or form shape changed');
    }

    const who = await page.evaluate(() => {
        const k = Object.keys(localStorage).find((x) => x.endsWith('.idToken'));

        return k ? JSON.parse(atob(localStorage.getItem(k).split('.')[1]))['cognito:username'] : null;
    });

    if (who !== username) {
        throw new Error(`logged in as ${who}, expected ${username} -- refusing to act as another account`);
    }

    return who;
}

/**
 * Same-origin fetch through the dev-server proxy, carrying the app's own access token.
 * Use it to SEED and to ASSERT: building a cohort/report by clicking through the UI is slow
 * and flaky, and these are the very endpoints the UI calls. Drive the UI for the thing under
 * test, not for the fixtures around it.
 *
 * `.accessToken` -- `.idToken` 401s on these APIs.
 */
export async function api(page, method, path, body) {
    return page.evaluate(
        async ({ method, path, body }) => {
            const k = Object.keys(localStorage).find((x) => x.endsWith('.accessToken'));
            const res = await fetch(path, {
                method,
                headers: { Authorization: 'Bearer ' + localStorage.getItem(k), 'Content-Type': 'application/json' },
                body: body ? JSON.stringify(body) : undefined
            });
            const text = await res.text();
            let parsed = null;
            try { parsed = JSON.parse(text); } catch { /* not json */ }

            return { status: res.status, body: parsed, raw: parsed ? null : text.slice(0, 400) };
        },
        { method, path, body }
    );
}

/**
 * Attaches console/pageerror/failed-request/response logging. Call BEFORE the action under
 * test: these only capture from attach time onward, and without them a stuck UI can only be
 * guessed at. `urlFilter` keeps the noise down (e.g. /\/cohort(\/|\?|$)/).
 */
export function instrument(page, log = console.log, urlFilter = null) {
    page.on('console', (m) => {
        if (m.type() === 'error' || m.type() === 'warning') log(`[console:${m.type()}] ${m.text().slice(0, 300)}`);
    });
    page.on('pageerror', (e) => log(`[pageerror] ${e.message.slice(0, 300)}`));
    page.on('requestfailed', (r) => log(`[requestfailed] ${r.method()} ${r.url()} ${r.failure()?.errorText}`));
    page.on('response', (r) => {
        if (urlFilter && !urlFilter.test(r.url())) return;
        log(`[http] ${r.request().method()} ${r.url().replace(BASE, '')} -> ${r.status()}`);
    });
}

/**
 * Closes page/context BEFORE browser.close(). A bare browser.close() while a proxied request
 * is in flight resets that socket, and webpack-dev-server's http-proxy 1.18.1 re-emits an
 * unguarded 'error' on it, killing the whole dev server. This ordering IS the fix.
 */
export async function shutdown(page, browser) {
    await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
    await page.close().catch(() => {});
    await page.context().close().catch(() => {});
    await browser.close();
}
