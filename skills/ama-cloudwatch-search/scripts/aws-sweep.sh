#!/usr/bin/env bash
# The AWS sweep, as a script. Usage: aws-sweep.sh <env> [--hours N]      env: qa|staging|production
# Runs AWS-SWEEP.md steps 1-4, 5, 6, 7, 8 in the fixed order and prints evidence per section.
# Steps 5a (running image vs Octopus release) and 8's "is that failed execution already
# fixed by a ticket" cross-check are judgement, left to the reader with the inputs printed.
#
# "Follow this same sequence every time, don't improvise" was a rule for the agent to
# remember while hand-running eight aws commands. The sequence is fixed, so it is a script.
set -uo pipefail
export MSYS_NO_PATHCONV=1 PYTHONUTF8=1
ENV="${1:?usage: aws-sweep.sh <env> [--hours N]}"; shift
HOURS=24; [ "${1:-}" = "--hours" ] && HOURS="${2:-24}"
CLUSTER="${ENV}-v1-AMA"
D="$(dirname "$0")"
sec() { printf '\n## %s\n' "$1"; }

sec "1. Services in $CLUSTER"
mapfile -t SVCS < <(aws ecs list-services --cluster "$CLUSTER" --max-items 200 2>/dev/null | jq -r '.serviceArns[]' | sed 's|.*/||' | sort)
[ "${#SVCS[@]}" -gt 0 ] || { echo "no services -- wrong env or no access"; exit 1; }
DESC="$(printf '%s\n' "${SVCS[@]}" | awk 'NR%10==1{if(l)print l; l=$0; next}{l=l" "$0} END{print l}' \
  | while read -r batch; do aws ecs describe-services --cluster "$CLUSTER" --services $batch 2>/dev/null | jq -c '.services[]'; done)"
LIVE=(); DORMANT=()
while IFS= read -r s; do
  n="$(printf '%s' "$s" | jq -r '.serviceName')"; d="$(printf '%s' "$s" | jq -r '.desiredCount')"
  if [ "$d" = "0" ]; then DORMANT+=("$n"); else LIVE+=("$n"); fi
done <<< "$DESC"
echo "live: ${LIVE[*]}"; echo "dormant (desired=0, expected for exporterplus/cacheupdatecoordinator): ${DORMANT[*]:-none}"

sec "2. Recently STOPPED tasks (retention ~1h on qa -- any here is already suspicious)"
aws ecs list-tasks --cluster "$CLUSTER" --desired-status STOPPED 2>/dev/null | jq -r '.taskArns[]?' | while read -r t; do
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$t" 2>/dev/null \
    | jq -r '.tasks[] | "  \(.group)  stopped=\(.stoppedAt // "?")  code=\(.stopCode // "?")  reason=\((.stoppedReason // "")[0:90])  exit=\(.containers[0].exitCode // "-")"'
done | sed '/^$/d' | { grep . || echo "  none"; }

sec "3. Service health (running!=desired, pending>0, rollout!=COMPLETED, >1 deployment)"
printf '%s\n' "$DESC" | jq -r 'select(.desiredCount > 0)
  | select(.runningCount != .desiredCount or .pendingCount > 0 or (.deployments|length) > 1 or (.deployments[0].rolloutState // "") != "COMPLETED")
  | "  \(.serviceName): running=\(.runningCount)/\(.desiredCount) pending=\(.pendingCount) deployments=\(.deployments|length) rollout=\(.deployments[0].rolloutState // "-")"' | { grep . || echo "  all live services steady"; }

sec "4. Running task age (young startedAt on a 'steady' service = restart loop)"
for n in "${LIVE[@]}"; do
  for t in $(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$n" --desired-status RUNNING 2>/dev/null | jq -r '.taskArns[]?'); do
    aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$t" 2>/dev/null | jq -r --arg n "$n" \
      '.tasks[] | "  \($n)  started=\(.startedAt)  image=\(.containers[0].image | sub(".*/";""))"'
  done
done | awk '{ cmd="date -u -d \""$2"\" +%s 2>/dev/null"; sub(/started=/,"",$2); cmd="date -u -d \""$2"\" +%s"; cmd | getline st; close(cmd); age=int((systime()-st)/60); printf "%s  age=%dm%s\n", $0, age, (age<30 ? "  <-- YOUNG" : "") }'

sec "5. Service events (repeated start/stop pairs = a loop; one started->registered->steady = a deploy)"
printf '%s\n' "$DESC" | jq -r 'select(.desiredCount > 0) | "  \(.serviceName):", (.events[0:4][] | "    \(.createdAt[0:19])  \(.message[0:110])")'

sec "6. CloudWatch log sweep, last ${HOURS}h, crash-class filter (known noise segregated by the script)"
for n in "${LIVE[@]}"; do
  td="$(printf '%s\n' "$DESC" | jq -r --arg n "$n" 'select(.serviceName==$n) | .taskDefinition')"
  lg="$(aws ecs describe-task-definition --task-definition "$td" 2>/dev/null | jq -r '.taskDefinition.containerDefinitions[0].logConfiguration.options["awslogs-group"] // empty')"
  [ -n "$lg" ] || { echo "  $n: no awslogs-group on its task definition"; continue; }
  # BrokerUnreachable + the RabbitMQ.Client phrase: a backbone apply swapped the Staging broker
  # NLB security group and every export API logged these for ~9h unnoticed (2026-10-14).
  out="$(bash "$D/cloudwatch-search-logs.sh" "$lg" "${HOURS} hours ago" "now" '?Unhandled ?FATAL ?ld.so ?OutOfMemory ?Segmentation ?panic ?terminated ?CrashLoop ?BrokerUnreachable ?"None of the specified endpoints"' 20 2>/dev/null | sed '1,3d')"
  if [ -n "$out" ]; then printf '  %s (%s):\n%s\n' "$n" "$lg" "$(printf '%s' "$out" | sed 's/^/    /')"; else echo "  $n ($lg): clean"; fi
done

sec "7. CloudWatch alarms in ALARM"
aws cloudwatch describe-alarms --state-value ALARM 2>/dev/null | jq -r '.MetricAlarms[]? | "  \(.AlarmName)  since=\(.StateUpdatedTimestamp)  \(.StateReason[0:100])"' | { grep . || echo "  none"; }

sec "8. Cache-update Step Functions FAILED executions, last ${HOURS}h (check: older than the last deploy, or already ticketed?)"
. "$HOME/.claude/hooks/lib-harness-repos.sh"
ACCT="$(hr_config '.aws.accountNumber' '')"; REGION="$(hr_config '.aws.region' 'us-east-1')"
since="$(date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)"
aws stepfunctions list-executions --state-machine-arn "arn:aws:states:$REGION:$ACCT:stateMachine:${ENV}-v1-cacheupdate-statemachine" \
  --status-filter FAILED --max-items 20 2>/dev/null \
  | jq -r --arg s "$since" '.executions[]? | select(.startDate >= $s) | "  \(.name)  started=\(.startDate)  stopped=\(.stopDate)"' | { grep . || echo "  none in window"; }
echo
echo "Judgement left to you: step 5a (running image vs Octopus release -- resolve-aws-names.sh / verify-octopus-env-deploys.sh), and whether any step-8 failure predates the last deploy or matches a resolved ticket."
