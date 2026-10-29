#!/usr/bin/env bash
# Watch an ElastiCache service update on one replication group until it finishes, then run
# the pass checks. Applying is a separate, user-approved step (batch-apply-update-action).
# Usage: elasticache-update-watch.sh <replication-group> <service-update-name> <env>
#   env: qa | staging | production  (picks the cache-update state machine + Graylog env)
# Run with run_in_background: ~30 min per group whatever the node count (3- and 4-node
# groups all took 27-29 min, 2026-10-20/21) -- past the 10-min foreground Bash cap.
#
# Pass checks:
#   - The failover signature, not "Redis": these apps never log that word. PROJ-15831
#     was closed "no Redis errors" while 129 reconnect messages and a failed prod cache
#     update sat in the window. See ama-graylog-search KNOWN-SIGNATURES.md section 8.
#   - Cache-update executions in the window: a failover mid-run fails the run. Pass = one
#     SUCCEEDED after the patch finished; else trigger a main cache update.
# NodesUpdated[] comes back null on these groups -- read UpdateActionStatus only.
export MSYS_NO_PATHCONV=1
rg="${1:?replication group}"; su="${2:?service update name}"; env="${3:?qa|staging|production}"
G="$HOME/.claude/skills/ama-graylog-search/scripts/graylog-search.sh"
start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; prev=""
for _ in $(seq 1 120); do
  st="$(aws elasticache describe-update-actions --service-update-name "$su" --replication-group-ids "$rg" \
        --query 'UpdateActions[0].UpdateActionStatus' --output text 2>&1 | tr -d '\r')"
  [ "$st" != "$prev" ] && { echo "$(date +%H:%M) $rg $st"; prev="$st"; }
  case "$st" in complete|stopped|not-applicable) break ;; esac
  sleep 120
done
end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
aws elasticache describe-update-actions --service-update-name "$su" --replication-group-ids "$rg" \
  --query 'UpdateActions[0].{status:UpdateActionStatus,slaMet:SlaMet}' --output json
echo "replication group: $(aws elasticache describe-replication-groups --replication-group-id "$rg" \
  --query 'ReplicationGroups[0].Status' --output text)"

echo "== failover signature $start..$end (by application)"
bash "$G" "environment:$env AND (\"ConnectionMultiplexer\" OR \"cannot be issued to a replica\" OR \"CACHE MANAGER\")" \
  "${start%Z}.000Z..${end%Z}.000Z" "" 200 'timestamp,application' \
  | jq -r '"total \(.total_results)", (.messages | group_by(.application)[] | "  \(.[0].application) \(length)")'

acct="$(aws sts get-caller-identity --query Account --output text)"
echo "== $env cache-update executions (newest first) -- any FAILED inside the window needs a SUCCEEDED after it"
aws stepfunctions list-executions --max-items 5 \
  --state-machine-arn "arn:aws:states:us-east-1:$acct:stateMachine:$env-v1-cacheupdate-statemachine" \
  --query 'executions[].[status,startDate,stopDate,name]' --output text
