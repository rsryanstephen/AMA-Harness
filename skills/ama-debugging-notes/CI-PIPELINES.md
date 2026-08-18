# CI pipeline bug classes

## net9.0 test leg aborts: "You must install or update .NET to run this application"

- **Signature**: Bitbucket "Build and Test" step FAILED; log shows net8.0 tests `Passed!` then
  `Testhost process ... exited with error: You must install or update .NET` for the net9.0 dll,
  frameworks found list missing 9.0.x. Junit report still shows 0 failures (net8 leg only) —
  don't trust the test-report summary, check step result.
- **Cause**: ECR image tags (`yourproduct:yourproduct-pipelines-NN`) mutate over time — `-33` dropped
  the .NET 9 runtime (now ships 8 + 10). Repos whose test step installs only `--channel 8.0` via
  dotnet-install break the moment the image loses 9.0.
- **Fix**: duplicate the dotnet-install line with `--channel 9.0` in the test step. Confirmed on
  notifications-client, cache-update-shared, reportclient, common-cqrs (PROJ-15178, 2026-08).
- **Discriminator**: only repos whose *test step* runs the ECR yourproduct image are exposed — a
  top-level `mcr.microsoft.com/dotnet/sdk:9.0` image already ships 9.0. Check the step's own
  `image:` override, not just the yml's first line.

## `bash: not found` on a `yourproduct-pipelines-*` build step

Custom `yourproduct-pipelines-*` image is Alpine (musl) — no `bash`. A `build_and_test`
step on the custom image (not the Debian `mcr.microsoft.com/dotnet/sdk` one) can't pipe
`dotnet-install.sh` to `bash` — step dies. Do `- apk add --no-cache bash` first.
Repos differ: some run build_and_test on the Debian top-level image (bash present,
CodeArtifact auth via inline `dotnet tool install AWS.CodeArtifact.NuGet.CredentialProvider`),
others on the custom Alpine image (auth via baked-in `code-artifact-auth.sh`) — confirm
which before adding a runtime-install line.

## `NU1301` 404 at restore — malformed `NuGet.config`

A broken `nuget.org` URL in `NuGet.config` recurs across old/neglected repos — check it
first, not just once. Fails at restore, before compile, so code-compat can't even be
assessed until fixed. Repo-health class to check on any old repo being touched.

## Old-TFM → modern-TFM upgrade breaking-change cluster

Jumping straight from net6/netcoreapp3.1 to net9+: `X509Certificate2(bytes, password)`
constructor obsoleted (`SYSLIB0057`, changed PFX/PEM load behavior); old ASP.NET Core
Kestrel `PackageReference`s (e.g. `2.2.0`) need converting to
`FrameworkReference Microsoft.AspNetCore.App`.

## net10: `System.Linq.Async` collides with built-in `System.Linq.AsyncEnumerable`

`CS0433` ambiguous `AsyncEnumerable` at compile — .NET 10 ships it in-box, and the NuGet
package's same-full-name type can't be disambiguated by qualification. Drop the package
(built-in serves `AsyncEnumerable.Range(...)` etc.); `IAsyncEnumerable<T>`-only consumers
unaffected. Hit in resultsprocessor's test project.

## Green `dotnet test` step proves nothing without a test project

Passes vacuously on a repo with no test project. De-risking an upgrade on zero-coverage
repo → build a characterization-test safety net first, run on both TFMs; a bare CI pass
isn't evidence.
