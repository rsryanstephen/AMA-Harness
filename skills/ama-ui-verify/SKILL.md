---
name: ama-ui-verify
description: Drive a real exporterplus/admin page (login, navigate, screenshot, computed CSS) unattended, headless. Use to debug a UI bug (inspect rendered state FIRST, before fixing) or verify a fix before deploy. Companion to `claude --chrome` -- use when already running without it, or the check must run unattended. Standing rule for all admin/exporterplus work: self-verify -> fix loop -> user local sign-off, before any deploy.
---

# Unattended UI debugging & verification (Playwright)

## Two uses -- debug first, then verify

1. **Debugging.** Use this skill as the FIRST step investigating a UI bug, not just the
   last step confirming a fix. Screenshot the actual current rendered state, read real
   computed CSS, check the browser console -- before writing any fix, not only after.
   Guessing root cause from reading source alone misses runtime-only state (actual
   computed styles, real data shapes, console errors) this skill can just show you.
2. **Verification.** After a fix, self-verify it -- see the standing rule below for the
   full loop-then-signoff sequence this now requires before any deploy.

## Two self-verify methods -- pick by whether Chrome tools are available in-session

| | `claude --chrome` / chrome-by-default | this skill (Playwright) |
|---|---|---|
| When chosen | at launch (flag, or `claudeInChromeDefaultEnabled`) | any time, mid-session |
| Login | user's real browser, already logged in | own dedicated test-user creds, headless |
| Attendance | none once logged in -- pauses only at a login page it doesn't hold, or a CAPTCHA; tools are server-allowlisted (`mcp__claude-in-chrome`), no per-click prompts | none |
| Use when | tools present (chrome-by-default machines: always), Chrome running | Chrome closed, machine without the opt-in, or those two repos' standard loop |

**Never claim a session lacks `--chrome` without probing.** On a chrome-by-default
machine (`claudeInChromeDefaultEnabled: true` in `~/.claude.json`) the
`mcp__claude-in-chrome__*` tools are ALWAYS in the session's deferred-tool list --
`ToolSearch("select:mcp__claude-in-chrome__tabs_context_mcp")` resolving is the only
valid test, a glance is not (session a3d73cec asserted absence while the tools sat in
its own list). Resolves -> just use them. Genuinely no match -> the default is off on
this machine or the session predates it -- only then suggest
`claude --continue --chrome` (reattaches, no work lost).

**Prerequisites are NOT your problem -- don't re-litigate them.** Extension installed,
extension version, plan type, `/login`-vs-API-key auth: all settled at install time
(`/harness-setup` step 5b, prereq table in `AGENTS.md`). Treat Chrome as available and
just try the call. **The ONE thing to ask the user for: Chrome not running.** A call
reporting no connected browser / extension not connected means exactly that -- ask them
to open Chrome, then retry the same call. Don't silently drop to headless Playwright
instead of asking; that's how a verification quietly gets weaker than it looks.

Mechanical nudge exists too: `chrome-verify-nudge.sh` (PreToolUse on `Skill`, fires for
`ama-ui-verify`/`ama-report-debug`/`verify`/`run`) -- it reads `~/.claude.json` itself
and branches: default ON -> states the tools are present, forbids the absence claim;
OFF -> suggests the relaunch. **Narrow trigger, don't rely on it alone**: reading this
file directly (ToolSearch result, prior context, a linked reference) never fires it.

Driving via `--chrome` has its own confirmed pitfalls (real-account safety, dead-stub
buttons, tool-arming order) -- read `references/chrome-driving-pitfalls.md` before
using it.

**Screenshot discipline when driving via `--chrome`** -- `computer` screenshots are
base64 and stay in context for the rest of the session (confirmed the biggest single
driver of claude-in-chrome's token cost). Default to `get_page_text`/`read_page` (text)
for confirming state; reach for a `computer` screenshot only when the check is genuinely
visual (layout, CSS, rendering) -- one per verification step, not per action.
`resize_window` smaller first if full resolution isn't needed. Close the tab
(`tabs_close_mcp`) once the loop ends, and recommend `/compact` right after -- the
images have served their purpose. `chrome-verify-compact-nudge.sh` backs this up
mechanically (fires on `tabs_close_mcp`, feeds [[context-hygiene]]'s per-session
notice) in case the recommendation gets missed in the reply.

## Self-verify -> fix loop, then user sign-off -- standing rule for ALL UI work

Applies to any `admin`/`exporterplus` change, before ANY deploy (QA via a plain
`develop` push, Staging via a release/hotfix branch push, or Production) -- not just
hotfix flows. In order, every time:

1. **Self-verify** the fix against a local dev server, using this skill (Step 0's
   compiled-CSS check or the full flow below) or `--chrome`.
2. **If broken or regressed, fix it and re-run step 1.** Loop until the original issue
   AND any regressions the fix may have introduced are actually resolved -- not a single
   pass. This is Claude's own quality gate, done before involving the user at all.
3. **Only then** ask the user to do their own local dev-server run as final sign-off.
4. **Only after** the user's explicit go-ahead does the push/deploy happen.

Additive to the user's own check, never a replacement -- the user's sign-off in step 3
is still the hard gate before step 4, same as [[ama-cloudwatch-search]]'s
Staging-verify-then-go-ahead rule. Claude's own loop comes first and must actually
converge before the user is asked to look at anything; applies to a plain `develop`/QA
push too, not only Staging-bound branches.

## Dedicated test users -- six accounts, never the user's own

MFA on a personal account would block headless login entirely, defeating the point.
Six dedicated Cognito users exist, one per env x tier combo, MFA off. **This table shows
this adopter's actual usernames as a real worked example — a different adopter's are
whatever their own `.ama-ui-credentials.json` (below) contains, don't assume this exact
naming pattern is universal:**

| | tier3500 | tier1800 |
|---|---|---|
| qa | `claude_qa_3500` | `claude_qa_1800` |
| staging | `claude_st_3500` | `claude_st_1800` |
| production | `claude_prod_3500` | `claude_prod_1800` |

**A `production` user exists too -- treat picking it as a deliberate escalation**, not a
default. Only use it for the actual post-deploy production check in
[[ama-deploy-release]]'s flow, not routine fix verification (that's `qa`/`staging`).

**`tier1800` cannot access Dynamic Cohorts or Cohort Reports** -- a lower-tier plan
restriction, not a bug. If verifying a fix in either area, use `tier3500`; a permission-
denied error under `tier1800` there is expected, not a regression to chase.

All six share one password. Usernames live in `~/.claude/.ama-ui-credentials.json`
(gitignored -- confirm with `git check-ignore ~/.claude/.ama-ui-credentials.json`, same
handling as `.credentials.json`). The password itself is **not** stored in this file --
history showed a plaintext `password` field here once got committed inside a chat log in
a different (private) repo before being redacted, so the field was removed entirely.
Env var is now the only local path:

```json
{
  "passwordEnvVar": "claude_ama_pw",
  "users": {
    "qa": { "tier3500": "claude_qa_3500", "tier1800": "claude_qa_1800" },
    "staging": { "tier3500": "claude_st_3500", "tier1800": "claude_st_1800" },
    "production": { "tier3500": "claude_prod_3500", "tier1800": "claude_prod_1800" }
  }
}
```

`run-ui-verify.sh:28-33` still checks `.password` first for back-compat, but falls
through to the named env var (`claude_ama_pw` -- gitignored/local-only either way) when
the field is absent, which it now always is for a fresh setup.

**Setup is a one-time, adopter-side step run at harness install ([[harness-setup]]),
not something Claude fetches each session.** Source of truth is the Octopus library
variable set `Claude Harness` (`LibraryVariableSets-261`), variable
`AmaUiTestUserPassword`, deliberately **non-sensitive** (Octopus never returns a value
for a variable flagged sensitive -- flipping it to sensitive as a "hardening" pass
breaks the fetch below, it does not harden anything). The set is unattached to any
project, so it never enters a release snapshot and cannot affect a deploy.

```bash
PW="$(curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" \
      "https://yourorg.octopus.app/api/Spaces-1/variables/variableset-LibraryVariableSets-261" \
      | jq -r '.Variables[] | select(.Name=="AmaUiTestUserPassword") | .Value')"
case "$PW" in ''|null) echo "Octopus fetch failed -- check OCTOPUS_API_KEY, variable name" >&2;; *)
  printf 'export claude_ama_pw=%q\n' "$PW" >> ~/.bashrc && source ~/.bashrc ;;
esac; unset PW
```

The empty/`null` guard matters: a bad API key or renamed variable both make `jq -r`
emit `null`, and `export claude_ama_pw=null` would otherwise pass `run-ui-verify.sh:33`'s
`:?` check silently and surface later as a confusing Cognito login failure instead of a
loud missing-var error. A different org adopting this harness has no access to
`LibraryVariableSets-261` -- they create their own `Claude Harness` set with a
`AmaUiTestUserPassword` variable and swap the id above for theirs, same as any other
per-adopter Octopus id in this harness.

**Never print the resolved password.** Assign to a variable or redirect to a file --
never a bare `curl ... | jq` that dumps the value to stdout. Two tiers exist because they
may hit different UI paths (role/plan-gated features, the multi-login dialog) -- pick
whichever tier matches what the fix under test actually affects; default to `tier3500`
if it doesn't matter. All six confirmed present + `Enabled: True` (via `aws cognito-idp
list-users`) -- see the pool table below.

## Where the six users actually live -- three Cognito User Pools, not in any repo

There's no provisioning script for these anywhere in this harness or the app repos --
they were created directly in Cognito, so don't go looking for an IaC/script source of
truth. To find or manage them yourself (console or CLI), region **us-east-1**:

| env | pool name | pool id |
|---|---|---|
| qa | `HS_Exporter_qa` | `us-east-1_EZPzT4PvW` |
| staging | `HS_Exporter_Staging` | `us-east-1_mAGKqTZ5f` |
| production | `HS_Exporter_Prod` | `us-east-1_lTBs66UDQ` |

Console: Cognito -> User pools -> pick the pool above -> Users tab -> filter `claude_`.
CLI: `aws cognito-idp list-users --user-pool-id <id> --region us-east-1 --filter 'username ^= "claude_"'`.

**Claude test users can open ANY user's report by direct URL, unshared** -- see the
direct-URL-vs-folder-listing gotcha below.

**What the grid RENDERS is identity-independent** -- same columns, criteria, data as the
owner sees. Don't caveat a grid-vs-export comparison with "but I'm not the owner".

**One exception: `tier1800` cannot view data for any organisation but its own.** Comparing
a cross-org report as `tier1800` shows the wrong data, not a bug. Use `tier3500` for that.

## Step 0 -- check the compiled stylesheet BEFORE logging in at all

For a pure CSS/SCSS fix, don't jump straight to the full login flow -- fetch the dev
server's served global stylesheet and grep for the changed rule directly. No login, no
test data, no browser needed -- sidesteps unrelated login/data-access gaps entirely.

```bash
bash ~/.claude/skills/ama-ui-verify/scripts/check-compiled-css.sh <dev-server-url> <grep-pattern>
```

Only covers **global** styles (anything reached from `angular.json`'s `styles` array,
e.g. `styles.scss` and its imports) -- component-scoped styles are inlined into JS at
runtime, not in this file. If the pattern isn't found and the fix IS component-scoped,
that's expected -- fall through to the full flow below instead.

## Running the full flow -- login, navigate, screenshot, computed CSS

Only needed when Step 0 doesn't apply (component-scoped style) or the fix must be
confirmed against a real rendered element's actual computed value, not just that it
compiled.

Runs against a LOCAL dev server serving the branch under test, not deployed QA.
**Use a dedicated port, not the human default** -- Your Name usually has his own dev server
running on 4200/4201, per [[ama-architecture-notes]]'s `FRONTEND-ARCHITECTURE.md`. This
skill's own confirmed-working port: **4210** for exporterplus, **4211** for admin.
Launch it yourself (the wrapper doesn't manage the dev server):

```bash
npx ng serve --proxy-config proxy.config.qa-ecs.json --configuration localqa --port 4210 --live-reload=false
```

**Always use the `npm run start:<env>` script name for anything other than a custom port
override** -- `start:qa`/`start:staging`/`start:prod` are the only correct invocations
(there is no `start:localqa`/`start:localstaging`/`start:localprod` script). The
in-repo config chain (`environment.localstaging.ts`, `proxy.config.staging-ecs.json`,
`angular.json`'s configurations) IS fine -- but `start:<env>` needs one more file that
ISN'T in the repo: `src/assets/config/config.local<env>.json`, a gitignored,
machine-local secret (`.gitignore`'s `src/assets/config/*`). **Often missing for
`staging`** (present only if manually restored on that machine, unlike the more commonly
restored `config.localqa.json`/`config.localprod.json`). Missing file -> `start:<env>`
404s on it and the app never boots.

**Don't just report it's missing -- reconstruct it yourself, every time, any machine.**
The live deployed site itself serves the real, already-substituted values -- no backup
file or lucky prior restoration needed:

```bash
curl -s "https://<app.domains.qa-or-staging from harness-config.json>/" | sed -n '/window\.env = $/,/^;$/p' | sed '1d;$d' | jq . > src/assets/config/config.local<env>.json
```

(Production is `app.domains.prod`, no subdomain.) exporterplus bakes
its runtime config into `index.html` as `window.env = {...}` at build time (not a
separately-fetched `config.json` -- see [[ama-architecture-notes]]'s
`FRONTEND-ARCHITECTURE.md`), and the SPA fallback route serves `index.html` for any
path, so hitting the domain root always returns it. **Safe to do** -- every value here
is a client-shipped identifier by design (Cognito pool/client IDs, Firebase client
keys, Flagsmith environment ID, App Insights key), not a server secret.

A stale local backup file is NOT a substitute for this -- trust the live fetch as the
source of truth, every field, every time.

`--live-reload=false` is added above for the crash-prevention reason below -- this skill
doesn't need live-reload for a one-shot check.

**If the live-fetch reconstruction above isn't possible for some reason (network
blocked), a `qa` fallback is NOT always equivalent** -- `qa`'s config points at a
different Cognito user pool than `staging`. If the fix under test needs a SPECIFIC
staging-only credential/state (e.g. a temp-password/forced-change flow tied to one
particular staging user), `qa` cannot exercise it at all -- flag this to the user and
ask for their own local sign-off on Staging instead of reporting a false pass.

**Launch the dev server via the Bash tool's own `run_in_background: true`, not a manual
`nohup ... &`** -- the latter's process gets silently orphaned/killed in this
environment.

```bash
bash ~/.claude/skills/ama-ui-verify/scripts/run-ui-verify.sh <env: qa|staging|production> <tier: 3500|1800> <url> <screenshot-out-path> [css-selector] [css-property]
```

Logs in via the in-app username/password form (aws-amplify `Auth.signIn`, not a hosted-UI
redirect), navigates to `<url>`, screenshots it, and -- if a selector+property are given --
prints the element's computed CSS value. Exits non-zero if login fails or the selector
never appears.

**Verifying CACHING behavior (FromCache flags) or driving Curve Analyzer** -- see
[CURVE-ANALYZER-DRIVING.md](CURVE-ANALYZER-DRIVING.md) (selector traps + the
response-body FromCache assertion pattern) and `scripts/drive-report-fromcache.mjs`
(usage: `node drive-report-fromcache.mjs <reportUrl> <outPrefix>`, needs
`AMA_UI_USERNAME`/`AMA_UI_PASSWORD` env -- drives a report twice, prints every
`/search/*` POST's FromCache flag).

**It screenshots on `networkidle` only -- it does NOT wait for ag-grid rows, so any
report/grid URL yields a blank-content screenshot and still exits 0.** Confirmed live
2026-08-13: `/aggregations/agency-marketshare` produced a correct app shell with an empty
grid area, easily misread as a broken report. `networkidle` fires long before the grid's
data call resolves. For any grid page, don't use this script's screenshot as evidence --
write a scratchpad script that waits for a non-empty `.ag-cell` first (the same
`waitForFunction` in "Bootstrapping test data" below, which applies to *reading* a grid,
not just saving one). Deliberately not changed in the script itself: a grid wait would
time out on the non-grid pages it's mostly used for.

**Confirmed end-to-end**: headless login, the "User Sessions"
multi-login dialog (CANCEL/CONTINUE buttons, can appear well after submit -- poll for it,
don't check once), and computed-CSS reads all work against a real local exporterplus
dev server.

**Angular Material components with a wrapper/ripple div fail a plain `.click()`** --
`mat-tab`, card links inside `mat-card`, toolbar buttons. Use `.click({ force: true })`
or hover-then-click (the existing `ui-testing` C# suite always hovers before clicking
these).

**Known limitation: `verify-ui.mjs` only drives the standard sign-in form.** Cognito's
`NEW_PASSWORD_REQUIRED` challenge (a temp/forced-change password flow, distinct from
normal sign-in) isn't handled -- verifying that flow needs a separate script.

## Testing async loading states (spinners, disabled-during-request) -- delay the call

A UI's loading state (spinner, disabled button while a request is in flight) can be
impossible to screenshot reliably as-is: if the underlying call rejects/resolves
synchronously (e.g. hits a stub or fails fast), the loading UI never gets a frame to
paint before the state already flipped back. Route-intercept the network call and
inject a real delay (even ~2s) before letting it resolve, so the loading state has
actual wall-clock time to render and be captured.

## `ng serve` crash prevention -- real root cause, not just "restart and hope"

`webpack-dev-server` 4.11.1 proxies through `http-proxy` 1.18.1. When Playwright's
`browser.close()` kills chromium abruptly mid-request, the proxied target socket resets
and `http-proxy` re-emits an unguarded error -- Node throws fatal, dev server dies. Fixed
at the source in `verify-ui.mjs`: page/context close (with a short `networkidle` wait)
BEFORE `browser.close()`, never a bare abrupt close. Combined with `--live-reload=false`
above (removes one more persistent socket). If it still crashes despite both: restart the
dev server once and retry -- don't loop forever, and don't treat one crash as proof the
fix is broken.

## Direct-URL view access ≠ appearing in the account's own report list

(PROJ-15177) Don't repeat these two falsified guesses: NOT "test users lack
any-user access" (direct-URL cross-user open works fine); NOT "search matches Name not
Id" (`MatTableDataSource`'s default filter predicate stringifies every field incl. Id).

Folder listings (`Home`/`Shared with me`, from `GET /report/folder/<folderId>`) come from
actual folder-share membership -- a separate mechanism from admin/elevated view access. A
report someone else owns that you can only view via elevated permission never appears in
your report-list UI, by any search term -- you can only exercise its in-report view
(`/aggregations/view/<id>`), never its list-row Query Description.

If a fix specifically needs to compare list-row vs in-report text for a REAL, pre-existing
report you don't own: either get it folder-shared to the test account (not just admin
view), or use a **fresh report the test account itself saves** as a mechanism proof instead
(see "Bootstrapping test data" above) -- that's a valid substitute for confirming the code
path works, just not proof for that specific pre-existing report's data.

## Bootstrapping test data -- creating a report when the test user has none

There's no "New Report" button -- a report is created by opening a **Template card** and
saving it. Reference implementation: `ui-testing/Tests/ReportsFixture.cs`
(`SaveAndDeleteReportFlow`) + `PageObjects/Exporter/{AggregationsDashboardPage,
AggregationsPage,SaveReportPage}.cs` -- port selectors from there if the app changes,
don't re-derive from scratch.

1. Dismiss the first-load "Not Now" interstitial dialog if present.
2. The Templates panel is a `mat-expansion-panel`, expanded by default but its content is
   lazy-rendered (`matExpansionPanelContent`) -- wait for a card to actually appear before
   clicking, don't assume it's there immediately on page load.
3. Click the **`Agency Marketshare`** template card's **VIEW** link (simplest,
   always-present template) -- hover-then-click, not a plain `.click()`. Navigates to
   `/aggregations/agency-marketshare` (kebab-case) -- a `waitForURL` on the wrong case
   times out even though nav already succeeded.
4. **Wait for the grid to actually finish loading real data, not just navigation** --
   wait for real row data, not `networkidle` alone. Applies to the **save** step too, not
   just screenshots -- a premature Save click can catch the grid still on its skeleton and
   the save silently never completes. Wait for a non-empty `.ag-cell` first:
   ```js
   await page.waitForFunction(() => {
     const cells = document.querySelectorAll('.ag-cell');
     return cells.length > 0 && [...cells].some(c => c.textContent.trim().length > 0);
   });
   ```

5. Click the **Save Report** toolbar button (`[title='Save Report']`).
6. Fill `#saved-report-name` -- the only required field (non-empty, <=64 chars, no
   `< > ; \ &`), and the sole gate on the Save button's `disabled` state.
7. Click `#save-report-confirm`.
8. **Assert the save toast immediately, short timeout, not a leisurely wait.** It's
   `MatSnackBar`, 2000ms auto-dismiss, text in `.mat-mdc-snack-bar-label`.

   A `text=...` locator can miss purely on timing if checked past the 2s window.

9. Confirm creation via the saved-reports search box, `#report-search-v2-input`.

## Testing zoom-dependent behavior -- use the real buttons, not synthetic wheel events

Material 15 renders `mat-mdc-*` classes, not `mat-fab`/`mat-mini-fab` -- see
[[ama-architecture-notes]] FRONTEND-ARCHITECTURE.md's Styling section.

- Zoom out: `.zoom-out-button` (also carries `.mat-mdc-mini-fab`)
- Zoom in: `.grid-zoom-button.mat-mdc-fab` (not `.mat-fab`)
- Current zoom label: `.grid-zoom-value`

Synthetic Ctrl+wheel zoom is unreliable (one run hung 2.5 minutes, hard-killed) --
drive the real buttons above instead.

## Writing verification scripts -- use the Write tool, not a bash heredoc

Large heredocs silently mangle/truncate -- see [[bash-command-style]].

## Confirmed selectors -- report/description UI (PROJ-15177)

Cheaper to copy than re-derive from source each run:

| what | selector | note |
|---|---|---|
| in-report description toggle | `[title='Show Query Description']` | icon button, title attr not text -- `getByText(/show query description/i)` never matches. Flips to `Hide Query Description` once open. `[disabled]` until `gridConfig?.gridState?.previousQuery` set -- wait for real grid data first, not just visible. |
| in-report query description | `#query_description` | |
| in-report report description | `#report_description` | |
| list query description | `.report-detail:has(h5:text("Query Description")) p` | |
| report list info toggle | `#report-list-info-btn` | |
| report search box | `#report-search-v2-input` | |
| save dialog | `#saved-report-name`, `#save-report-confirm` | |
| Save Report toolbar button | `[title='Save Report']` | **Resolves to the inner `mat-icon`, not the button** — a `.click({force:true})` on it can leave the dialog unopened (confirmed 2026-08-17: element visible + not disabled, `#saved-report-name` still timed out). Click the enclosing `button` (`page.locator("button:has([title='Save Report'])")`) or hover-then-click. Still not opening → stop and use `--chrome`, the save flow is known-good there. |

## One-off scratchpad script can't `import playwright` directly

3 fails, avoid all:

- Throwaway scripts never go in `~/.claude/skills/...` -- use the session scratchpad
  (see [[write-a-skill]]'s skills-directory note for why Write fails there).
- Scratchpad script can't resolve `playwright` as a bare import -- not in its own
  `node_modules`, and `NODE_PATH` does NOT work for ESM. Fix:
  ```js
  import { pathToFileURL } from 'url';
  const { chromium } = await import(
    pathToFileURL('C:/Users/your.windows.username/.claude/skills/ama-ui-verify/scripts/node_modules/playwright/index.mjs').href
  );
  ```
- Import `index.mjs` not `index.js` -- `index.js` is CJS, resolves under ESM but
  `chromium` comes back `undefined` -> `Cannot read properties of undefined ('launch')`.
  Bare Windows path in `import()` also throws `ERR_UNSUPPORTED_ESM_URL_SCHEME` -- always
  wrap `pathToFileURL(...).href`.

## Fail fast on a state that may legitimately not exist

Don't `waitFor` a selector that depends on data/permission that might just not be there
(report not in this account's folder listing at all -- see direct-URL-vs-list-membership
gotcha above, empty search) -- burns full timeout, throws misleading `TimeoutError`
instead of the real cause. Check the negative case first, exit with a clear reason:
```js
if (await page.getByText('0 of 0').isVisible().catch(() => false)) {
  console.log('REPORT_NOT_IN_ACCOUNT_FOLDER_LISTING');
  process.exit(2);
}
```
If genuinely unsure why it's empty, intercept the actual list API response
(`GET /report/folder/<id>`) rather than guessing from the rendered UI alone.

## Playwright stuck on data/permission, or no headless path at all -> use `--chrome` instead

If Playwright can't reach a state for **data or permission** reasons (report owned by
someone else, no access grant) rather than a selector bug -- stop fighting headless.
Same call if the repo has **no headless path here at all** -- this skill's script +
Cognito test users only cover `admin`/`exporterplus`; a UI task in `reports`/`manage`/
`search`/etc has nothing to run. User's own browser (via `claude --chrome`) runs their
real logged-in account, sees everything, any repo. Claude can't adopt `--chrome`
mid-session (launch-time flag only) -- so tell user to restart: `claude --continue
--chrome` (reattaches, no work lost). Say this out loud as an option, don't just
silently give up or keep retrying headless. See `references/chrome-driving-pitfalls.md`
for driving-via-chrome gotchas once reattached.

## Variant: fix only reproduces on a REAL user's own report -- user logs in, Claude drives via `--chrome`

No test account (headless or `--chrome` admin) sees a report as its OWNER does in the list
(direct-URL-vs-folder-listing gotcha above still applies). If the bug is data-specific to
one real person's report: have the user log into the **local dev server** themselves as
that person, then restart `claude --continue --chrome` so Claude drives that already
-authenticated tab against the unreleased local fix. Offer this whenever a fix needs the
owner's own list view, not just view access.
