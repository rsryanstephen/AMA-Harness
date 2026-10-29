# Auth and security

## Two auth schemes, chosen per-endpoint, never global

`auth` (YourCompany.Product.Auth) registers both JWT-Bearer (Cognito RSA) and HMAC
(`softaware.Authentication.Hmac`) as separate schemes — no global default-policy requiring
auth. Every controller action explicitly declares
`[Authorize(AuthenticationSchemes = AuthenticationSchemes.JwtBearer)]` or `.Hmac` — never
bare `[Authorize]`. This is load-bearing, see next point.

## `UseAuthorization()` before `UseAuthentication()` — works by accident, fragile

Confirmed in `manage`, `search`, `reports`: `UseAuthorization()` is called BEFORE
`UseAuthentication()` in `Configure()` (backwards from the normal convention) — same
`// HMAC Authentication` comment stuck above the misplaced call in all three, evidence
it's accidental copy-paste, not deliberate.

**Why it works anyway**: every `[Authorize]` names explicit `AuthenticationSchemes`.
ASP.NET Core's `PolicyEvaluator`, when a policy specifies schemes, calls
`context.AuthenticateAsync(scheme)` itself inside the authorization middleware and sets
`HttpContext.User` there — it does NOT depend on `UseAuthentication` having run first.

**The trap**: add any endpoint with a bare `[Authorize]` (no schemes), or add a global
default auth policy, and it silently breaks — falls back to depending on
`UseAuthentication`, which runs too late in this pipeline. Any endpoint MUST specify
schemes explicitly, or this pipeline ordering bug becomes a real bug.

## `AuthService.GetUserId()` throws on HMAC-authenticated requests

`YourCompany.Product.Auth/Security/AuthService.cs`: pulls JWT from the `access_token` claim
or raw `Authorization` header, parses `Subject` as `Guid`. If identity is HMAC
(`AuthenticationType == "HMAC"`) it throws `InvalidOperationException`. Any shared logic
calling `IAuthService.GetUser()`/`GetUserId()` on an HMAC-authed (service-to-service)
request crashes unless the caller checks `IsHmacIdentity()` first.

## JWT validation specifics

RSA key built at runtime from `Modulus`/`Exponent` (base64url) in config, not a JWKS
fetch. `ValidateAudience = false` deliberately — Cognito access tokens (unlike id tokens)
have no `aud` claim. `ClockSkew = TimeSpan.Zero`.

Cognito groups → ASP.NET roles happen in `OnTokenValidated`: `ClaimsBuilder.Build()` reads
`cognito:groups` from the JWT and adds each as a `ClaimTypes.Role` claim — this is why
`[Authorize(Roles = "UserManagement")]` works against Cognito groups directly, no separate
role service.

Which group opens which report template (reports `Filters/UserReportAccessCheck/*Rule.cs` +
`RuleEngines/ReportSummaryRules/*`, checked 2026-10-07): `pool-data` → `PoolLoanView` (or
Admin/UserManagement; exporterplus `aggregations.component.ts` checks PoolLoanView/Admin too).
`cmo-mega-view` / `cmo-mega-servicing-transfer` → `Tier3500` suffices; the Cognito groups
`CmoMegaViewer` and `CmoServicingTransferViewer` are legacy, read by NO rule. MCF cohort reports
(`mcf-header-export`) → `McfHeaderCohortReport` (exporterplus route guard). The Admin interface
can assign only the groups in manage's `CognitoGroup`/`Role` enums (PoolLoanView added
PROJ-15475); any other group is AWS console/CLI only (`admin-add-user-to-group`).

## External client IP whitelisting = hand-edited security groups, not IaC

Prod client allowlist for `hs-prod-elasticsearch` / `hs-prod-aggregation-api` is
`sg-0938a8f75b287262d` "HS Production - New Refinitiv external access" — same CIDRs
replicated across ports 80/443/8080/9200. Edited in AWS by hand; **rules are in no repo.**
Aggregation-API does not actually listen on 8080 (prod-only, PROJ-15313) — Elasticsearch
does; the rule replication predates that and is otherwise harmless.

`yourproduct-backbone` consumes SG **IDs** only, via Octopus vars
(`external_elb_security_group_ids` on BackBone_Elasticsearch/Projects-179,
`lb-security-groups` on Backbone_Applications_AggregationAPI/Projects-138). No
`aws_security_group_rule` targets these. So: rule edits survive a Terraform apply,
**attach/detach does NOT** — update the Octopus var too or the next apply reverts it.

Three traps. Load balancers cap at **5 SGs**, hard, whatever an EC2 ENI shows (instances
can hold 6+); a 6th on an ELB/ALB fails `InvalidConfigurationRequest`. SG rules here carry
**no descriptions**, so no CIDR is attributable to a requester — always set one. Access
logging is **off** on the prod ES ELB and both aggregation-api ALBs, so you cannot check
whether an existing allowlist entry is still used.

Unrelated despite the name: `api-testing/whitelist-ip.sh` drives a WAFv2 **CLOUDFRONT** IP
set `${env}-allowed-ip-addresses` for build runners on qa/staging. Different mechanism.

## IAM access-key audits: "not used in 90+ days" is not "unused"

- Self-managed ES 5.x nodes (`*.es.prod.hs` / `*.es.dev.hs`) have NO instance profile.
  discovery-ec2 signs `ec2:DescribeInstances` with IAM-user keys baked into the boot config
  (`yourproduct-infrastructure` `administration/elasticsearch/awsami/bootconfig/*/{prod,dev}/elasticsearch.*.yml`):
  `hs_production_user` (prod), `hs_development_user` (dev). Calls happen only at node start /
  master loss -> key shows last-used months ago, yet deactivating it breaks the next restart
  (PROJ-15494 switched the prod one off, reverted same day). Retire with the managed-ES
  migration (PROJ-15867), not by key rotation.
- Before deactivating ANY key: CloudTrail event history is 90 days only, but trail
  `AMA-account-cloudtrail` -> S3 `aws-cloudtrail-logs-000000000000-174c3989` keeps everything
  since 2025 (no lifecycle, ~58 GB). Sync just the hour around the key's last-used time
  (`aws s3 sync … --exclude '*' --include '*_YYYYMMDDTHH*'`, one process -- per-file `s3 cp`
  is ~4.5 s/file) and match `userIdentity.accessKeyId`; map `sourceIPAddress` via VPC CIDRs
  (prod `173.31/16`, dev `174.0/16` -- non-RFC1918, private IPs appear as-is) or ENI public IPs.
  Also grep the config repos for the key id. GuardDuty is OFF in this account.
- Whole-archive question (every use of N keys) -> Athena partition-projection table over that
  bucket (region enum x `yyyy/MM/dd` day, CloudTrailInputFormat): one `WHERE accesskeyid IN (…)`
  scan = ~58 GB = ~$0.29 (2026-10). Native AWS CLI can't read `/c/...` paths: `file://$(cygpath -m f.sql)`.
  Day-limited `sourceipaddress IN (…)` query attributes an IP via named console logins (<$0.01).
- Trail = MANAGEMENT events only: S3 object reads/writes are NOT in it. Those are only in S3 server
  access logs (`hs-{prod,qa,staging}-s3-server-logs`; prod = 4.6 TB, ~$23/full scan; covers
  `hs-production-emr`, `prod-yourproductv1-s3`). "No misuse" = "none in account activity since 2025-06-18".

## HMAC replay protection is in-memory only

`AddHmacAuthenticationExtension` wires `IMemoryCache` for nonce/replay tracking —
per-instance, not shared (e.g. Redis). With multiple pods behind a load balancer, replay
protection is only as good as sticky routing / a short `MaxRequestAgeInSeconds`, not truly
fleet-wide.
