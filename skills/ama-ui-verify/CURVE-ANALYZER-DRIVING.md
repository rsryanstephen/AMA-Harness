# Driving Curve Analyzer headless — confirmed selectors + traps (2026-08-13, PROJ-15302)

Route: `/curve-analyzer`. All confirmed live against Staging exporterplus, headless Playwright.

## ADD BOND — cheapest way to a curve with a specific agency (2026-08-20, PROJ-15317)

Cohort creation is an async build with a progress bar — skip it when any single pool
works. Confirmed on QA: `#curve-add-bond-btn` → field picker
`#select-cohort-choose-fields mat-select` (open, `keyboard.type('cusip')` into
`input[aria-label="dropdown search"]`, click `getByRole('option', {name:/cusip/i})`,
Escape) → value input inside `#groupby-criteria-field-value-input` (click, type the
CUSIP, click the matching option) → `button.create-button` "Add". Bond curve appears
toggled ON and fires `POST /search/curve` immediately. Pick a live CUSIP from Redshift
(loanbyservicertransferview joined to loanhistorybyperiods on the target period);
`36179WBX5` = GNM, ~100k loans. Curve type switch: the top-left title `mat-select`
(trigger text `S-CURVE`), options match `/aging/i` etc. Request body `CurveType` is the
backend enum int (0=SCurve, 1=AgingCurve), NOT the frontend string enum.

## Colour picker + Edit panel (2026-09-22, PROJ-15273)

- Field option text is `MBS CUSIP` (also `Tranche CUSIP`), not bare `CUSIP` — filter
  `mat-option` by `/^\s*MBS CUSIP\s*$/`. Value control is a second searchable select:
  `#groupby-criteria-field-value-input mat-select`, type into the `dropdown search` input.
- `app-curve-color-picker` is inside the per-curve Edit panel: click the row's
  `button[title="Edit"]` first, else the picker is attached but hidden with `curve == null`.
  A visibility toggle CLOSES that panel — reopen Edit before the pick. Trigger =
  `app-curve-color-picker ngx-colors` (`el.click()` via evaluate), swatches =
  `ngx-colors-panel .circle.color.circle-border`; the row's `.key-container` background
  mirrors the curve colour, so it's a DOM assertion that needs no chart.
- Counting facade calls in dev mode: `window.ng.getComponent(pickerEl).changeCurveColorFacade`,
  wrap `changeColor` on its prototype. Script: session scratchpad `verify-15273.mjs` shape.

## Traps, in the order they bit

- **NOTIFICATIONS dialog respawns** ("Introducing AMA Notifications", NOT NOW /
  ENABLE) — dismissing once is not enough, it can reappear mid-flow. Re-check + click
  `getByRole('button', {name: /not now/i})` before EVERY interaction block, not once at
  login.
- **`mat-select:visible` ordering includes the S-CURVE title dropdown** (top-left of the
  page) — `nth(0)` is NOT the criteria row's operator. Clicking `nth(1)` blind hit the
  operator and silently changed `In` → `Contains`. Target selects structurally, never
  by visible index.
- **Operator choice reflows the Values control**: `In` → a checkbox multi-select with
  its own search box (`app-mat-select-search-input mat-select`); `Contains` → a plain
  text input ("Please enter a value"). A selector written for one shape times out on
  the other.
- **Field picker** = the `mat-select` whose trigger text is `Add Criteria Field`. Its
  panel has a search input (`aria-label="dropdown search"`) — a plain `.fill()` on it
  flaked; `page.keyboard.type(...)` after the panel opens works. Options are
  checkbox rows; `getByRole('option', {name: /…/})` matches; a bare
  `locator('mat-option').first()` resolves a HIDDEN template option and times out.
- **Close panels via `.cdk-overlay-backdrop` click + Escape**, then wait ~700ms —
  Escape alone left the panel intercepting the next click.
- **`.curve-legend-container` never became visible headless** even with the chart
  loaded (ui-testing's Selenium suite uses it, but don't gate on it in Playwright).
  Gate on captured network instead: wait until a `POST /search/curve` response arrives.
- **Curve toggles reset per session; cohorts persist.** A cohort added last session
  shows in the Curves list with its toggle OFF — toggle "Show All"
  (`mat-slide-toggle`, first in the side panel) to fire the chart requests.
- **Name field**: "Auto Generate Name" ON still showed "Name is required" until
  criteria were complete — fill `#create-single-cohort-name` explicitly, don't rely on
  the toggle.

## The decisive assertion — response body, not DOM

Curve and search responses carry a trailing `FromCache` bool. Capture it:

```js
page.on('response', async r => {
  if (/curve/i.test(r.url()) && r.request().method() === 'POST') {
    const j = await r.json().catch(() => null);
    console.log(r.url(), j?.FromCache);
  }
});
```

`fromCache: false` on first request (write), `true` on the repeat — including across
fresh sessions (curve cache expiry is 32 days, `CachedSearch.cs`). This beats any DOM
assertion for cache verification. Same pattern for reports: `scripts/drive-report-fromcache.mjs`.

## Semantics worth knowing before "testing curves"

- Staging has `CurveSettings__CurveUsesPrecaching=false` (prod: `true`) — a
  `cache-type=curve` cache update on Staging pattern-CLEARS only, no pre-generation
  (`CurveCacheUpdateService.cs:134`). Absence of curve writes after the update is
  correct behavior there, not a failure.
- Curve lazy caching is gated on general `CacheSettings.EnableCaching` only — NOT
  `EnableSearchCaching` (`CachedSearch.cs:44`).
- Creating a curve cohort fires `ClearCacheKeysForSpecificCohort` → `ClearByAsync`
  pattern `*-<cohortId>-*` in search-api — a cheap way to exercise pattern clears.
