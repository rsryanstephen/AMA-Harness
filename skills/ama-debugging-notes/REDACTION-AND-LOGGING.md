# Input sanitization / logging — Shared, manage

## Where the logic actually lives

Sanitization + redaction (`InputSanitizer.cs`, `InputSanitizationFilter.cs`) is in
`product-service-shared`, consumed via NuGet by `manage` and 14 other repos. A fix
here needs a Shared version bump + republish + reference bump in consumers, not a local
edit in the consumer repo.

Exemption model (post PROJ-14948): NOT by argument name. Property-name substring
match (password/secret/token/credential/key-\* variants, `_`/`-` normalized) + a
type-based skip for `JToken` (JObject/JArray) so JSON query operators (`<`/`>`) survive.
The old whole-arg-by-name exemption had a `return` (not `continue`) bug — one exempt arg
skipped sanitizing ALL later args too. Gone now, don't reintroduce that shape.

## Known reoccurring bug class: eager structured-log destructuring can OOM

Confirmed real incident: a prod OOM/ECS-kill (exit 137) traced to
`InputSanitizationFilter.OnActionExecuting` logging
`Log.Debug("...{@Context}", context)` — the `@` destructures the whole
`ActionExecutingContext` (cyclic HttpContext/DI graph) → Serilog "Maximum destructuring
depth reached" → memory flood. Fixed by `46.3.4+`.

This is a generic trap, not just this one line: **any** `{@SomeObject}`/`Log.Debug("...{@}",
x)` on a large or cyclic object (framework context objects, DI-resolved services, EF
entities with navigation properties) can reproduce this class of OOM. If you see the
Serilog "Maximum destructuring depth reached" message again anywhere in this fleet, check
for a `{@...}` destructuring a framework/cyclic object first, before assuming a genuine
memory leak or infra issue.

## Verification gotcha for any Shared bump

Verify with a full `dotnet build` (Release), not just `dotnet test` — at least one
consumer (`resultsprocessor`) doesn't compile `Startup.cs`/app-project wiring under
`dotnet test`, so a broken `using` only surfaces in the Docker image's full build step in
CI.

## `manage` branch gotcha

`develop` and `master` can pin very different Shared versions — confirmed `master` lagged
on an old `46.2.x` line while `develop` tracked current `46.3.x`. Check BOTH branches'
reference before assuming "current" — a cross-line bump on `master` can silently need its
own compile-break investigation.
