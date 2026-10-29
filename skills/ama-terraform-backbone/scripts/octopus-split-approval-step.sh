#!/usr/bin/env bash
# Give Claude (service account, team "Claude non-prod approvers") approval rights on a project's Terraform
# plan in Development/QA/Staging ONLY, by splitting its single "Approve ... Plan" manual step in two:
#   original step  -> excludes Dev/QA/Staging (= the Production approval, teams unchanged)
#   "(non-production)" copy -> Dev/QA/Staging only, teams + Claude non-prod approvers
# Octopus snapshots the process into each release, so only releases created AFTER the split are affected.
# Done for all 42 Backbone projects on 2026-10-15 (PROJ-15658); run it for any NEW Backbone project.
# Usage: octopus-split-approval-step.sh dry|apply <Projects-N>...
# Skips: no approval step, already split, several approval steps, disabled step, no responsible team
# (anyone may approve -- adding a team would RESTRICT it; decide with the user). Backs up each process
# to $(hscratch octopus-process-backup proc-<id>.json) before the PUT. Afterwards audit: no manual step
# that can run in Production may list the Claude team.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"
MODE="${1:-}"; shift || true
[ "$MODE" = dry ] || [ "$MODE" = apply ] || { sed -n '9p' "$0"; exit 2; }
CONFIG="$HOME/.claude/harness-config.json"
SERVER="$(jq -r '.octopus.serverUrl // "https://yourorg.octopus.app"' "$CONFIG" 2>/dev/null | tr -d '\r')"
SPACE="$(jq -r '.octopus.spaceId // "Spaces-1"' "$CONFIG" 2>/dev/null | tr -d '\r')"
O="$SERVER/api/$SPACE"; H="X-Octopus-ApiKey: ${OCTOPUS_API_KEY:-}"
[ -n "${OCTOPUS_API_KEY:-}" ] || { echo "OCTOPUS_API_KEY not set"; exit 2; }
TEAM="$(curl -sS -H "$H" "$SERVER/api/teams/all" | jq -r '.[] | select(.Name=="Claude non-prod approvers") | .Id' | tr -d '\r')"
[ -n "$TEAM" ] || { echo "team 'Claude non-prod approvers' not found"; exit 2; }
NONPROD="$(jq -c '[.octopus.environmentIds.development // "<development>", .octopus.environmentIds.qa // "<qa>", .octopus.environmentIds.staging // "<staging>"]' "$CONFIG" | tr -d '\r')"
for p in "$@"; do
  pj="$(curl -sS -H "$H" "$O/projects/$p" | tr -d '\r')"; name="$(printf '%s' "$pj" | jq -r .Name)"; dp="$(printf '%s' "$pj" | jq -r .DeploymentProcessId)"
  proc="$(curl -sS -H "$H" "$O/deploymentprocesses/$dp" | tr -d '\r')"
  verdict="$(printf '%s' "$proc" | jq -r '
    [.Steps[] | select(.Actions[0].ActionType=="Octopus.Manual" and (.Actions[0].Name|test("^Approve";"i")))] as $a
    | if ($a|length)==0 then "skip:no-approval-step"
      elif ([.Steps[].Name] | map(test("non-production";"i")) | any) then "skip:already-split"
      elif ($a|length)>1 then "skip:several-approval-steps"
      elif $a[0].Actions[0].IsDisabled then "skip:approval-step-disabled"
      elif (($a[0].Actions[0].Properties["Octopus.Action.Manual.ResponsibleTeamIds"] // "") == "") then "skip:no-responsible-team"
      else "split" end')"
  if [ "$verdict" != split ]; then echo "$p $name: $verdict"; continue; fi
  new="$(printf '%s' "$proc" | jq --arg team "$TEAM" --argjson np "$NONPROD" '
    (.Steps | map(.Actions[0].ActionType=="Octopus.Manual" and (.Actions[0].Name|test("^Approve";"i"))) | index(true)) as $i
    | .Steps[$i] as $orig
    | ($orig.Actions[0].Environments) as $envs
    | (if ($envs|length)==0 then $np else [$envs[] | select(. as $e | $np | index($e))] end) as $npEnvs
    | ($orig | del(.Id, .Slug) | .Name = ($orig.Name + " (non-production)")
        | .Actions |= map(del(.Id, .Slug, .Links) | .Name = (.Name + " (non-production)") | .Environments = $npEnvs | .ExcludedEnvironments = []
            | .Properties["Octopus.Action.Manual.ResponsibleTeamIds"] = ((.Properties["Octopus.Action.Manual.ResponsibleTeamIds"] | split(",")) + [$team] | unique | join(",")))) as $copy
    | .Steps[$i].Actions |= map(if ($envs|length)==0
          then .ExcludedEnvironments = ((.ExcludedEnvironments + $np) | unique)
          else .Environments = [.Environments[] | select(. as $e | $np | index($e) | not)] end)
    | if ($npEnvs|length)==0 then . else .Steps = (.Steps[0:$i+1] + [$copy] + .Steps[$i+1:]) end')"
  if [ "$MODE" = apply ]; then
    printf '%s' "$proc" > "$(hscratch octopus-process-backup "proc-$p.json")"
    out="$(printf '%s' "$new" | curl -sS -X PUT -H "$H" -H 'Content-Type: application/json' --data-binary @- "$O/deploymentprocesses/$dp" | tr -d '\r')"
    err="$(printf '%s' "$out" | jq -r '.ErrorMessage // empty')"
    [ -n "$err" ] && echo "$p $name: PUT FAILED $err" || echo "$p $name: SPLIT (process v$(printf '%s' "$out" | jq -r .Version))"
  else
    echo "$p $name: would split"
  fi
done
