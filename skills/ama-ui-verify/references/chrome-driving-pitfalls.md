# `--chrome` driving pitfalls (AMA UI)

All hit for real. Read before driving exporterplus/admin via Claude-in-Chrome.

## Identity/safety — highest severity, hit twice

- `--chrome` = user's REAL browser profile, not an isolated test session. Session can
  silently drift to user's real account (multi-login dialog, stale localStorage) -
  zero visible warning. Check identity before any state-changing action: decode
  Cognito `idToken` from `localStorage` via `javascript_tool`, don't trust top-right
  username glance.
- `/login` in real browser autofills user's REAL saved password. Never click Sign In
  without checking field contents first. Only submit real creds with explicit
  per-task user authorization.
- Synthetic `type` into password field can silently truncate (16 chars -> 9, cut
  mid-string - likely autofill popup stealing focus). Verify field length via JS after
  typing, before submit. If wrong: set value via JS
  (`Object.getOwnPropertyDescriptor(proto,'value').set` + dispatch `input`/`blur`) -
  more reliable than retyping.
- `ctrl+a` without focus truly in the field selects the WHOLE PAGE. Click into field
  first, verify selection scope before delete/retype.

## Navigation — labeled button != what it does

- exporterplus: sliders icon (`#drawer-toggle-button`) opens the REAL working
  side-panel criteria editor (`ama-customize-container`, has Between filter UI). The
  OTHER "Customize" button (report title styled,
  `report-actions.component.ts customizeButtonClicked()`) is a no-op stub (`return;`
  only). Confirmed via source. When a button seems inert, check its handler in source,
  don't keep re-clicking.
- A component can be `declarations`-registered with live `MatDialog.open()` call
  sites and still be totally unreachable if every path routes through a dead stub.
  Trace the actual `(click)` binding to its handler body, not just grep for `open()`.
- Dynamic Cohorts cohort-report customize panel = same component as Aggregations but
  `hideCriteria=true` - no Criteria section, only Cohorts/Bonds + Group By.
- `find` tool's description of an element can be confidently wrong (called a side
  panel "a modal dialog distinct from a side panel"). Use it to locate, not to trust
  what it claims the element does - verify by clicking + observing or reading source.
- `mat-slide-toggle` coordinate click can silently miss. Verify via
  `aria-checked`/`.checked` in JS, not screenshot glance. If coordinate click won't
  land, drive `.click()` on the DOM element directly via JS.
- Search-select "Add Criteria" dropdowns: confirm item actually got added
  (re-screenshot/re-`find`) before assuming the click registered.

## When a target UI is genuinely hard to reach

PROJ-15180's fix lives in `CriteriaDialogComponent` ("Between" dialog). Tracing
its live reachability took a full investigation, not one click:
- Obvious old entry point (`CriteriaComponent`/`app-query-criteria`) turned out to be
  dead code - orphaned since a 2020-05-21 commit deleted its only caller, never cleaned
  up (removed for good in PROJ-15265). General lesson: a dead entry point still
  shows up in grep/`declarations` and will mislead you into thinking it's the live path
  - always trace the actual `(click)` binding to its handler body, don't stop at "an
  `open()` call exists somewhere."
- Real path is `customize-template.component.ts`, used by two dialogs (aggregation-report
  "customize template", dynamic-cohorts "customize cohort report") - but every
  Aggregations page tried (template view, saved report) only opened the newer
  side-panel UI instead, not this dialog. Whole old criteria-dialog UI tree is
  effectively deprecated/superseded, even where source still wires it up.
- Dynamic Cohorts' "Cohort Reports" path exists but needs a real cohort/bond set up
  first. Don't just decide "too much to build live" and stop there -
  **ask the user to create the needed cohort/report in their own account, or to sign
  into an account that already has one, on the SAME browser instance.** Cheap ask,
  saves a dead end.

## Tool arming order

`read_network_requests`/`read_console_messages` only capture from first-call onward.
Page already loaded before first call -> nothing captured. Arm the tool, THEN
reload/trigger the action. Even armed, it missed every exporterplus `/search/*` XHR
(saw only the App Insights POST) - list URLs with
`performance.getEntriesByType('resource')` via `javascript_tool` instead, or replay
directly (below). A cached result (Redis) fires no request at all, so a re-Apply that
changes nothing captures nothing.

## Replaying an API request against Staging from the page

Same-origin `fetch` from the logged-in app tab; no separate auth setup:
- Token: `localStorage` key ending `.accessToken` as `Authorization: Bearer ...` -
  `.idToken` -> 401 on the report/search APIs.
- Hosts: search API `search-<env>[-a|-b|-c].example-app.com`; template
  definition `GET /report/template/<name>` on the app host (Template.Fields carry
  `field.name`/`fieldType`, enough to build `Fields`/`GroupingColumns`).
- Redshift-backed searches run 1-5 min, past `javascript_tool`'s timeout: fire the fetch
  un-awaited into `window.__res`, poll with `computer wait`. Any full navigation wipes
  `window.*` - re-arm.
- A prod request body recovered from Graylog (see `ama-graylog-search` GRAYLOG-REFERENCE)
  replays verbatim; only `ReportTemplateName` may need to exist on Staging.
- Several requests in one `javascript_tool` call: `(async()=>{ for (const c of cases) {
  ... await fetch(...) ; window.__r[c.k]=... } window.__r.__done=true })()` — sequential, so
  Staging isn't hit concurrently; poll `window.__r`. Used for the six-family stitch matrix
  (`ama-architecture-notes` SEARCH-SQL-PIPELINE.md, "Testing whether a family is stitched").

## Reproduce bugs through real UI, don't hand-fabricate state

To verify a defense-in-depth fix that only fires on loading already-bad saved data:
`git stash push --keep-index -- <fixed file>` (revert just that file) -> reproduce bad
state through actual buggy UI flow -> save for real -> `git stash pop` (restore fix)
-> wait for dev server to actually recompile (`ng serve` watcher rebuilds on save even
with `--live-reload=false` - that flag only stops browser auto-refresh) -> reload,
observe. Beats hand-crafted JSON that might not match the real bug's shape.

Don't assume the first blank-field state reproduces a known incident. A plain
newly-added Between criterion did NOT reproduce PROJ-15260 (a live
required-field flag made old code correctly reject it) - only reproduced after
deactivating the criterion first, which flipped `required` via a different path. If a
bug won't reproduce, recheck what state the fix actually gates on.

## Process

- Batch independent browser actions (click+type+screenshot) into one message - the
  harness reminds every single-call turn, don't ignore it.
- After killing a dev server on a fixed port, confirm the PID is actually dead
  (`netstat`/`taskkill`) before restarting - a stopped background Bash task doesn't
  guarantee the `node` process exited, and the new `ng serve` will refuse the port.
  Same two-step check applies at SHUTDOWN, not only before a restart - see SKILL.md's
  "Verification over -> STOP the server".

## Driving the MCF ADD BOND / ADD COHORT flow (confirmed live 2026-08-19, PROJ-15321)

- Coordinate clicks can miss silently when screenshot px != viewport px (saw 1568x743
  screenshots vs 2133x1012 viewport). No error, nothing happens. Click by `ref` from
  `read_page`, or `querySelector(...).click()` via `javascript_tool`.
- ADD BOND / ADD COHORT buttons are UNNAMED in the a11y tree -- they're the two bare
  `button` refs right after "Export Report".
- Angular Material selects: open with
  `el.dispatchEvent(new MouseEvent('click', {bubbles:true}))` on the `mat-select`.
  Options render in `.cdk-overlay-container` at body level -- `read_page` scoped to the
  dialog ref will NOT show them; query `mat-option` globally.
- The bond VALUE picker is a server-side type-to-filter (`mat-select-search`) capped at
  ~200 results. A JS value-setter + `input` event does NOT trigger it -- type real
  keystrokes (`computer` type action). A short prefix that matches >200 values silently
  hides later entries: type MOST of the target (e.g. `3137FNR3`, not `3137F`).
- MCP network tools show request/response METADATA only, no bodies. For bodies, install
  an XHR recorder in-page via `javascript_tool` (patch `XMLHttpRequest.prototype
  .open/send`, push into `window.__rec` with `loadend` capturing `responseText`). It
  survives SPA navigation; a full page load wipes it -- re-navigate via the app's own
  links/history, not `navigate` to a URL.
- MCP tabs share the user's Chrome profile cookies: navigating your own MCP tab to the
  app rides their logged-in session (owner-path testing) without touching their tab.
- Customize "Apply" is view-local -- nothing persists until Save. Safe to Apply
  experimental bonds/cohorts on a user's report for testing; never click Save without
  their say.
