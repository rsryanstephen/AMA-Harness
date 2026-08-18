#!/usr/bin/env bash
# Fallback for "CacheClear Lambda - Cache Update failed" when Graylog shows no error
# explaining why -- queries the AWS Step Functions execution directly for the real
# cause. Confirmed feasible: this machine's default AWS CLI profile already has
# states:ListExecutions + states:GetExecutionHistory on these state machines.
#
# State machine naming convention: <environment>-v1-cacheupdate-statemachine
# (confirmed: production-v1-cacheupdate-statemachine, qa-v1-cacheupdate-statemachine,
# staging-v1-cacheupdate-statemachine all exist).
#
# Usage: query-cacheupdate-stepfunction.sh <environment> <approx-failure-time-utc>
#   <approx-failure-time-utc> in a form `date -d` accepts, e.g. "2026-07-21T08:00:00Z"
set -uo pipefail

ENVIRONMENT="${1:?usage: query-cacheupdate-stepfunction.sh <environment> <approx-failure-time-utc>}"
APPROX_TIME="${2:?usage: query-cacheupdate-stepfunction.sh <environment> <approx-failure-time-utc>}"

. "$HOME/.claude/hooks/lib-harness-repos.sh"
# Both decide WHICH AWS ACCOUNT/REGION gets queried -- no safe default.
AWS_ACCOUNT="$(hr_config_required '.aws.accountNumber')" || exit 1
AWS_REGION="$(hr_config_required '.aws.region')" || exit 1
ARN="arn:aws:states:${AWS_REGION}:${AWS_ACCOUNT}:stateMachine:${ENVIRONMENT}-v1-cacheupdate-statemachine"
target_epoch="$(date -u -d "${APPROX_TIME}" +%s 2>/dev/null)"
if [ -z "${target_epoch}" ]; then
  echo "Couldn't parse timestamp: ${APPROX_TIME}" >&2
  exit 1
fi

executions="$(aws stepfunctions list-executions --state-machine-arn "${ARN}" --status-filter FAILED --max-items 20 2>&1)"
if ! printf '%s' "${executions}" | grep -q '"executions"'; then
  echo "Couldn't list executions for ${ARN}:" >&2
  echo "${executions}" >&2
  exit 1
fi

# Closest FAILED execution to the given time, within a 10-minute window either side.
best_arn=""
best_diff=999999
while IFS=$'\t' read -r exec_arn start_date; do
  [ -n "${exec_arn}" ] || continue
  start_epoch="$(date -u -d "${start_date}" +%s 2>/dev/null)" || continue
  diff=$(( start_epoch > target_epoch ? start_epoch - target_epoch : target_epoch - start_epoch ))
  if [ "${diff}" -le 600 ] && [ "${diff}" -lt "${best_diff}" ]; then
    best_arn="${exec_arn}"
    best_diff="${diff}"
  fi
done < <(printf '%s' "${executions}" | jq -r '.executions[] | "\(.executionArn)\t\(.startDate)"')

if [ -z "${best_arn}" ]; then
  echo "No FAILED execution within 10 minutes of ${APPROX_TIME} on ${ARN}" >&2
  exit 1
fi

encoded_arn="$(printf '%s' "${best_arn}" | sed 's/:/%3A/g')"
console_link="https://${AWS_REGION}.console.aws.amazon.com/states/home?region=${AWS_REGION}#/executions/details/${encoded_arn}"

echo "Execution: ${best_arn}"
echo "Console: ${console_link}"
echo "---"
aws stepfunctions get-execution-history --execution-arn "${best_arn}" --max-items 500 2>&1 \
  | jq -r '
    .events[]
    | select(.executionFailedEventDetails or .taskFailedEventDetails or .lambdaFunctionFailedEventDetails)
    | . as $ev
    | ($ev.executionFailedEventDetails // $ev.taskFailedEventDetails // $ev.lambdaFunctionFailedEventDetails) as $d
    | "[\($ev.type)] error=\($d.error)\n  cause=\($d.cause)"
  '
