# Shared-infra repos: what's alive, what's dead

These 5 repos are "shared" but NOT consumed via NuGet — the propagation mechanism (or
lack of one) matters before assuming a change here takes effect anywhere.

## `common` — appears orphaned/dead

Has a `.csproj` but no `PackageId`/publish config; git log is just 4 commits ending in a
build-error revert. Grepped every `.csproj` in AMA_APP for a `PackageReference` to exactly
`YourCompany.Product.Common` (not the `.Configuration`/`.Cqrs`/`.Logging` siblings) — zero
hits. **Nothing in the current tree consumes it.** Don't hunt for a NuGet reference that
doesn't exist, or spend time "bumping" it — confirm with the team whether it's actually
dead before treating it as real shared infra.

## `config` — a manually-maintained mirror, no automation

Contains `config.json` + `E-plus/config.{env}.json` (Angular env configs). **Not a git
repo locally** — no `.git` dir, `git log`/`git status` will fail here, that's expected,
not broken. Diffed against `exporterplus/src/assets/config/config.localprod.json` — byte
identical. No pipeline/script anywhere references this folder. **This is a hand-kept
mirror of exporterplus's dev config, with no tooling to catch drift** if one copy changes
and the other doesn't. Also: exporterplus's actual deployed config mechanism has since
moved away from this file entirely (baked into `index.html` at build time, ticket
PROJ-14906) — this whole `config.json` approach is legacy/partially superseded in
prod, see [[ama-architecture-notes]]'s `FRONTEND-ARCHITECTURE.md`.

## `octopus` — a worker image, wired outside git entirely

Just a Dockerfile (Octopus worker image + an old pinned Terraform 0.13.3 binary). Built/
pushed to ECR manually per its README. **Not referenced in any `bitbucket-pipelines.yml`**
— it's wired in via Octopus Deploy's worker-pool configuration on the Octopus server
itself, which lives outside git. To propagate a change: rebuild+push a new tagged image
AND manually update the worker-pool assignment in Octopus's own UI — nothing in any repo
picks this up automatically.

## `pipelines` — the real workhorse, hardcoded per-repo image pinning

`custom-images/base-image/` builds `yourproduct-pipelines:N` (AWS CLI, Octopus CLI, and
helper scripts baked in — `create-release.sh`, `build-and-publish.sh`, `build-lambda.sh`,
`check-code-coverage.sh`, `code-artifact-auth.sh`). Every consumer's
`bitbucket-pipelines.yml` pins this image by exact tag (e.g. `yourproduct-pipelines-32`),
and **different repos pin different versions** (`search`/`manage` on -32,
`feedback`/`fieldtablemapper` on -30). **Bumping a helper script here does nothing for
consumers** until: (1) the image is rebuilt+pushed with an incremented tag, (2) every
consumer's `bitbucket-pipelines.yml` is manually edited to the new tag. No version-range/
latest mechanism exists — it's a hardcoded string per repo, per pipeline step.

## `shared-configuration` — effectively empty

Single "Initial commit," only boilerplate. Nothing to break, nothing shared yet.

## `local-infrastructure` (added later) — the actual clone/run/release toolbox, not just config

Real Bitbucket name `product-service-local-infrastructure`. Genuinely useful and
actively maintained (commits through Nov 2025+, unlike `common`/`shared-configuration`) —
**not** docker-compose or Terraform. It's .NET Tye orchestration (`tye run --tags
export-functionality`, `--tags postgres`) to run the whole fleet locally in one shot,
plus a LocalStack helper for local S3, plus multi-repo git/release bash scripts
(`git-clone.sh`, `merge-develop-to-master.sh`, `delete-stale-branches.sh`, etc.) driven by
a hardcoded `scripts/repo-list.txt` (15 repos). **Real external consumer**:
`exportproducer`'s and `cacheupdate-infrastructure`'s own READMEs point developers here
by name for local debugging — this isn't an orphaned repo, other repos' onboarding docs
depend on it existing. Distinct from `config`/`octopus` — no file overlap, only a loose
conceptual link (some commented-out Octopus variable URLs left in `tye.yaml`).

**Security note**: a June 2025 commit (`cf6024a`) explicitly scrubbed real AWS
keys/secrets that had been checked into `tye.yaml`/`tye-qa.yaml` directly — confirms
secrets did leak into this repo's git history before being removed. If ever auditing for
historically-committed secrets fleet-wide, this repo's history is a known hit.

**Its `scripts/` release tooling is the retired predecessor to [[ama-cut-release-branch]]**
— that skill now does this job; don't run these scripts. Two things worth knowing if this
history ever surfaces: (1) the legacy flow used **git-flow** (`release-script` Makefile:
`git flow release start/finish/publish`, tag prefix `release-` distinct from branch prefix
`release/`) — the current skill deliberately doesn't use git-flow at all, just direct
branch-off-develop, so there's no tag to manage. (2) A real incomplete-release incident
(`cleanup-release-121.sh`) shows the recovery pattern when a cut goes wrong: delete both
the local+remote tag AND the local+remote branch, then redo from scratch — no partial-fix
path existed. Everything else in `scripts/` (hardcoded `repo-list.txt`, stop-on-first-merge-
conflict semantics, a stale-branch-deletion helper) is either superseded or not generically
useful — not worth separate notes.

## CI pinned to .NET 8 SDK — blocks publishing any net9+ target until bumped (both places)

Two SDK pins, BOTH `sdk:8.0`, both must move for a net9 lib build to publish:
1. Each nuget-package repo's `bitbucket-pipelines.yml` `build_and_test` step →
   `image: mcr.microsoft.com/dotnet/sdk:8.0`. Bump to `sdk:9.0` (SDK 9 still builds net8).
2. The publish step's custom `yourproduct-pipelines-N` image is built
   `FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine`
   (`pipelines/custom-images/base-image/base-image-dockerfile`); its `package.sh` runs
   `dotnet pack` → CANNOT pack a net9 TFM. Fix = new image tag FROM `sdk:9.0-alpine`,
   rebuilt+pushed to ECR, then every repo's publish step re-pinned (hardcoded per-repo,
   manual — see `pipelines` section above).

NuGet version scheme (`package.sh`): `<VersionPrefix>` from csproj + `.` +
`$BITBUCKET_BUILD_NUMBER`. master → no suffix; other branch → appends `-<branch>`. So a
master push auto-bumps the 4th part — no need to hand-edit VersionPrefix just to rebuild.

**A feature branch containing `/` (e.g. `fix/lazy-...`) breaks this publish step** —
`shared`/`search`'s `package.sh`/`package_develop_branch.sh` run on every branch, and the
`-<branch>` suffix becomes an invalid NuGet version string (the `/` isn't legal), so the
publish step FAILS. A red pipeline on a feature-branch push to these two repos, where the
only failure is this invalid-version publish error, is expected/benign — don't chase it
as a code bug. Real publishes only happen from `master` (shared) / `develop` (search).

**The `sdk:9.0` CI image can build net8 but can't run its tests** — multi-targeting a
lib to `net8.0;net9.0`, `dotnet test` for the net8.0 TFM throws
`Testhost process for ... net8.0 ... exited with error: You must install or update .NET
to run this application.` The sdk:9.0 image only ships the net9 runtime; it can compile
net8 via reference assemblies but can't execute the net8 test host. Fix: install the
.NET 8 ASP.NET Core runtime as an extra CI step before `dotnet test`. Applies to every
multi-targeted library repo identically, not a one-off.

**Per-repo pipeline image tags drift independently, beyond just build vs. publish** — a
repo's `bitbucket-pipelines.yml` can reference the custom `yourproduct-pipelines-N` image
in more than one step (build, coverage, publish), each pinned separately. Re-pinning the
publish step alone isn't sufficient — check every step that references the custom image
before assuming a repo is fully bumped.

**Lambdas/ECS target .NET 10, NOT .NET 9 — and the CI image is now `yourproduct-pipelines-34`
(`sdk:10.0-alpine`, builds net8/9/10).** AWS Lambda `dotnet9` is **container-only** (no
managed zip runtime) and deprecates **Nov 10 2026 — same day as `dotnet8`**; `dotnet10` is a
managed zip runtime, LTS, deprecates Nov 14 2028. So runtime-bearing components go straight
to net10 (Octopus runtime var `dotnet8`→`dotnet10` + TFM + net10 SDK), keeping the
zip+Terraform deploy. `-34` supersedes the net9 `-33`; re-pin repos to `-34` going forward.
The 21 libraries stay `net8.0;net9.0` (fine for net10 consumers via forward-compat). Full
reasoning/citations: PROJ-15179.

**CI failure signatures** (`bash: not found` on Alpine `yourproduct-pipelines-*` images,
`NU1301` malformed `NuGet.config`, old-TFM→net9+ breaking-change cluster, net10
`System.Linq.Async` `CS0433` collision, vacuous green `dotnet test` on a repo with no
test project) live in [[ama-debugging-notes]] CI-PIPELINES.md — that's where a
failing-build reader looks.

**Lambda deploys (Octopus/Terraform) DON'T replace code on an existing function — you MUST
delete the AWS Lambda first, THEN deploy**, or it silently keeps running stale code even
though Octopus/the function's metadata report success. Full writeup (verification
method, the separate patch-version trap once fixed) in [[ama-octopus-deploy]] — that's
the deploy-mechanics skill, not this one.

**ECS service net10 upgrade is the cleanest class** — container-hosted (no managed-runtime
constraint, no delete-first — a plain rolling ECS task), and libs are consumed as NuGet
packages so net10 apps use the net8.0;net9.0 packages via forward-compat (no lib
entanglement). Per-repo change: every `.csproj` net8.0→net10.0; `Dockerfile` base
`aspnet:8.0`→`aspnet:10.0` AND build `sdk:8.0`→`sdk:10.0`; a container-lambda in the same
repo may also have a `runtime:8.0`→`10.0` base (e.g. export's `ReportTransfers.Lambda`).
For the **develop deploy** (not the build-only feature-branch CI), the repo's DEFAULT
`build_and_test` step must also go to `-34` AND set `DOTNET_ROLL_FORWARD=Major` so its
net8.0 ReportGenerator line runs on net10. Some repos also carry a `global.json` pinning
the SDK (e.g. exportproducer, search) — bump it to `10.0.0` too or the build stays on SDK 8.

**"Pure ECS" is a trap — grep `build_lambda` in the DEFAULT pipeline BEFORE batching a repo
as ECS-only.** Several service repos (export, notifications, fieldtablemapper) carry a
per-service **cache-update lambda in the SAME default pipeline as the ECS service**, with
`build_lambda`/`build_lambdas` ordered BEFORE `build_and_publish_docker`. The docker/ECS
build runs *inside* the repo's `sdk:10.0` Dockerfile so the docker step's pipeline image is
SDK-agnostic (that's why feedback — a true pure-ECS repo — deployed fine with only the
default `build_and_test` bumped). But `build_lambda` runs `dotnet publish` on the PIPELINE
IMAGE itself → on a net8 image it dies `NETSDK1045: SDK does not support targeting .NET 10.0`
and, being ordered first, blocks docker+octopus → the ECS service never deploys either. So
these repos CANNOT have their ECS deployed independently of the lambda: the lambda step must
also go to `-34`, its Makefile `--runtime dotnet8`→`dotnet10`, its Octopus `function-runtime`
var→`dotnet10`, AND the lambda gets the delete-first deploy. Treat such a repo as ECS+lambda
hybrid, not pure ECS. (export is worst: TWO lambdas — Export.Lambda zip + ReportTransfers
container; the container one likely skips delete-first.)

**Container-image Lambdas (`PackageType=Image`, confirmed: cohortdata's `qa-v1-cohort-data`) do NOT
have the zip stale-cache bug** — check `aws lambda get-function-configuration --query PackageType`
before assuming delete-first is needed. Deploy is Docker build+publish to ECR + Octopus
`create-release.sh` referencing the new image; Terraform updates `image_uri`/digest in place and
Lambda actually swaps code (confirmed: digest + tag changed, `LastUpdateStatus=Successful`, a real
SQS-shaped test invoke ran the new code's business logic end-to-end). Only true zip lambdas
(`PackageType=Zip`, `dotnet-lambda package` in the pipeline) need delete-first. AWS does publish
`public.ecr.aws/lambda/dotnet:10` (verified via `docker manifest inspect`, both arch manifests) —
don't assume no net10 container base exists without checking.

**Not every ECS service rolls the same way — check `deploymentConfiguration` before panicking at `running=0`.** Most AMA services roll with headroom (new task up before old drains). But some Fargate services (confirmed: `exportproducer`) are `minimumHealthyPercent=0` + `maximumPercent=100`, so ECS STOPS the old task before starting the new one → a legitimate `running=0`/`pending=0` window of several minutes on EVERY deploy (net10 image pull + ALB health-check registration stretch it to ~10 min). `failedTasks=0` + the only stopped task being the old taskdef with `stopCode=ServiceSchedulerInitiated`/exit 137 (SIGKILL-on-drain) = healthy rollout, NOT a crash. rollout flips to COMPLETED once the new task passes ALB health checks (which itself proves the net10 app booted). Brief deploy-time downtime is inherent to that service's own config, not introduced by the upgrade.

