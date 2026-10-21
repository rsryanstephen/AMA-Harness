#!/usr/bin/env bash
# Approve (Proceed) the pending manual intervention on Octopus task(s) -- NON-PRODUCTION ONLY.
#   bash ~/.claude/scripts/octopus-approve.sh approve ServerTasks-N [ServerTasks-N ...]
# Gated by hooks/octopus-approve-preflight-gate.sh: each task needs a fresh SAFE/REVIEW stamp from
# scripts/octopus-approval-preflight.sh. Octopus itself fences Production: the service account is only in
# "Claude non-prod approvers" (Teams-101), which is responsible only on the "(non-production)" copy of
# each Backbone approval step (Development/QA/Staging). This script refuses Production anyway.
# Start scripts/octopus-task-watch.sh on each task afterwards so the apply's outcome comes back.
set -u
[ "${1:-}" = approve ] && shift
[ $# -gt 0 ] || { sed -n '3p' "$0"; exit 2; }
CONFIG="$HOME/.claude/harness-config.json"
SERVER="$(jq -r '.octopus.serverUrl // "https://yourorg.octopus.app"' "$CONFIG" 2>/dev/null | tr -d '\r')"
SPACE="$(jq -r '.octopus.spaceId // "Spaces-1"' "$CONFIG" 2>/dev/null | tr -d '\r')"
PROD="$(jq -r '.octopus.environmentIds.production // "<production>"' "$CONFIG" 2>/dev/null | tr -d '\r')"
O="$SERVER/api/$SPACE"; H="X-Octopus-ApiKey: ${OCTOPUS_API_KEY:-}"
[ -n "${OCTOPUS_API_KEY:-}" ] || { echo "OCTOPUS_API_KEY not set"; exit 2; }
api() { curl -sS --max-time 30 -H "$H" "$@" 2>/dev/null | tr -d '\r'; }
rc=0
for t in "$@"; do
  dep="$(api "$O/tasks/$t" | jq -r '.Arguments.DeploymentId // empty')"
  env="$(api "$O/deployments/$dep" | jq -r '.EnvironmentId // empty')"
  if [ -z "$env" ] || [ "$env" = "$PROD" ]; then echo "$t: REFUSED (environment ${env:-unknown}) -- Production approvals are the user's"; rc=1; continue; fi
  iid="$(api "$O/interruptions?regarding=$t&pendingOnly=true" | jq -r '.Items[0].Id // empty')"
  [ -n "$iid" ] || { echo "$t: no pending interruption"; rc=1; continue; }
  api -X PUT "$O/interruptions/$iid/responsible" >/dev/null
  out="$(jq -n '{Result:"Proceed", Notes:"Approved by Claude Code after octopus-approval-preflight.sh (SAFE/REVIEW)."}' | api -X POST -H 'Content-Type: application/json' --data-binary @- "$O/interruptions/$iid/submit")"
  echo "$t: $iid -> $(printf '%s' "$out" | jq -r 'if .IsPending == false then "approved" else (.ErrorMessage // "pending still") end')"
done
exit $rc
