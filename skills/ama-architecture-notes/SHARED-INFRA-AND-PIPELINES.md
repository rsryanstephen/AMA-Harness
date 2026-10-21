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
`bitbucket-pipelines.yml` pins this image by exact tag (`yourproduct-pipelines-NN`), and
**different repos pin different versions** — read each repo's own yml, never assume the
fleet is uniform. **Bumping a helper script here does nothing for
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

## NuGet package publishing (`package.sh`)

A nuget-package repo pins TWO SDK images independently: its `bitbucket-pipelines.yml`
`build_and_test` step (`mcr.microsoft.com/dotnet/sdk:N`), and the publish step's custom
`yourproduct-pipelines-N` image, built `FROM mcr.microsoft.com/dotnet/sdk:N-alpine`
(`pipelines/custom-images/base-image/base-image-dockerfile`). The publish image's
`package.sh` runs `dotnet pack` → can't pack a TFM newer than its own SDK. Raising a repo's
TFM means bumping BOTH; the publish-step tag is hardcoded per-repo, manual (see `pipelines`
section above).

NuGet version scheme (`package.sh`): `<VersionPrefix>` from csproj + `.` +
`$BITBUCKET_BUILD_NUMBER`. master → no suffix; other branch → appends `-<branch>`. So a
master push auto-bumps the 4th part — no need to hand-edit VersionPrefix just to rebuild.

**A feature branch containing `/` (e.g. `fix/lazy-...`) breaks this publish step** —
`shared`/`search`'s `package.sh`/`package_develop_branch.sh` run on every branch, and the
`-<branch>` suffix becomes an invalid NuGet version string (the `/` isn't legal), so the
publish step FAILS. A red pipeline on a feature-branch push to these two repos, where the
only failure is this invalid-version publish error, is expected/benign — don't chase it
as a code bug. Real publishes only happen from `master` (shared) / `develop` (search).

**A CI SDK image can BUILD an older TFM but can't RUN its tests** — multi-target a lib and
`dotnet test` on the older TFM throws `Testhost process for ... exited with error: You must
install or update .NET to run this application.` An SDK image compiles older TFMs via
reference assemblies but only ships its own runtime, so it can't execute their test host.
Fix: install that TFM's ASP.NET Core runtime as an extra CI step before `dotnet test`.
Applies to every multi-targeted library repo identically, not a one-off.

**Per-repo pipeline image tags drift independently, beyond just build vs. publish** — a
repo's `bitbucket-pipelines.yml` can reference the custom `yourproduct-pipelines-N` image
in more than one step (build, coverage, publish), each pinned separately. Re-pinning the
publish step alone isn't sufficient — check every step that references the custom image
before assuming a repo is fully bumped.

**Not every AWS Lambda runtime has a managed zip flavour — check before picking a TFM for a
zip lambda.** `dotnet9` was container-only (no managed zip runtime) and shares `dotnet8`'s
Nov 10 2026 retirement, which is why AMA's zip lambdas went straight from `dotnet8` to
`dotnet10` (managed zip, LTS, retires Nov 14 2028) rather than stopping at 9. A runtime that
can't be selected as a managed zip runtime forces either a container lambda or the next
version up.

**CI failure signatures** (`bash: not found` on Alpine `yourproduct-pipelines-*` images,
`NU1301` malformed `NuGet.config`, a mutated pipeline-image tag dropping a runtime,
old-TFM→modern-TFM breaking-change cluster, .NET 10 `System.Linq.Async` `CS0433` collision,
vacuous green `dotnet test` on a repo with no test project) live in
[[ama-debugging-notes]] CI-PIPELINES.md — that's where a failing-build reader looks.

**Lambda deploys (Octopus/Terraform) DON'T replace code on an existing function — you MUST
delete the AWS Lambda first, THEN deploy**, or it silently keeps running stale code even
though Octopus/the function's metadata report success. Full writeup (verification
method, the separate patch-version trap once fixed) in [[ama-octopus-deploy]] — that's
the deploy-mechanics skill, not this one.

**ECS services carry no managed-runtime constraint** — container-hosted, plain rolling ECS
task (no delete-first), and libs come in as NuGet packages, so a service can run a newer TFM
than the packages it consumes via forward-compat. The repo's own SDK pins are its
`Dockerfile` bases (build `sdk:N`, runtime `aspnet:N`) plus, in some repos (exportproducer,
search), a `global.json` — that one is easy to miss and silently holds the build on the old
SDK.

**"Pure ECS" is a trap — grep `build_lambda` in the DEFAULT pipeline BEFORE batching a repo
as ECS-only.** Several service repos (export, notifications, fieldtablemapper) carry a
per-service **cache-update lambda in the SAME default pipeline as the ECS service**, with
`build_lambda`/`build_lambdas` ordered BEFORE `build_and_publish_docker`. The docker/ECS
build runs *inside* the repo's own Dockerfile, so that step is pipeline-image-agnostic — but
`build_lambda` runs `dotnet publish` on the PIPELINE IMAGE itself, and being ordered first, a
failure there blocks docker+octopus → the ECS service never deploys either. So these repos
CANNOT have their ECS deployed independently of the lambda; the lambda's pipeline image,
Makefile `--runtime`, and Octopus `function-runtime` var must all move together with it, and
the lambda gets the delete-first deploy. Treat such a repo as ECS+lambda hybrid, not pure
ECS. (export is worst: TWO lambdas — Export.Lambda zip + ReportTransfers container; the
container one likely skips delete-first.)

**Container-image Lambdas (`PackageType=Image`, confirmed: cohortdata's `qa-v1-cohort-data`) do NOT
have the zip stale-cache bug** — check `aws lambda get-function-configuration --query PackageType`
before assuming delete-first is needed. Deploy is Docker build+publish to ECR + Octopus
`create-release.sh` referencing the new image; Terraform updates `image_uri`/digest in place and
Lambda actually swaps code (confirmed: digest + tag changed, `LastUpdateStatus=Successful`, a real
SQS-shaped test invoke ran the new code's business logic end-to-end). Only true zip lambdas
(`PackageType=Zip`, `dotnet-lambda package` in the pipeline) need delete-first. Check ECR for a
`public.ecr.aws/lambda/dotnet:<ver>` base (`docker manifest inspect`, both arch manifests)
before assuming none exists for a given runtime version.

**Not every ECS service rolls the same way — check `deploymentConfiguration` before panicking at `running=0`.** Most AMA services roll with headroom (new task up before old drains). But some Fargate services (confirmed: `exportproducer`) are `minimumHealthyPercent=0` + `maximumPercent=100`, so ECS STOPS the old task before starting the new one → a legitimate `running=0`/`pending=0` window of several minutes on EVERY deploy (image pull + ALB health-check registration stretch it to ~10 min). `failedTasks=0` + the only stopped task being the old taskdef with `stopCode=ServiceSchedulerInitiated`/exit 137 (SIGKILL-on-drain) = healthy rollout, NOT a crash. rollout flips to COMPLETED once the new task passes ALB health checks (which itself proves the app booted). Brief deploy-time downtime is inherent to that service's own config, not introduced by whatever change is being deployed.


**The `*.example-app.com` wildcard IS auto-renewed — by certbot on ECS, not by ACM. Don't
read `Type=IMPORTED` / `RenewalEligibility=INELIGIBLE` as "nothing renews this".** EventBridge rule
`renew-ama-certificate` (`cron(0 4 ? * MON-FRI *)`) runs Fargate task
`production-v1-certificate-renew` on cluster `production-v1-AMA`, which runs certbot and then
`acm import-certificate --certificate-arn <existing>` — **re-importing into the SAME ARN**
(`cbe128bc-181b-437a-9905-4ab60482e4cd`). That in-place reimport is why the ARN is hardcoded in 10
places in `yourproduct-backbone` and in the Octopus `certificate-arn` / ExporterPlus `CERTIFICATE`
vars and still never breaks; all 27 consumers (22 LBs incl. 3 classic ELBs + 5 CloudFront dists)
pick up new material with no listener or Terraform change. Runs as IAM **user**
`hs-production-example-app-renew` (2021-vintage static keys, image last built 2021) and
**fails silently** — no alarm, evidence only in log group `/ecs/production-v1-certificate-renew`
and bucket `hs-production-example-app-renew` (only the `-0001/` lineage is live; `-0003/`
and the bare prefix are dead 2021 leftovers). Reading that log group from git-bash needs
`MSYS_NO_PATHCONV=1` or the `/ecs/...` name gets path-mangled into an `InvalidParameterException`.
`*.<tenant domain>` is NOT covered by this job, and its Route53 zone is not in account
`000000000000` — so those certs can't be DNS-validated from our account at all (PROJ-15335).

## `yourproduct-backbone` — Terraform for AMA AWS infra

- Clone `~/Repos/AMA/yourproduct-backbone` (NOT under AMA_APP). Prod CloudFront `E30D5D8661NH9N` + WAF + website buckets = `Applications/AMA/ExporterPlus`; also Ingress ALB, Lambdas. State `s3://hs-<env>-terraform/Applications/AMA/<Component>/<ver>/terraform.tfstate`.
- Deploy: any-branch push → `_build/build.sh` → Octopus `Backbone_Applications_<...>` (ExporterPlus `Projects-152`): Plan → manual approval (Production + QA only) → Apply → CF invalidation. **Staging auto-applies, no approval.** Worker pins TF 0.13.3; no provider pin.
- Local read-only prod plan: render `#{...}` from `variables/preview?project=<id>&environment=<production>`, `terraform plan -lock=false` (method: `Applications/Ingress/README.md`). Bucket refresh 403 on planning identity reads as "deleted" — noise.
- Drift tracked in PROJ-15657. Console change → reverted by next apply; change code instead.
- **exporterplus CSP ≠ its nginx config** (PROJ-14687, 2026-10-12). Site = S3 via CloudFront (`ECUZT6F5CH29F` qa, `E14BLLDUYV61WT` staging, `E30D5D8661NH9N` prod); CSP added by Lambda@Edge origin-response `<env>-hs-response-headers` (qa:6, staging:13, prod:8 — nodejs14.x, code in NO repo, TF gets ARN via Octopus var `response-headers-lambda-arn`). `<env>-v1-exporterplus-api-esvc` = 0 tasks all envs → `nginx-config/` dead. admin is different: nginx container IS live. Check `Server:`/`X-Cache:` headers before trusting a CSP source.
