---
name: ama-octopus-deploy
description: Trigger, check, or promote an Octopus Deploy deployment for AMA_APP. Use for "deploy the pilot to QA", "deploy this branch to staging", "promote the release to production", "ship this to prod", "do I have Octopus access", "what's currently deployed to X", or before guessing at Octopus server/space/project naming.
---

# Octopus Deploy for AMA_APP

See [OCTOPUS-REFERENCE.md](OCTOPUS-REFERENCE.md) for the full API reference — auth, space,
project naming, environments, channel lifecycles, key endpoints, and a confirmed
end-to-end deployment example. Read it before hand-rolling a call.

## Don't guess the server hostname

**Server is `https://yourorg.octopus.app`** (mirrored as `octopus.serverUrl` in
`~/.claude/harness-config.json` — swap that field for a different adopter).
`octopus.yourorg.net` resolves via internal DNS but its HTTPS connection times
out — not a real endpoint. If
the correct host fails to resolve, check the transient-VPN-DNS-blip note in
[[commit-ticket]] before assuming the server itself is unreachable.

## Repo name → Octopus project isn't a plain substring match

A loose match on `search` also matches `etl-load-elasticsearch-emr` and
`backbone-elasticsearch` ("search" inside "elasticsearch"). Anchor to
`product-service-<repo>...-ecs` / `other-project-<repo>...-ecs` and require
the `-ecs` suffix specifically — some repos (e.g. `search`) also have a coincidentally
same-versioned `-cacheupdate-lambda` project that isn't the one you want.

If resolution still isn't unambiguous (zero or multiple projects share the expected
version), stop and list the candidates rather than guessing — flag it to the user.

## Version is the cross-system key

`build-and-publish.sh` hardcodes ECS Docker tags as `2.0.0.<BITBUCKET_BUILD_NUMBER>` — no
`VersionPrefix`, no branch suffix (unlike the NuGet path in `package.sh`). The same value
shows up as the Octopus release version and the deployed image tag.

**A service being up/healthy/responding is NOT proof it's running the version Octopus
says it deployed — always cross-check the actual running image tag against Octopus's
release version, don't infer from "it's working."** Check the deployed image tag
directly (`aws ecs describe-task-definition` / `verify-deployment-e2e.sh`, which
already does this) — a working ECS task and a correctly-deployed ECS task are
different claims.

E.g. `reports` crash-looped on build `204`, so ECS kept serving `203` while Octopus
still reported `204` as deployed — invisible precisely because nothing failed outright.

**A version "mismatch" doesn't always mean stale.** `BITBUCKET_BUILD_NUMBER` is a per-repo
counter shared across ALL branches, not per-branch. If `develop` hasn't been pushed in a
while but `master` has, the latest `develop` build number can be LOWER than what's
actually deployed (e.g. `cohortdata` develop build `#31` vs QA running `#313` — not a
regression). Read a mismatch as "not verified against the build just pushed," not
automatically "QA is behind."

## Deploying a Lambda — delete the existing function first, or it silently runs stale code

Octopus/Terraform deploying over an EXISTING Lambda can leave the old code running even
though `LastModified`/`CodeSize`/`Runtime` all look updated (a net8 build kept running
under a `dotnet10` runtime flip, crashing every invocation).
Fix: `aws lambda delete-function --function-name <env>-v1-<name>` before every Octopus
Lambda deploy, not just misbehaving ones. Verify via the deployed zip's
`*.runtimeconfig.json` `tfm` (`aws lambda get-function` → `Code.Location`), not just the
`Runtime` field.

**Gate-enforced** (`octopus-lambda-delete-gate.sh`): a `POST .../deployments` is denied
unless a `delete-function` was recorded this session. Not a Lambda project → prefix
`OCTOPUS_TARGET_NOT_LAMBDA=1`. Prose alone did NOT hold — see below.

**Verify the ARTIFACT after every Lambda deploy, not the task state.** Octopus reporting
`Success` and `LastModified` moving to now are BOTH consistent with the old code still
running — confirmed live 2026-08-17: a PROJ-15297 hotfix deployed green to Staging
and kept running a `2025-03-18` build, so the fix looked broken and ~40 min went into
re-diagnosing correct code. Check the DLL dates in the deployed package:
```bash
url=$(aws lambda get-function --function-name <env>-v1-<name> --query 'Code.Location' --output text)
curl -sS -o /tmp/fn.zip "$url" && unzip -l /tmp/fn.zip | grep -i '<YourAssembly>.dll'
```
Dates older than the build you just shipped ⇒ stale deploy: delete the function and
redeploy the SAME release, then re-check. Same release id redeployed after a delete
produced a same-day artifact.

## Changed a variable? Redeploying an EXISTING release still ships the OLD value

**Octopus snapshots variable values into a release at creation time — redeploying an
existing release replays that snapshot, it does NOT pick up live variable edits.**
Same class of "looks deployed, isn't really" mistake as the Lambda-stale-code gotcha
above.

After changing any variable, before redeploying an EXISTING release (not creating a
new one): refresh that release's snapshot first.

```bash
curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" \
  "https://yourorg.octopus.app/api/Spaces-1/releases/<release-id>" | jq -r '.Links.SnapshotVariables'
curl -sS -X POST -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" \
  "https://yourorg.octopus.app/api/Spaces-1/releases/<release-id>/snapshot-variables"
```

Then redeploy. Verify the actual effect landed (fetch the live served config/response),
not just that the deployment task succeeded — a successful deploy of a stale snapshot
still reports success.

## Can't reach Octopus at all? A Bitbucket-branch workaround exists

Re-running/pushing a Bitbucket pipeline on `develop` auto-deploys to **QA** (`develop` →
Testing channel, set to auto-deploy QA). Running one on a `release/*` branch (check Jira
for the current release number) auto-deploys to **Staging**. If Octopus itself is
unreachable/unverifiable, triggering the right Bitbucket branch still gets a build
deployed without needing direct Octopus access — see [[ama-bitbucket-api]] for triggering.

## After triggering a deployment

Hand off to [[ama-cloudwatch-search]]'s `DEPLOY-VERIFICATION.md` (`verify-qa-deploy.sh` /
`verify-deployment-e2e.sh`) to confirm it actually landed clean on the AWS/ECS side — this
skill covers the Octopus half, not the runtime-health half.
