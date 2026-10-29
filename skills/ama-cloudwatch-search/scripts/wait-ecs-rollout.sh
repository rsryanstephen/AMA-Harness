#!/usr/bin/env bash
# Block until every named ECS service has finished rolling out.
# Usage: wait-ecs-rollout.sh <env> <service-short-name>... [--max-minutes N]
#   env: qa | staging | production        short name: search | reports | exportproducer ...
#
# "Wait for rolloutState: COMPLETED first" was written out three times across
# ama-deploy-release and ama-hotfix as a rule for the agent to remember, with a precise
# failure mode behind it: trigger the cache update while a service is still draining old
# tasks and the Step Functions task token is lost with the task, so the update sits until
# States.Timeout (3500 s). The precondition is a single describe-services field per service,
# so it is a loop, not a rule.
#
# Steady = exactly one deployment, rolloutState COMPLETED, runningCount == desiredCount.
# Exit 0 when all are steady, 1 on timeout (prints who is still rolling).
set -uo pipefail
export MSYS_NO_PATHCONV=1

ENV="${1:?usage: wait-ecs-rollout.sh <env> <service>... [--max-minutes N]}"; shift
MAX_MIN=15; SERVICES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --max-minutes) MAX_MIN="${2:?}"; shift 2 ;;
    *) SERVICES+=("$1"); shift ;;
  esac
done
[ "${#SERVICES[@]}" -gt 0 ] || { echo "no services given" >&2; exit 1; }
CLUSTER="${ENV}-v1-AMA"

# search is -isvc, everyone else -esvc; export-cohort's service is `cohorts`.
resolve() {
  case "$1" in
    *-esvc|*-isvc) printf '%s' "$1" ;;
    search) printf '%s-v1-search-api-isvc' "$ENV" ;;
    export-cohort|cohorts) printf '%s-v1-cohorts-api-esvc' "$ENV" ;;
    *) printf '%s-v1-%s-api-esvc' "$ENV" "$1" ;;
  esac
}

deadline=$(( $(date +%s) + MAX_MIN*60 ))
while :; do
  pending=()
  for s in "${SERVICES[@]}"; do
    svc="$(resolve "$s")"
    line="$(PYTHONUTF8=1 aws ecs describe-services --cluster "$CLUSTER" --services "$svc" 2>/dev/null \
      | jq -r '.services[0] // empty | "\(.deployments|length) \(.deployments[0].rolloutState // "?") \(.runningCount)/\(.desiredCount)"')"
    # A wrong short name never appears, so waiting is pointless -- fail fast with the real names
    # (`results` for resultsprocessor burned a full timeout, PROJ-15801 2026-10-14).
    if [ -z "$line" ]; then
      echo "NOT FOUND: $svc in $CLUSTER. Services matching '$s':" >&2
      aws ecs list-services --cluster "$CLUSTER" --output text --query 'serviceArns' 2>/dev/null \
        | tr '\t' '\n' | tr -d '\r' | sed 's#.*/##' | grep -i -- "${s%%-*}" | sed 's/^/  /' >&2
      exit 2
    fi
    set -- $line
    if [ "$1" = "1" ] && [ "$2" = "COMPLETED" ] && [ "${3%%/*}" = "${3##*/}" ]; then
      :
    else
      pending+=("$svc(deps=$1 $2 $3)")
    fi
  done
  if [ "${#pending[@]}" -eq 0 ]; then
    echo "ALL STEADY: ${SERVICES[*]} on $CLUSTER"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "TIMEOUT after ${MAX_MIN}m, still rolling:"; printf '  %s\n' "${pending[@]}"
    exit 1
  fi
  echo "[$(date -u +%H:%M:%SZ)] rolling: ${pending[*]}"
  sleep 30
done
