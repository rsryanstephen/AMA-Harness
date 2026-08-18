# Frontend architecture: exporterplus and admin

## Which UI talks to which backend — `manage` is shared, not admin-exclusive

`manage` is the admin API — but it's NOT admin-UI-exclusive. `admin` (the UI) only ever
talks to `manage`. **`exporterplus` (the general/main UI) also consumes `manage`** for
admin-type functionality embedded in the main app, alongside its other backend calls
(search, reports, etc. — see each app's backend-call-strategy below). Don't assume a
change in `manage` only affects the `admin` UI — check `exporterplus` call sites too.

## These are two genuinely divergent architectures, not one convention at two maturity levels

- **exporterplus**: layered `core/` (cross-cutting singletons: auth-cognito, charts,
  hql-query, notification) + `features/` (lazy `loadChildren` route modules,
  path-aliased `@core/...`) + `shared/`. Real module-boundary discipline.
- **admin**: flat, one folder per domain noun at `app/` root
  (`organizations/`, `users/`, `monthly-exports/`, `socialising/`, `client-loan-data/`).
  No core/features split, no lazy loading — one big eager `Routes[]` array, role-gating
  via `data: { roles: [...] }` + `ExpAuthGuard`.
- admin looks frozen at an earlier team convention; exporterplus kept evolving. Don't
  assume a pattern from one app applies to the other.

**State management**: no NgRx in either app — pure services + `BehaviorSubject` (100+
uses in exporterplus). No real "store" pattern exists.

## Auth token injection — forked from a common ancestor, since diverged

Both apps have a near-identical `token.interceptor.ts` (byte-for-byte common lineage):
calls `Auth.currentSession()` (aws-amplify), sets `Authorization: Bearer <token>` +
custom `IDToken` header. `search-request.interceptor.ts` also forked: exporterplus's
copy grew a domain-sharding scheme (`-a/-b/-c` subdomain rotation, `AppConfigService`
flags); admin's copy is the older, simpler version gated directly on
`environment.production`. **No shared library — a fix in one won't propagate to the
other automatically.**

## Backend call strategy — opposite strategies, not just wrapper differences

- **admin**: every feature service builds its own absolute base URL from
  `this.configService.config.endpoints.<name>` — one distinct backend origin per
  service, injected via env config.
- **exporterplus**: no `endpoints` map at all. Same-origin relative paths (`/search`,
  `/manage`), routed via nginx/ALB, with the sharding interceptor rewriting origin for
  search calls only.
- Neither app has a shared HTTP client wrapper; both hit `HttpClient` directly per
  feature service. `BaseService` in exporterplus's `shared/` is NOT an HTTP wrapper —
  it's just a `SubSink` cleanup base class for `ngOnDestroy`.

## Build/deploy config — genuinely different mechanisms

- **exporterplus**: moved OFF runtime-fetched `assets/config/config.json`. Config is
  baked into `index.html` as `window.env = {...}` at BUILD time
  (`_build/prepare-s3-deployment.sh` regex-replaces a placeholder, then deletes the
  `dist/.../assets/config` folder entirely). Octopus substitutes `#{...}` tokens in
  `index.html` afterward. `AppConfigService.load()` only fetches the JSON file when
  `environment.local === true`. Ticket PROJ-14906.
- **admin**: still the older pattern — `start_container.sh` runs at CONTAINER STARTUP,
  `sed`-substitutes `#{...}` tokens into `config.json`, and the app fetches
  `assets/config/config.json` over HTTP unconditionally at runtime. **Still
  network-exposed** — worth knowing before assuming config is never fetchable.

## Running a local dev server — per each repo's actual config, not the (stale) READMEs

- **admin**: `npm run start:dev` (README-documented). Port **4201**, explicit in
  `angular.json` — not the Angular default. Proxies via `proxy.config.dev.json` to
  `app.domains.dev` (`harness-config.json`).
- **exporterplus**: README says `npm start`, but that script no longer exists in
  `package.json` — stale, use `npm run start:tye` instead. Port **4200** (Angular
  default, unset in `angular.json`). Proxies via `proxy.config.json` to local
  microservice ports (`localhost:5000+`).
- Both also have `start:qa`/`start:prod`/`start:staging` variants (`--configuration
  local*`) pointing the proxy at the matching remote environment instead.

## No shared component library between the two apps

No `@ama/*` or common npm package in either `package.json`. Any resemblance
(interceptors, config service shape) is copy/fork lineage, not a maintained shared
dependency.

## exporterplus's own UI layer (beyond the module split above)

**Shared component layer is real, not ad hoc**: `shared/components/` has ~25 reusable
widgets (criteria-picker, cohort-select, field-value-input, save-query-dialog,
share-dialog, ama-icon, chip-values-viewer, skeleton-loaders, network-status). Features
compose these rather than hand-rolling inputs/modals.

**ag-grid is centralized via an abstract facade + DI-token factory** — every feature
grid extends `core/ag-grid/services/core-grid-facade-abstract.ts`
(`CoreGridFacadeAbstract`, owns column state/tool-panel/sort/lifecycle).
`CoreGridFacadeFactory` picks the right impl at runtime by injecting
`CoreGridFacadeAbstract[]` under a DI token and calling `isValid(template)` on each —
**the same multi-provider-array pattern as the connection-type DI crash class** (see
[[ama-debugging-notes]]'s `DI-EAGER-CONSTRUCTION.md`), just applied to grids. A new grid
facade added without correct `isValid()` logic, or not registered under the token,
silently fails to resolve.

**Column formatting is centralized**: `ColumnTypeService.get()` is a single registry of
named ColDef presets (date/decimal/currency/percentage/barChart columns), backed by
`ColumnFormatterService` — features pick from this rather than inline ColDef formatting.

**Export-to-excel is NOT ag-grid's client export** — a custom service
(`core/export/export.service.ts`, `ExportField`, `ExportReportBuilderService`), backend-
driven, decoupled from grid config.

**Cross-cutting UI concerns, each with one real shared service**:
- Toasts: `AppSnackBarService` wraps `MatSnackBar` — everything toasty goes through this.
- Confirmation/notification dialogs: `NotificationDialogService` wraps `MatDialog`.
- **No shared loading/spinner service** — loading UI (`progress-indicator-bar`,
  `skeleton-loaders`) is used directly per-component, ad hoc, unlike toasts/dialogs.

**`CriteriaBusService` vs `CriteriaService` — not a naming collision, different jobs**:
`CriteriaBusService` (`core/ag-grid/services/criteria-bus.service.ts`) is the actual state
holder — a `BehaviorSubject<FilterModel[]>` broadcast bus components subscribe to for
live filter changes. `CriteriaService` (`shared/services`) is stateless — a pure
transform/builder over criteria data, not a competing source of truth. Don't assume
they're duplicating each other; check which one a component needs (state vs transform).

## Chart category picks the builder/options-service pair — bar and line don't share a data-read strategy

`chart-category.ts`'s `ChartCategory` map (keyed by `ChartField.chartType`) decides which
builder/options-service pair handles a field — `bar` -> `BarChartBuilderService`/
`BarCharOptionService`, `line`/timeSeries category -> `LineChartBuilderService`/
`LineCharOptionService`. Not interchangeable data-read strategies:
- `BarCharOptionService.getOptionsData` reads a row's value via direct key lookup,
  `node[field.fullName]`.
- `LineCharOptionService.getOptionsData` never does a direct fullName lookup — sweeps
  `Object.keys(node)`, matches each against `field.fieldNameRegex` (`getSortedCprData`).
- For a **grouped** chart field (`ChartField.isGrouped`, built by `ChartService.getGroupedFields`),
  `fullName` = the group's **display label** (`chart.service.ts:212`, e.g. `"% GNM RPB del30D"`),
  not a real data column key. Harmless on the line/timeSeries path (never looked up as a key) —
  would break a bar-category field built the same way. Before assuming a grouped chart field's
  blank render is a fullName/data-key mismatch, check which category
  (`ChartCategory[chartType].id`) it actually resolved to first.

## Three parallel criteria-input mechanisms exist — only one is fully live

exporterplus has three separate places a "filter/criterion" gets entered, not one:
1. **Side-panel criteria-picker** (`shared/components/criteria-picker` +
   `field-value-input`, rendered inside `ama-customize-container`). This is the current,
   fully-live path — opened by the small sliders/drawer-toggle icon on
   Aggregations/Dynamic-Cohorts report pages.
2. **`CriteriaDialogComponent`** (`core/query/criteria-dialog`, a `MatDialog`) — still
   opened live from `customize-template.component.ts` (used by two other dialogs:
   aggregation-report "customize template", dynamic-cohorts "customize cohort report"),
   but the visible "Customize" button that would reach it
   (`report-actions.component.ts`'s `customizeButtonClicked()`) is a **no-op stub**
   (`return;`, nothing else). Effectively unreachable from the live UI today, confirmed
   via source — not dead code by declaration, dead by broken wiring.
3. **ag-grid's own native column quick-filter** (the funnel icon per column header —
   `Greater than`/`In range`/etc.) — handled entirely separately via
   `criteria.service.ts`'s `getCriteriaFromAgGridParams`/`getGridFiltersFromFilterModel`.
   Doesn't go through either of the above.

**Net effect**: a bug report about "the Between filter" almost always means mechanism 1
(`between-input.component.ts` under the criteria-picker tree) — that's the one users
actually interact with. Mechanism 2's own Between validation
(`criteria-dialog.component.ts`'s `disableAddEdit`) still matters for code correctness
but has no live UI surface to test against today.

**Between validator's `required` flag mechanics** (mechanism 1): driven by
`CriteriaRequiredPipe` = `!value.disabled` for an active criterion in the list view. A
freshly-added, active Between criterion is always `required=true` by default —
`required=false` only happens once the criterion is deactivated (toggled off). Relevant
to any future work on Between/validation reachability in this tree.

## RxJS cleanup convention — and where it breaks

Fleet-wide convention: components extend `BaseService`/use `SubSink` (`this.subscription.sink
= obs$.subscribe(...)`) or a `@autoUnsubscribe()` decorator, torn down in `ngOnDestroy`.
Consistent almost everywhere, with two known exceptions:

- **`ngOnDestroy` never fires for `providedIn: 'root'` singleton services** — `@autoUnsubscribe()`
  on a root-scoped service is a silent no-op. Only safe if the service's subscriptions are
  explicitly managed some other way (confirmed clean for `aggregations-side-panel.service.ts`).
  Check scope before trusting the decorator alone.
- **SubSink prevents leaks, not races** — it cancels on destroy, but does nothing about two
  overlapping in-flight calls on the same still-alive component. Known live bugs from this
  gap: see [[ama-debugging-notes]] EXPORTERPLUS-FRONTEND.md's SubSink section.

**Styling**: Angular Material 15, no PrimeNG. SCSS variables in
`shared/styles/_variables.scss` + per-feature `*.theme.scss` overrides (feature-scoped,
not one global theme). Material 15 is MDC-based — `mat-fab`/`mat-mini-fab` directives
render `mat-mdc-fab`/`mat-mdc-mini-fab` classes, NOT a literal `mat-fab` class; any
selector (test or style) assuming the old class name silently fails to match.

**Testing is real but uneven** — 297 spec files exist, but ~22 are stub-only
(`xdescribe` blocks or a bare "should create" with no real assertion). A `.spec.ts`
file's existence doesn't mean real coverage — check for `xdescribe`/triviality before
trusting it as a regression guard.

## New ui-projects.md entries (added later) — neither follows the exporterplus/admin patterns

- **mappingtool-web** — NOT a modern SPA. ASP.NET Core 2.0 MVC with server-rendered Razor
  views and an embedded **AngularJS 1.x** widget layer bolted on (`ui-grid`, no
  `package.json`/Angular CLI at all) — predates both exporterplus and admin. It IS its own
  backend (talks directly to Postgres/NHibernate + Elasticsearch) — despite being added
  alongside `mappingtool-service`, it does **not** call that service (zero references
  found); don't assume a client/server split exists yet. Auth is server-side OAuth2
  code-exchange against Cognito directly, not the client-side aws-amplify pattern
  admin/exporterplus share.
- **ui-style-guide** — Angular 12.2, project literally named `"best-practices"`. A
  teaching-example scaffold, not a real app: calls a public fake-API test endpoint
  (`jsonplaceholder.typicode.com`), no auth, no fleet config/deploy mechanism, `private:
  true` with no library build target. **Not a shared component library** despite the
  name suggesting one — confirmed zero references from admin's or exporterplus's
  `package.json`. Don't assume anything importable exists here until a real consumer
  shows up.
