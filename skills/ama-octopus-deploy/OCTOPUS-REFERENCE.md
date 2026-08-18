# Octopus Deploy REST API — AMA_APP reference

Server: `https://yourorg.octopus.app` (see [SKILL.md](SKILL.md) for the wrong-hostname
gotcha and the Bitbucket-branch workaround). Auth: header
`X-Octopus-ApiKey: $OCTOPUS_API_KEY` — confirmed working against `/api/users/me`
(identity: `automation@example.com`). Server/space/identity are mirrored as
`octopus.serverUrl`/`octopus.spaceId`/`octopus.automationServiceAccountEmail` in
`~/.claude/harness-config.json` — that's the source of truth for a different adopter.

## Space: `Spaces-1` (YourProduct) — not the Default space

AMA_APP lives in `Spaces-1`. Querying `Spaces-1` (Default) silently returns empty results
(no environments, no AMA projects) — looks like "nothing configured," not an error. If
unsure of the space, enumerate first: `GET /api/spaces/all`.

## Project naming — same ambiguity as the Bitbucket→Octopus mapping in verify-deployment-e2e.sh

Searching projects by repo name (e.g. "feedback") can return TWO matches:
`Backbone_Applications_AMA_<Repo>` and `YourProduct_Exporter_<Repo>_ECS`. For ECS
deploy/rollout work, use the `_ECS`-suffixed one — same convention already confirmed in
`verify-deployment-e2e.sh`'s Octopus-project resolution.

## Environments — filter to the `YourProduct-*` prefix

`Spaces-1` has 16 environments total, most NOT AMA-relevant (shared space with other
teams' projects). The ones that matter: `YourProduct-Development(21)`, `YourProduct-QA(22)`,
`YourProduct-Staging(23)`, `YourProduct-Production(24)`. Generically-named ones (`Staging`,
`QA`, `Prod` with no `YourProduct-` prefix) belong to other projects — don't match on name
alone.

## Channels have per-channel lifecycles — this is why manual deploys to "unreachable" environments are possible

Each project has multiple channels (seen: `Default`, `Development`, `Hotfix`, `Master`,
`Release`, `Testing`), each pointing at its own lifecycle. A lifecycle's phases mark each
environment as an `AutomaticDeploymentTarget` or `OptionalDeploymentTarget` — e.g. the
Testing channel's lifecycle marks `YourProduct-QA` automatic but `YourProduct-Staging`
optional (manual-deploy-allowed). This is why a `develop`-branch (Testing-channel)
release CAN be manually deployed to Staging via the API even though auto-deploy only
reaches QA — don't assume a channel is locked to only its auto-deploy target.

## Key endpoints

- List releases for a channel: `GET /api/{space}/projects/{projectId}/channels/{channelId}/releases?take=N` → `Id`, `Version`, `Assembled`.
- Full deploy state per environment: `GET /api/{space}/projects/{projectId}/progression` → `Environments[]` + `Releases[].Deployments{envId: [{State}]}`.
- Trigger a deployment: `POST /api/{space}/deployments` body `{"ReleaseId":"Releases-X","EnvironmentId":"Environments-Y"}` → response `TaskId`.
- Poll deployment status: `GET /api/tasks/{taskId}` → `State` (`Executing`/`Success`/`Failed`/`Canceled`), `ErrorMessage`.

**Gotcha**: a deployment task can still be `Executing` past this harness's 2-minute Bash
tool timeout — plan a second, later poll call rather than expecting one call to catch
completion. Not an Octopus issue, a tool-timeout one.

## Confirmed end-to-end

A Testing-channel release for `feedback` deployed to `YourProduct-Staging` this way, task
succeeded, ECS task definition's image tag cross-verified via
`aws ecs describe-task-definition` against the release version.
