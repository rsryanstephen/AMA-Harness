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

### Probe WHO the profile is before picking the method -- one JS call, do it first

`--chrome` uses the real profile, and that profile can hold a token for **a different
human**. Confirmed live 2026-09-11: a fresh dev server on :4210 came up holding an expired
`idToken` for a colleague; the login page then autofills THAT person's saved password. Two
bad outcomes one click apart -- sign in as them, or prompt for their credentials.

```js
const k = Object.keys(localStorage).find(x => x.endsWith('.idToken'));
k && JSON.parse(atob(localStorage.getItem(k).split('.')[1]))['cognito:username'];
```

Not the expected user (or expired) -> **use Playwright + a dedicated test account**, don't
try to fix up the real profile. Cheaper, and the account question stops existing. Password
never reaches a tool call either: `run-ui-verify.sh` and `lib-ama-ui.mjs` read
`claude_ama_pw` from the env themselves; typing it through a `computer` action would put it
in the transcript (and truncates, per the pitfalls doc).

**Screenshot discipline when driving via `--chrome`** -- `computer` screenshots are
base64 and stay in context for the rest of the session (confirmed the biggest single
driver of claude-in-chrome's token cost). Default to `get_page_text`/`read_page` (text)
for confirming state; reach for a `computer` screenshot only when the check is genuinely
visual (layout, CSS, rendering) -- one per verification step, not per action.
`resize_window` smaller first if full resolution isn't needed. Close the tab
(`tabs_close_mcp`) once the loop ends, and recommend `/compact` right after -- the
images have served their purpose. `chrome-verify-compact-nudge.sh` backs this up
mechanically (fires on `tabs_close_mcp`, feeds [[context-hygiene]]'s per-session
notice); `chrome-activity-track.sh` + `on-prompt.sh` nudge anyway after 2 prompts with no
browser call, so a forgotten tab still gets the recommendation.

## Self-verify -> fix loop, then user sign-off -- standing rule for ALL UI work

Applies to any `admin`/`exporterplus` change, before ANY deploy (QA via a plain
`develop` push, Staging via a release/hotfix branch push, or Production) -- not just
hotfix flows. In order, every time:

1. **Self-verify** the fix against a local dev server, using this skill (Step 0's
   compiled-CSS check or the full flow below) or `--chrome`.
2. **If broken or regressed, fix it and re-run step 1.** Loop until the original issue
   AND any regressions the fix may have introduced are actually resolved -- not a single
   pass. This is Claude's own quality gate, done before involving the user at all.
3. **Only then** ask the user to do their own local dev-server run as final sign-off. Handing
   them a server Claude started → `bash ~/.claude/scripts/devserver-hold.sh <port>` first (4h),
   else idle-kill reaps it before they open it.
4. **Only after** the user's explicit go-ahead does the push/deploy happen.

Additive to the user's own check, never a replacement -- the user's sign-off in step 3
is still the hard gate before step 4, same as [[ama-cloudwatch-search]]'s
Staging-verify-then-go-ahead rule. Claude's own loop comes first and must actually
converge before the user is asked to look at anything; applies to a plain `develop`/QA
push too, not only Staging-bound branches.

## A PASS proves nothing until the thing under test is in the REQUEST

Page loaded, grid rendered, no 500 -- and the criterion under test never left the browser.
Confirmed live (PROJ-15263): a seeded Between criterion sat in the report JSON with
`"disabled": true`, `addCriteriaFromTemplate` skipped it, and the run reported three clean
greens on a code path it never once exercised.

**Assert the outgoing payload, not the outcome.** Attach a `page.on('request')` filter,
find the criterion by field name in `payload.Criteria`, and assert its `value` /
`displayValue`. Absent = the verification did not run, which is a FAIL, not a pass.

**Pair it with a negative control.** Replay the same captured request with the pre-fix value
shape and assert it still breaks: 200 vs 500 on one payload field proves the fix and the bug
in one step, and it costs a single extra call because the request body is already in hand.

**Deployed env + `page.route` = `newContext({ serviceWorkers: 'block' })`, always.** The QA/Staging
service worker carries the app's requests past `page.route`: "0 saves" reads as "blocked" while
the save really ran, and an `abort()` meant to keep a test write out lets it through (2026-10-16:
4 stray bands on Staging). Local `ng serve` has no worker, so a probe green there proves nothing
here. Staging also opens an "Introducing AMA Notifications" dialog over the page: click **Not now**
once after load (a generic first-dialog-button closer races it).

**Deployed env: `/search` is cross-origin.** `SearchRequestInterceptor` shards it to
`search-<env>[-a|-b|-c].example-app.com` -- filter on path, never on `BASE`, or the
criterion reads as absent. Cap `request.response()` with a timeout: a SignalR long-poll never
resolves and hangs the run.

### Bug is "fires too many times"? COUNT the calls in-page -- the DOM cannot show it

A redundant call leaves the UI looking correct, so screenshot/DOM checks pass on the bug
and on the fix alike, and the spec alone only proves the component in isolation. Dev-mode
Angular hands you the live instance -- wrap the method on the service PROTOTYPE, so every
component sharing it is counted:

```js
const cmp = window.ng.getComponent(document.querySelector('app-curve-color-picker'));
const proto = Object.getPrototypeOf(cmp.changeCurveColorFacade);
window.__cc = []; const orig = proto.changeColor;
proto.changeColor = function (...a) { window.__cc.push(a); return orig.apply(this, a); };
```

Drive the real UI, read `window.__cc.length` at each step: 0 across re-renders, exactly 1
for the genuine user action. Needs an `ng serve`/dev build -- a prod build has no
`window.ng`. Arm it AFTER the element exists, and re-check the element is visible, not just
attached: an `@Input()`-fed component can sit in the DOM with a null input the whole time.

**Deployed/prod build -- patch the chunk instead.** `page.route` the method's lazy chunk,
string-replace a `window.__cc.push(...)` into the method (assert the anchor occurs exactly
once), fulfil. Context needs `serviceWorkers: 'block'`: the app's service worker serves the
unpatched chunk after the first load and the count silently reads 0. Control run: also strip
the fix from the chunk -- the spurious call must appear (PROJ-15273, 2026-09-26).

### Local looks wrong -> replay it on the DEPLOYED env before blaming the diff

QA runs the un-fixed build, so the same URL there is a free pre-fix control. A fixture
report showing `No Data Retrieved for Selection` locally looked like a regression until the
deployed QA tab returned the identical empty grid -- pre-existing, narrow selection, nothing
to do with the change (2026-09-21).

**Sessions are per-origin**: `localhost:4210` and `qa.yourapp.example.com` hold separate
tokens and can be two DIFFERENT humans. Probe both (see the identity probe above) before
reading an A/B as a behaviour difference -- it may just be two accounts.

### Reading criteria back -- inputs, not text

A Between criterion renders as two separate bound inputs, so a text/regex sweep for the
joined display (`4 - 8`) matches NOTHING even when everything is correct. Read values:

```js
[...document.querySelector('.criteria-picker-container').querySelectorAll('input')].map(i => i.value)
```

The criteria panel is in the DOM while collapsed -- no click needed. Avoid clicking for it:
the leftmost toolbar button is the dashboard toggle, and it navigates away from the report.

**EDITING criteria needs the drawer open**: `#drawer-toggle-button`. Closed, the chooser stays
rendered off-screen -- `isVisible()` true, click fails "outside of the viewport"; test the
bounding box instead. Report drawer = LIST view, template filters pre-listed: per
`mat-list-item`, label `[id^="text_"]`, toggle `mat-slide-toggle button[role="switch"]`
(`aria-checked`), `#operator-input-select`, value `app-field-value-input mat-select`. Turn
off defaults you don't want (MBS Issue Date is ON), then `#customise-container-confirm-btn`.

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

`tier3500b` (`claude_qa_3500b`, `claude_prod_3500b`): second Tier3500 user, copy TARGET for
`ama-user-data-copy` (made by its `create-test-user.sh`). Admin app: every 3500 user has
UserManagement, so it signs in there too (`lib-ama-ui.mjs login()` matches admin's Sign in button).

**A `production` user exists too -- treat picking it as a deliberate escalation**, not a
default. Only use it for the actual post-deploy production check in
[[ama-deploy-release]]'s flow, not routine fix verification (that's `qa`/`staging`).

**`tier1800` cannot access Dynamic Cohorts or Cohort Reports** -- a lower-tier plan
restriction, not a bug. If verifying a fix in either area, use `tier3500`; a permission-
denied error under `tier1800` there is expected, not a regression to chase.

### All six carry `UserManagement` -- every permission gate PASSES for them

Deliberate, keep it: it's what lets a test user open another user's report when the client
only ever shared a URL. Cost: `UserManagement` is a GRANT in the app's access checks
(`Admin || UserManagement || org access` -- `ClientDataReportRule`,
`ClientLoanDataAccessRule`, `ClientLoanDataTemplateAccessHandler` in `reports`), so these
accounts clear role- and org-gated checks unconditionally.

**Verifying anything permission-gated with them = false PASS, silently.** Tile/report
visible proves nothing about the gate. Confirmed 2026-09-15 (PROJ-15409).

Before trusting a permission result: `aws cognito-idp admin-list-groups-for-user
--user-pool-id <pool> --username <user> --region us-east-1`. Gate in that list -> pick a
different subject, or drop the group for the run and **restore it after** (diff the group
list before/after).

**Org-gated checks: send the `IDToken` header.** `OrgService` reads `custom:organization`
from it, NOT the access token. `lib-ama-ui.mjs`'s `api()` omits it -> org reads null ->
looks like "no access" for the wrong reason. Read the app's own request
(`page.on('response')` on the endpoint), don't hand-roll the fetch.

### Cohorts/cohort-reports are OWNERSHIP-scoped -- a test user sees none of the user's

Even on `tier3500`. Reproducing a user-reported cohort-report bug as a test user is
contaminated by default, not merely inconvenient:

| call | as non-owner | consequence |
|---|---|---|
| `/cohort/summary`, `/cohort/report/summary` | `{"items":[],"totalCount":0}` | a script that finds a report by LISTING it gets nothing and looks broken |
| `/cohort/{id}` | **404** | can't fetch real cohort JSON |
| `/cohort/report-id/{id}` | **500** (uncaught `CohortReportNotFoundException`) | see below |
| `/cohort/report/{id}` | 200 | works -- not user-scoped |
| `/dynamic-cohorts/reports/<tpl>/view/<guid>` | 200 | direct URL works; **use this** |

So: reach the report by direct `/view/<guid>` URL, never by listing. Get the guid from Mongo
([[ama-mongo-access]] -- `cohortreport._id` is binary subtype 03, decode it).

**The 500 silently breaks bond/criteria loading.** `getCohortsAndBondCriteria` is
`report$ -> forkJoin([getCohorts, getBondCriteria])`, and `forkJoin` errors whole if any
source errors -- so that one 500 stops bond criteria ever reaching `gridState.criteria`.
Conclusions like "the UI drops the bond" are then artefacts of the test user, not findings.

Getting a real owner-path answer without owner credentials (their MFA blocks headless login):
`page.route` the ownership-scoped endpoint and `fulfill` it with a plausible array. Browser-side
only, no writes. A stub answers faster than the real call, so it biases any race TOWARD passing
-- a failure observed under a stub is therefore the conservative, trustworthy direction.

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
never a bare `curl ... | jq` that dumps the value to stdout.

**Instrumenting requests leaks it too -- redact before logging.** `page.on('response')`
/ `instrument()` that prints `request.postData()` dumps the Cognito POST body, and
`ConfirmForgotPassword`/`ChangePassword` carry `Password`/`ProposedPassword` in
CLEARTEXT -> straight into the transcript and the chat log (which is a git repo). Hit
live 2026-09-17 driving forgot-password. Redact every capture:
```js
post.replace(/("(?:Proposed)?Password"\s*:\s*")[^"]*"/g, '$1[REDACTED]"')
```
Leaked anyway -> **redact it yourself first, immediately, no asking**:
`bash ~/.claude/scripts/redact-leaked-secrets.sh` (see [[credential-leak-redact-dont-ask]]).
Transcripts and chat logs are not git-tracked, so that closes it. Recommend rotating
`AmaUiTestUserPassword` (Octopus `LibraryVariableSets-261`) + all six Cognito users ONLY if
it also reached somewhere published. Never rotate unasked.

Two tiers exist because they
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

**Getting the export side of that comparison**: three scripts here do it end-to-end --
`verify-export-vs-grid.mjs` (drive grid, collect ALL headers past column virtualisation,
click Export, capture the `exportId`), `fetch-export-zip.sh` (newest matching zip out of
`<env>-v1-results-processor`, unzipped), `diff-export-vs-grid.mjs` (ordered column diff +
value cross-check). See [[ama-architecture-notes]]'s `EXPORT-DOWNLOADS.md` for the bucket/key
facts, the two newest-object listing traps, and why Export is a dialog + async S3 write
rather than a browser download. **Claude can verify an export end-to-end unattended** --
don't hand "a human must run the export and eyeball the columns" back to the user.

`verify-export-vs-grid.mjs` also shows the pattern for reading a **virtualised** grid: the
`waitForFunction` on `.ag-cell` below is only a readiness gate; `.ag-header-cell-text` holds
the viewport only, so reading headers straight from the DOM silently checks a handful of
columns and looks like it passed.

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
4210/4211 already taken (another session, a stale server)? Serve on any free port and export
`AMA_UI_BASE=http://localhost:<port>` -- `lib-ama-ui.mjs`'s `BASE` reads it. Off-list port =
`dev-server-teardown-reminder.sh` can't see it (it watches 4210/4211/8791 only), so kill it
yourself.
Launch it yourself (the wrapper doesn't manage the dev server):

```bash
npx ng serve --proxy-config proxy.config.qa-ecs.json --configuration localqa --port 4210 --live-reload=false
```

ONE verification only (hotfix self-check, single screenshot/diff)? `scripts/with-dev-server.sh`
owns the lifecycle -- starts, waits on `[::1]`, runs your verify command, kills the tree on
exit. Nothing left behind. Header has usage. Iterative fix -> re-verify loop: background
`ng serve` as above (watch rebuilds on edit; wrapper restarts cost 1-2 min per run).

### Dev server traps -- all four hit in one sitting (2026-09-22, PROJ-15273)

- **Binds `[::1]` ONLY.** `curl http://127.0.0.1:4210/` returns `000` forever while the
  server is up and serving fine. Probe with `curl 'http://[::1]:4210/'`. A v4 readiness
  probe burned a 400s timeout and read as "server never came up".
- **Port taken -> `ng serve` PROMPTS and the backgrounded task exits 1 with no error
  line**: `Port 4210 is already in use. Would you like to use a different port? (Y/n)`.
  Check the log tail for that question before diagnosing anything else.
- **Port held by another session -> read its command line before killing or reusing**:
  `Get-CimInstance Win32_Process -Filter "ProcessId=<pid>" | Select-Object CommandLine`.
  Same repo + same `--configuration` -> just use it, it serves the shared clone so it
  already has your edits. Different config (`localstaging` vs `localqa`) -> it points at
  another backend; serve your own on a free port and export `AMA_UI_BASE`. Never kill a
  server you did not launch (check the parent chain -- yours carries your own flags).
- **Readiness wait probes the PORT, never your own log.** A stale `ep-serve.log` from your
  previous dead launch reports failure while somebody else's healthy server answers.

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

**Verification over -> STOP the server, same turn.** A leftover `ng serve` is
indistinguishable from a hung task in the task list -- user ends up asking what is stuck
(2026-09-14: 4210 + a `python -m http.server` left up for hours). Two steps, BOTH needed:
`TaskStop` kills the wrapper bash only, the `npx` node CHILD keeps the port.
  1. `TaskStop` the launching task.
  2. `netstat -ano | grep 4210` -- still LISTENING -> `taskkill //PID <pid> //F`.
Same rule for any ad-hoc server started for a check. Serving static files locally
(rendering a deck/report -- Chrome refuses `file://`): use port **8791**, so the teardown
backstop can see it too. Backstop: `dev-server-teardown-reminder.sh` KILLS any server a
Claude call started (any port, any session) after 20 min with no command/browser call naming
`:<port>` and no open connection -- says what it killed; restart if still needed. `--chrome` loop: closing the verify tab KILLS
this session's server mechanically (`dev-server-tab-close-teardown.sh`, says what it
killed) -- loop not over? restart it, 1-2 min.

```bash
bash ~/.claude/skills/ama-ui-verify/scripts/run-ui-verify.sh <env: qa|staging|production> <tier: 3500|1800> <url> <screenshot-out-path> [css-selector] [css-property]
```

Logs in via the in-app username/password form (aws-amplify `Auth.signIn`, not a hosted-UI
redirect), navigates to `<url>`, screenshots it, and -- if a selector+property are given --
prints the element's computed CSS value. Exits non-zero if login fails or the selector
never appears.

### Multi-step flow (click, assert, click again) -> `scripts/lib-ama-ui.mjs`

`run-ui-verify.sh` is ONE-SHOT: navigate, screenshot, read one computed style. A dialog you
must open, act on, and re-check needs a scratchpad script -- import the shared pieces rather
than rewriting login each time:

```js
import { chromium, login, api, instrument, shutdown, BASE } from
    'file:///C:/Users/<you>/.claude/skills/ama-ui-verify/scripts/lib-ama-ui.mjs';
```

Signatures -- **argument order bites, read it here before writing the call** (a
`shutdown(browser, context, page)` guess off the old prose cost a whole run):

```js
login(page, username?, password?)      // asserts the reached username, throws otherwise
api(page, method, path, body)          // same-origin fetch, app's .accessToken
instrument(page, log?, urlFilter?)     // console/pageerror/http logging, attach BEFORE the action
shutdown(page, browser)                // closes page+context first (the dev-server-crash fix)
BASE                                   // 'http://localhost:4210', or $AMA_UI_BASE
```

Resolve creds in the wrapper, never inline:

```bash
export AMA_UI_USERNAME="$(jq -r '.users.qa.tier3500' "$HOME/.claude/.ama-ui-credentials.json")"
export AMA_UI_PASSWORD="${claude_ama_pw:?claude_ama_pw not set}"
```

**Seed fixtures through `api()`, drive the UI only for the thing under test.** Building a
cohort + three cohort reports by clicking is slow and flaky; the POSTs are the very calls
the UI makes. Needs a fixture only another user can own (ownership-scoped features) -> create
it as the test user, then reassign the owner in Mongo ([[ama-mongo-access]], qa only).
Clean up after: soft-delete the rows, then delete through the real API -- the cleanup
doubles as the unblocked-happy-path check.

**Need an MCF (`mcf-header-export`) report** -- test users own none; create one (cohort +
report via API, soft deletes, 120s grid wait): [MCF-REPORT-DRIVING.md](MCF-REPORT-DRIVING.md),
`scripts/mcf-report-fixture.mjs`.

**Driving an AGGREGATION report (Servicer Rankings, Servicing Transfer, Custom Loan Pool
View...) with claude-in-chrome** -- build via Criteria, never the grid filter boxes (view-only,
ignore input while Customize is open); re-`find` refs after every re-render; Escape the Group
By dropdown before Apply; long Save description = silent 500 (PROJ-15472):
[AGGREGATIONS-DRIVING.md](AGGREGATIONS-DRIVING.md).

**Verifying CACHING behavior (FromCache flags) or driving Curve Analyzer** -- see
[CURVE-ANALYZER-DRIVING.md](CURVE-ANALYZER-DRIVING.md) (selector traps + the
response-body FromCache assertion pattern) and `scripts/drive-report-fromcache.mjs`
(usage: `node drive-report-fromcache.mjs <reportUrl> <outPrefix>`, needs
`AMA_UI_USERNAME`/`AMA_UI_PASSWORD` env -- drives a report twice, prints every
`/search/*` POST's FromCache flag).

**For any report/grid URL pass `--expect-grid`** (`run-ui-verify.sh <env> <tier>
--expect-grid <url> <shot>`): it waits for a non-empty `.ag-cell` set and **exits 2** if the
grid never renders. Without it the script screenshots on `networkidle`, which fires long
before the grid's data call resolves -- a correct app shell with an EMPTY grid, exit 0
(2026-08-13, misread as a broken report). Opt-in because the wait would time out on the
non-grid pages this is mostly used for.

**Blank TOP-ROW cell on an off-screen column = your scroll, not the API** (2026-09-23,
PROJ-15442). Totals for CPRn/on-demand columns fetch per visible column page
(`hasUnRequestedTopRowColumns`); a JS `scrollLeft=` on `.ag-body-horizontal-scroll-viewport`
renders the cell but fires no grid scroll event, so no request goes. Detail rows fine, Graylog
shows the SQL, reads like a data bug. Check: reload with the column in the initial viewport
(drawer closed), or scroll with a real wheel/drag on the grid.

### A dialog mid-transition reads like a hung one -- count containers, don't eyeball

Same class of trap as the `networkidle` screenshot above: measuring too early and believing
it. Confirmed live 2026-09-11 -- a dialog that closes and immediately reopens with fresh data
was read, 6s after the click, as "stuck, every button disabled, the observable never
emitted". Nothing was stuck. Material keeps a closing dialog in the DOM through its
animation, so `.mat-mdc-dialog-container` `.last()` was still the OLD one, correctly disabled
because its own in-flight flag was set.

- Assert on `page.locator('.mat-mdc-dialog-container').count()` plus the new content, not on
  a locator that silently resolves to the corpse.
- **A count of 2 is often correct**, not a leak: a confirm dialog that stays open underneath
  while a second dialog handles a refusal is two containers by design.
- `instrument()` BEFORE the click. The request sequence settles it in one run -- seeing
  `PUT -> 200`, `DELETE -> 409`, then a new dialog is proof; a screenshot is not.
- Retry/refusal round-trips are slower than they look (a doubled request, a re-issued call,
  an animation). Give them ~20s before concluding anything.

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

## Reusable QA fixture reports -- REUSE these, don't seed another

`claude_qa_3500` owns a standing fixture set on QA. Check it BEFORE creating anything: a
seeded one-off leaves permanent clutter in a shared env, and every past session's leftovers
(`claude-verify-*`, `claude-15263-*`) were exactly that.

**Named by ATTRIBUTE, never by ticket.** A ticket name rots the moment that ticket closes and
tells the next agent nothing about what the report holds. `AMA fixture - <type> <operator>,
<value shape>`.

| Name | Id | Holds |
|---|---|---|
| `AMA fixture - number Between, split bounds` | `16ed38de-ee71-4c98-b6bc-fa37d741fae3` | MBS Coupon, Number, Between, `["4","8"]` -- the legacy 2-element shape |
| `AMA fixture - number Between, joined range` | `3724b3fd-95e5-405b-a699-1d98558373cb` | MBS Coupon, Number, Between, `["4-8"]` -- the joined 1-element shape |
| `AMA fixture - number Between, blank upper bound` | `a5643ec3-78c1-44b3-aafa-e76e0ef73cfd` | MBS Coupon, Number, Between, `["5",""]` -- PROJ-15260's drop-on-load guard case |
| `AMA fixture - date Between, split bounds` | `ce0086d2-231e-489f-965e-2a3c01c50db8` | MBS Issue Date, Date, Between, `["2026/06/01","2026/09/01"]` |
| `AMA fixture - date Between, joined range` | `3d9ab11d-2b0e-4bcf-9bcc-82c07548e65b` | MBS Issue Date, Date, Between, `["2026/06/01-2026/09/01"]` |
| `AMA fixture - grid column state, default widths` | `a49fac02-e36f-47e0-a6a2-e063428b6834` | All 1211 columns at the default width 200 -- nothing resized |
| `AMA fixture - grid column state, resized columns` | `2f0056c3-1c69-4480-a7a6-8f9c160b0d71` | 9 visible columns persisted at content-fitted widths (100-189) |

All seven are Agency Marketshare, `loan_by_servicer_transfer_non_periods_source`, 20 filters,
every other filter disabled. Open one directly: `/aggregations/view/<id>`.

The last two carry the same date-Between criterion as the date fixtures -- their distinct
attribute is saved `GridColumnState`, so they are the pair to diff for column persistence
(width/sort/pin/hide survives a save-reload). 1196 of the 1211 columns are hidden in all
seven; that is normal for this template, not a fixture quirk.

**Both shapes of a Between persist in the wild, and only one is reachable through the UI** --
the panel writes the joined form, the split form is legacy rows. A fix touching criterion
serialization needs BOTH fixtures, not whichever the UI happens to produce (PROJ-15263).

**Grew a genuinely new shape? Add a row here.** Reshaping an existing fixture instead breaks
whatever verification relied on it.

### Reshaping a fixture through the API -- three traps

Seed via `lib-ama-ui.mjs`'s `api()`, reshape+rename via a `page.evaluate` fetch. All three
confirmed live 2026-09-21.

- **`PUT /report` finds the record BY NAME, not by Id.** Change `Name` in the body and it
  404s `Report '<new name>' was not found for user '<user>'` -- reads like a missing report,
  is actually a rename attempt.
- **Rename is its own endpoint**: `PUT /report/{id}?name=<encoded>`, empty `{}` body. Edit
  the shape first, rename second.
- **`Content-Type: application/json;v=2.0` is required on both.** Plain `application/json`
  404s the route. `api()` sends plain, so it works for `GET`/`POST` here but NOT for these
  two -- use a `page.evaluate` fetch.

A filter with `"disabled": true` is skipped by `addCriteriaFromTemplate` and never reaches the
request -- a fixture whose criterion looks right in the DB but never appears in the search
payload is this, not a bug in the code under test.

### Creating a dynamic cohort through the real UI (PROJ-14658, 2026-09-26)

`/dynamic-cohorts/cohorts/new`, tier3500. Field chooser `#field-choose-field-input mat-select`
-- its search box KEEPS the last term between openings: Ctrl+A, Backspace before typing, else
`No matches found`. Row operator `#operator-input-select`; value
`#groupby-criteria-field-value-input` = lookup `mat-select` (boolean: `True`/`False`), but
`Equals` on a string field reflows it to a plain `input`. Then `#create-single-cohort-name`,
`button.create-button` -> `POST /cohort` 201. Done = `GET /cohort/{id}` `progress.status` 2
(3 = failed); `dataAvailable` is a create-time flag, not completion. Loan-count truth:
Graylog `COHORT_SQL` names the mapping table + `cohort_id` -> count via `rs-query.sh`.
`DELETE /cohort/{id}` after -- also drops the Redshift mapping rows.

## Bootstrapping test data -- no fixture above fits, and the test user has none

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
   **A CHART is the opposite -- never wait on its DOM.** No series selector matches while
   rendered (`.ag-charts-series path` timed out at 180s; `.curve-legend-container` never
   shows headless -- `CURVE-ANALYZER-DRIVING.md`). Gate on the chart's DATA CALL instead:
   `instrument()`, `page.waitForResponse(/\/search\/curve/)`, assert the response BODY.

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

Large heredocs silently mangle/truncate -- see [[bash-command-correctness]].

**Start from this skeleton, every time** -- a first draft without the `try/finally` crashed
the dev server twice (webpack-dev-server's http-proxy re-emits an unguarded error on an
abrupt `browser.close()`, see "`ng serve` crash prevention" above):

```js
const browser = await chromium.launch();
try {
  const page = await (await browser.newContext()).newPage();
  // ... drive, assert, screenshot ...
} finally {
  for (const c of browser.contexts()) { for (const p of c.pages()) await p.close().catch(() => {}); await c.close().catch(() => {}); }
  await browser.close();
}
```

## Confirmed selectors -- report/description UI (PROJ-15177)

Cheaper to copy than re-derive from source each run. **Confirmed for the report list /
description components only** -- the same logical control has a different DOM on another
report type (cohort-report-aggregation's toolbar puts `title='Save Report'` on the
`<button>` itself, not a nested `mat-icon`), so before trusting a row on a new page dump
the element once: `page.evaluate(() => document.querySelector("[title='Save Report']").outerHTML)`.

**`--chrome` on the cohort-report toolbar:** `find` -> `left_click` by ref silently no-ops
on the icon buttons (Save Report, Export Report) and mat-select dropdowns will not open
from ref or coordinate clicks. Use `javascript_tool`: `document.querySelector('button[title="Save Report"]').click()`,
and `el.focus()` + Enter for a mat-select (cost 40 min to rediscover, 2026-09-15).

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

## Prod probe = real Graylog error, later read as a regression

`api(page, 'POST', ...)` hits the real service. Guessed body -> Error-level log,
`environment:production`, alert-stream candidate. Indistinguishable from a user fault.

Live (158ea91a, 2026-09-17): probe posted `{}` to `/fieldtablemapper/mapping/filter`;
endpoint binds `string[]` -> `ArgumentNullException`. Only prod error in 90 days, 16 min
after a hotfix deploy -> read as that hotfix regressing, cost a full root-cause dig.

- Probe shapes in QA/staging. Prod run = exact call the UI makes, nothing exploratory.
- Must probe prod -> copy the body shape off the caller's own client first
  (`table-mapping.service.ts` posts `fieldNames`, an ARRAY). Never guess.
- Probe errored -> say so same turn, with the timestamp. Unexplained prod error found
  later is assumed to be a code regression.
