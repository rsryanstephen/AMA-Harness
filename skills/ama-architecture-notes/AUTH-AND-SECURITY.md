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

## External client IP whitelisting = hand-edited security groups, not IaC

Prod client allowlist for `hs-prod-elasticsearch` / `hs-prod-aggregation-api` (both :8080)
is `sg-0938a8f75b287262d` "HS Production - New Refinitiv external access" — same CIDRs
replicated across ports 80/443/8080/9200. Edited in AWS by hand; **rules are in no repo.**

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

## HMAC replay protection is in-memory only

`AddHmacAuthenticationExtension` wires `IMemoryCache` for nonce/replay tracking —
per-instance, not shared (e.g. Redis). With multiple pods behind a load balancer, replay
protection is only as good as sticky routing / a short `MaxRequestAgeInSeconds`, not truly
fleet-wide.
