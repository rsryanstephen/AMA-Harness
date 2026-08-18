# Driving Curve Analyzer headless — confirmed selectors + traps (2026-08-13, PROJ-15302)

Route: `/curve-analyzer`. All confirmed live against Staging exporterplus, headless Playwright.

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
