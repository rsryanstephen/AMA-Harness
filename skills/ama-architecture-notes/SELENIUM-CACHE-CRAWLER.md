# selenium-crawlers (cache-warming Lambda)

Deployed as `<env>-v1-selenium-crawlers-cacheupdate`, invoked by the cache-update Step
Functions pipeline's "Search" step (name mismatch — see [[ama-debugging-notes]]'s
`CACHE-UPDATE-DEBUGGING.md` equivalent in [[ama-graylog-search]]). Pre-warms report pages by
driving a real headless browser against the actual web app.

## Firefox, not Chrome — deliberately

`DriverManager.cs` hardcodes Firefox/geckodriver 0.30.0. Comment: "Chrome has lots of
issues running in a lambda." A full `GetChromeDriver()` method (20+ `--headless=new` flags
tuned for Lambda's read-only `/tmp`) sits dead/unused in the code — Chrome-in-Lambda was
tried and abandoned. No Selenium Grid/remote WebDriver — the C# process drives the browser
in-process, inside the Lambda sandbox. `firefox-esr` + geckodriver installed directly into
the Lambda image. `HOME=/tmp/home`, `XDG_DATA_HOME=/tmp/chrome-xdg` — Lambda's only
writable path is `/tmp`.

## "Page ready" is 3-layer DOM/JS coupling, not a real signal

`ExporterAggregationsPage.IsRequestsLoading()` checks: `#aggregations-container` exists,
`.requests-loading` CSS class is gone, at least one `.ag-row` rendered. All three must
pass. **Fragile in a dangerous direction**: `IsElementPresent`/`WaitForElementVisible`
(`PageAction.cs`) swallow all exceptions and return false/true silently — if the frontend
renames `aggregations-container` or drops the `requests-loading` class, the crawler thinks
pages load instantly and "successfully" caches nothing, with no error anywhere.

After the loading check passes, a blind `Thread.Sleep(5000)` "to ensure server-side
caching" — the actual backend caching mechanism is opaque to this repo, inferred by
wall-clock guess, not a real completion signal.

## Report list is hardcoded

`Crawler.cs` has a literal `List<string>` of 17 `/aggregations/*` URLs. Adding a new
aggregation report to the web app requires someone to remember to add it here too —
nothing enforces sync.

## Silent partial-failure — Lambda can report success while every report failed

Ordinary render failures (dashboard never appears, loading never finishes) are NOT
exceptions — just logged and skipped, so the Lambda returns success even if every report
failed to actually warm. Meanwhile genuine crashes DO propagate: `OpenReport`'s
`_driver.Navigate().GoToUrl(url)` isn't wrapped, so any exception that doesn't match
`IsBrowserCrashException`'s substring list (`marionette`, `browsing context has been
discarded`, `no such window`, `connection refused`) kills the remaining report URLs for
that run and fails the Step Functions step. `ReportsBeforeRestart` restarts the whole
Firefox process every 5 reports to dodge memory buildup — implies real leak pressure in
Lambda's 2048MB.

## `cache-update-shared` is NOT used by this repo

Zero project reference to `YourCompany.Product.CacheUpdateShared` — the crawler doesn't
touch `CacheUpdateStateRepository`, DynamoDB, or the `CacheUpdateStep` enum. The "Search"
step correlation is pure Step Functions wiring; `cache-update-shared`'s state
tracking/Slack notification data is consumed by a different Lambda (UpdateCacheState).
This crawler is a "dumb" leaf step with zero visibility into overall pipeline state.
