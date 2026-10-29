#!/usr/bin/env bash
# PostToolUse (Bash|PowerShell). Production twin of octopus-staging-cache-update-reminder.sh:
# after an Octopus deploy POST to YourProduct-Production, nudge the cache-update decision.
#
# Staging got its reminder because prose failed three hotfixes running (129.0.9-.11 shipped
# with zero Staging cache-update executions). The identical requirement on the Production
# side -- ama-deploy-release Step 4b, "required only when the deploy touched report fields
# or SqlTemplates ... confirm it actually completed" -- stayed prose with nothing behind it
# (2026-09-15 audit). Same shape as the staging hook's Trigger A; there is no git push to
# diff on the production path, so this is a decision-nudge, not a classifier.
set -u
IFS= read -r -d '' payload || true
case "$payload" in *deployments*|*octo-deploy*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0

. "$HOME/.claude/hooks/lib-octopus-deploy-detect.sh" 2>/dev/null || exit 0
region="$(octo_scan_region "$command")"
octo_is_deploy_post "$region" || exit 0

CONFIG="$HOME/.claude/harness-config.json"
prod_env="<production>"
[ -f "$CONFIG" ] && prod_env="$(jq -r '.octopus.environmentIds.production // "<production>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
normalized="$(printf '%s' "$region" | sed 's/\\"/"/g')"
printf '%s' "$normalized" | grep -qF "$prod_env" || exit 0

# The command SHAPE is not a deployment. When a PreToolUse gate blocked a combined
# write-script-and-deploy command, both prod reminders still announced "deployment just
# triggered" and pointed at sweeping tickets to Done for a deploy that never ran
# (2026-09-18). Octopus answers a real POST with a Deployments-N / ServerTasks-N id; a
# wrapper that polls the task prints one too. No such evidence in the response -> silent.
# No tool_response at all -> fail open (nudge), same stance as ticket-in-progress-reminder.sh.
. "$HOME/.claude/hooks/lib-octopus-deploy-detect.sh" 2>/dev/null
octo_response_shows_deploy "$payload" || exit 0

jq -cn '{decision:"block", reason:"Production deployment just triggered via Octopus. Did this release touch report fields or SqlTemplates (ama-deploy-release Step 4b'"'"'s trigger condition)? If so: wait for every touched ECS service to read rolloutState COMPLETED (`wait-ecs-rollout.sh production <services>`), THEN trigger the `main` cache update for production and CONFIRM it completed (`query-cacheupdate-stepfunction.sh production <time>` -- Success, not just triggered). Skipping this on 2026-08-25 left production serving stale report metadata. If nothing report-field/SqlTemplate-shaped changed, no cache update is needed -- a decision, not an unconditional action."}'
exit 0
