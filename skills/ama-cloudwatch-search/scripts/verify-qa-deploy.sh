#!/usr/bin/env bash
# Verify a QA deployment (ECS or Lambda) after a push to develop actually rolled out
# clean -- steady state reached, no crash-loop restarts, no error-level log spam.
# Usage: verify-qa-deploy.sh <repo> ecs [max-wait-minutes] [service-short-name-override] [expected-version]
#        verify-qa-deploy.sh <repo> lambda <function-name>
#
# ECS mode polls describe-services until steady state (or times out), then checks for
# tasks that stopped for a non-routine reason and scans CloudWatch logs for errors.
# Lambda mode does NOT check runtime health (Lambdas don't "run" until invoked) -- it
# only confirms the new code actually published (LastUpdateStatus=Successful).
#
# Optional 5th arg (ecs mode): expected image tag version (e.g. "2.0.0.101", the
# BITBUCKET_BUILD_NUMBER-derived Docker tag from build-and-publish.sh) -- if given,
# confirms every RUNNING TASK's container image carries that tag, not just that the
# service is steady (a steady service can still be steady on the OLD version if the
# deploy never actually rolled out).
#
# Without it this script proves the service is STEADY and nothing about WHICH build is
# serving -- it says so explicitly in the output rather than staying silent. The
# documented invocation used to omit it, which made the happy path assert no version at
# all; verify-deployment-e2e.sh derives it from the Bitbucket build number.
#
# The repo's local folder name does NOT reliably match the ECS service/log-group short
# name -- confirmed real mismatch: repo `export-cohort` -> ECS service
# `<env>-v1-cohorts-api-esvc` / log group `/aws/ecs/<env>-v1-ama-cohorts` (no substring
# relation at all). Pass the 4th arg to override the short name when the repo name
# itself doesn't resolve.
#
# `cohortdata` is the trap next to it: it has NO ECS service at all, it deploys as the
# Lambda `<env>-v1-cohort-data`. The `cohorts` service is export-cohort's -- verified
# on BOTH qa and staging 2026-09-15 by reading the running task definition's image
# (`product-service-export-cohort:2.0.0.<build>`). Earlier revisions of this header
# claimed cohortdata -> cohorts; that was wrong. Use `lambda` mode for cohortdata.
set -uo pipefail

# Confirmed real bug found testing this script: MSYS_NO_PATHCONV=1 set only on the `aws`
# command in a pipeline does NOT protect a downstream `jq --arg` in the same pipeline --
# git-bash still mangles a leading-`/` value passed to jq (a native exe) into a Windows
# path (e.g. "/aws/ecs/qa-v1-ama-search" -> "C:/Program Files/Git/aws/ecs/..."), silently
# breaking any equality check against it. Export for the whole script, not per-command.
export MSYS_NO_PATHCONV=1

REPO="${1:?usage: verify-qa-deploy.sh <repo> ecs|lambda [max-wait-minutes|function-name] [short-name-override]}"
MODE="${2:?usage: verify-qa-deploy.sh <repo> ecs|lambda [max-wait-minutes|function-name] [short-name-override]}"

# Environment prefix: `qa` (default) or `staging` -- release/* branches deploy to
# Staging, so ama-cut-release-branch Step 5 runs this as AMA_ENV=staging. Same
# `<env>-v1-*` naming in both, confirmed against the live staging cluster 2026-09-15.
ENV_PREFIX="${AMA_ENV:-qa}"
CLUSTER="${ENV_PREFIX}-v1-AMA"

if [ "${MODE}" = "lambda" ]; then
  FUNCTION="${3:?usage: verify-qa-deploy.sh <repo> lambda <function-name>}"
  echo "Checking Lambda deploy status: ${FUNCTION}"
  result="$(PYTHONUTF8=1 aws lambda get-function --function-name "${FUNCTION}" 2>&1)"
  if ! printf '%s' "${result}" | jq -e '.Configuration' >/dev/null 2>&1; then
    echo "Query failed:" >&2
    echo "${result}" >&2
    exit 1
  fi
  status="$(printf '%s' "${result}" | jq -r '.Configuration.LastUpdateStatus')"
  reason="$(printf '%s' "${result}" | jq -r '.Configuration.LastUpdateStatusReason // "none"')"
  last_modified="$(printf '%s' "${result}" | jq -r '.Configuration.LastModified')"
  echo "LastUpdateStatus: ${status}"
  echo "LastModified: ${last_modified}"
  [ "${status}" != "Successful" ] && echo "Reason: ${reason}"
  if [ "${status}" = "Successful" ]; then
    echo "RESULT: deployment succeeded, new code published. (Runtime health not checked -- Lambdas don't run until invoked.)"
    exit 0
  else
    echo "RESULT: deployment NOT clean (status=${status})."
    exit 1
  fi
fi

if [ "${MODE}" != "ecs" ]; then
  echo "Unknown mode '${MODE}', expected ecs or lambda" >&2
  exit 1
fi

MAX_WAIT_MIN="${3:-15}"
SHORT="${4:-${REPO}}"
EXPECTED_VERSION="${5:-}"

# Resolve the actual service name -- don't assume -api-esvc, confirmed real mismatch:
# `search`'s service is qa-v1-search-api-isvc (isvc, not esvc), no documented reason why.
# Frontends carry no `-api` infix: staging-v1-hs-admin-esvc (short name `hs-admin`).
SERVICE=""
for candidate in "${ENV_PREFIX}-v1-${SHORT}-api-esvc" "${ENV_PREFIX}-v1-${SHORT}-api-isvc" "${ENV_PREFIX}-v1-${SHORT}-esvc"; do
  check="$(PYTHONUTF8=1 aws ecs describe-services --cluster "${CLUSTER}" --services "${candidate}" 2>&1)"
  if printf '%s' "${check}" | jq -e '.services[0].serviceName' >/dev/null 2>&1; then
    SERVICE="${candidate}"
    break
  fi
done

if [ -z "${SERVICE}" ]; then
  echo "Couldn't resolve an ECS service for short name '${SHORT}' via -api-esvc/-api-isvc/-esvc." >&2
  echo "Services in ${CLUSTER} matching '${SHORT}':" >&2
  PYTHONUTF8=1 aws ecs list-services --cluster "${CLUSTER}" --max-items 200 2>/dev/null \
    | jq -r '.serviceArns[]' | sed 's|.*/||' | grep -i "${SHORT}" >&2
  echo "If nothing matches, the short name differs from the repo name entirely (e.g." >&2
  echo "export-cohort -> cohorts) -- pass the correct short name as the 4th argument." >&2
  exit 1
fi

# Two confirmed log-group name shapes -- most services have the "ama" infix, but
# exportproducer's task def points its awslogs-group at the no-infix form instead. Try
# both before giving up.
LOG_GROUP=""
for candidate in "/aws/ecs/${ENV_PREFIX}-v1-ama-${SHORT}" "/aws/ecs/${ENV_PREFIX}-v1-${SHORT}"; do
  if PYTHONUTF8=1 aws logs describe-log-groups --log-group-name-prefix "${candidate}" 2>/dev/null \
       | jq -e --arg lg "${candidate}" '.logGroups[] | select(.logGroupName == $lg)' >/dev/null 2>&1; then
    LOG_GROUP="${candidate}"
    break
  fi
done
if [ -z "${LOG_GROUP}" ]; then
  echo "Note: no log group found for '${SHORT}' (tried both name shapes) -- will skip the log scan step." >&2
fi

POLL_INTERVAL_SEC=30
MAX_POLLS=$(( MAX_WAIT_MIN * 60 / POLL_INTERVAL_SEC ))
DEPLOY_START="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo "Cluster: ${CLUSTER}  Service: ${SERVICE}"
echo "Polling for steady state (every ${POLL_INTERVAL_SEC}s, up to ${MAX_WAIT_MIN}m)..."

steady=false
for (( i=0; i<MAX_POLLS; i++ )); do
  svc="$(PYTHONUTF8=1 aws ecs describe-services --cluster "${CLUSTER}" --services "${SERVICE}" 2>&1)"
  if ! printf '%s' "${svc}" | jq -e '.services[0]' >/dev/null 2>&1; then
    echo "describe-services failed:" >&2
    echo "${svc}" >&2
    exit 1
  fi
  deployment_count="$(printf '%s' "${svc}" | jq '.services[0].deployments | length')"
  rollout_state="$(printf '%s' "${svc}" | jq -r '.services[0].deployments[0].rolloutState')"
  running="$(printf '%s' "${svc}" | jq -r '.services[0].runningCount')"
  desired="$(printf '%s' "${svc}" | jq -r '.services[0].desiredCount')"
  echo "  [$(date -u '+%H:%M:%S')] deployments=${deployment_count} rolloutState=${rollout_state} running=${running}/${desired}"
  if [ "${deployment_count}" -eq 1 ] && [ "${rollout_state}" = "COMPLETED" ] && [ "${running}" = "${desired}" ]; then
    steady=true
    break
  fi
  sleep "${POLL_INTERVAL_SEC}"
done

if [ "${steady}" != "true" ]; then
  echo "RESULT: did NOT reach steady state within ${MAX_WAIT_MIN}m -- deployment may still be rolling out, or stuck. Check manually:"
  echo "  PYTHONUTF8=1 aws ecs describe-services --cluster ${CLUSTER} --services ${SERVICE}"
  exit 1
fi
echo "Steady state reached."

# What is ACTUALLY serving, read off the RUNNING tasks -- not off the service's
# registered task definition. Those two differ for the whole rollout window: the service
# points at the new revision from the moment the deploy starts, while the old task keeps
# taking traffic until the new one is healthy. Reading the definition and calling it
# "running" cost a real incident (PROJ-15355, 2026-09-15): a correct fix was probed
# 45s after Octopus reported Success, measured against the pre-deploy container, declared
# broken and reverted. The steady-state poll above makes the definition safe to read by
# the time we get here, but this function is also copied by hand into ad-hoc checks that
# have no such poll -- so read the authoritative thing, and model the right call.
task_def_arn="$(printf '%s' "${svc}" | jq -r '.services[0].taskDefinition')"
requested_image="$(PYTHONUTF8=1 aws ecs describe-task-definition --task-definition "${task_def_arn}" \
  | jq -r '.taskDefinition.containerDefinitions[0].image')"

# `tr -d '\r'` is load-bearing on git-bash: jq's output carries CRLF here, and a task ARN
# with a trailing \r fails describe-tasks with a misleading "Unexpected number of
# separators" / "taskId length should be one of [32,36]" rather than anything mentioning
# whitespace. Cost 20 minutes the first time.
running_task_arns=()
while IFS= read -r arn; do
  arn="$(printf '%s' "$arn" | tr -d '\r')"
  [ -n "$arn" ] && running_task_arns+=("$arn")
done < <(PYTHONUTF8=1 aws ecs list-tasks --cluster "${CLUSTER}" \
  --service-name "${SERVICE}" --desired-status RUNNING 2>/dev/null \
  | jq -r '.taskArns[]?')

serving_images=""
if [ "${#running_task_arns[@]}" -gt 0 ]; then
  # Every running task, not just the first -- a part-rolled service serves both versions.
  serving_images="$(PYTHONUTF8=1 aws ecs describe-tasks --cluster "${CLUSTER}" \
    --tasks "${running_task_arns[@]}" 2>/dev/null \
    | jq -r '.tasks[].containers[0].image' | tr -d '\r' | sort -u)"
fi

if [ -n "${serving_images}" ]; then
  echo "Serving image(s) on RUNNING tasks: $(printf '%s' "${serving_images}" | tr '\n' ' ')"
else
  echo "Serving image(s): could not read RUNNING tasks -- falling back to the service's task definition." >&2
  serving_images="${requested_image}"
fi

if [ "${requested_image}" != "$(printf '%s' "${serving_images}" | head -1)" ] \
   || [ "$(printf '%s' "${serving_images}" | wc -l)" -gt 1 ]; then
  echo "Note: service task definition asks for ${requested_image}; running tasks are not all on it yet."
fi

version_mismatch=false
if [ -n "${EXPECTED_VERSION}" ]; then
  # Mismatch if ANY running task is on something other than the expected tag.
  while IFS= read -r img; do
    [ -n "${img}" ] || continue
    if [ "${img##*:}" != "${EXPECTED_VERSION}" ]; then
      version_mismatch=true
    fi
  done <<< "${serving_images}"

  if [ "${version_mismatch}" = false ]; then
    echo "Version check: OK (every running task is on ${EXPECTED_VERSION})"
  else
    echo "Version check: MISMATCH -- expected ${EXPECTED_VERSION}, running $(printf '%s' "${serving_images}" | sed 's/.*://' | tr '\n' ' '). Service is steady, but not (all) on the expected release."
  fi
else
  echo "Version check: SKIPPED -- no expected version passed, so this run proves the service is steady, NOT that your build is the one serving. Pass it as arg 5, or use verify-deployment-e2e.sh, which derives it from the Bitbucket build number."
fi

echo "Checking for tasks that stopped since ${DEPLOY_START}..."
stopped="$(PYTHONUTF8=1 aws ecs list-tasks --cluster "${CLUSTER}" --service-name "${SERVICE}" --desired-status STOPPED --max-items 20 2>&1)"
task_arns="$(printf '%s' "${stopped}" | jq -r '.taskArns[]?' 2>/dev/null)"
crash_found=false
if [ -n "${task_arns}" ]; then
  details="$(PYTHONUTF8=1 aws ecs describe-tasks --cluster "${CLUSTER}" --tasks ${task_arns} 2>&1)"
  # Routine deploy scale-down reads stopCode=ServiceSchedulerInitiated -- not a crash.
  # Anything else (exitCode != 0, or stopCode like TaskFailedToStart/EssentialContainerExited
  # with a non-zero exit) stopped since deploy start is worth flagging.
  crash_lines="$(printf '%s' "${details}" | jq -r --arg since "${DEPLOY_START}" '
    .tasks[]
    | select(.stoppedAt != null and .stoppedAt >= $since and .stopCode != "ServiceSchedulerInitiated")
    | "\(.stoppedAt)\tstopCode=\(.stopCode)\tstoppedReason=\(.stoppedReason)\t" +
      (.containers[] | "exitCode=\(.exitCode // "null") reason=\(.reason // "none")")
  ' 2>/dev/null)"
  if [ -n "${crash_lines}" ]; then
    crash_found=true
    echo "Non-routine task stops found since deploy:"
    echo "${crash_lines}"
  fi
fi
[ "${crash_found}" = "false" ] && echo "No non-routine task stops/restarts since deploy start."

if [ -n "${LOG_GROUP}" ]; then
  echo "Scanning CloudWatch logs (${LOG_GROUP}) for errors since ${DEPLOY_START}..."
  bash "$(dirname "$0")/cloudwatch-search-logs.sh" "${LOG_GROUP}" "${DEPLOY_START}" "now" "?ERROR ?Exception ?Fatal ?FATAL" 50
fi

if [ "${crash_found}" = "true" ]; then
  echo "RESULT: deployment reached steady state, but non-routine task stops were found -- investigate above."
  exit 1
elif [ "${version_mismatch}" = "true" ]; then
  echo "RESULT: service is steady with no crashes, but NOT running the expected version -- deploy likely hasn't rolled out yet or stalled."
  exit 1
else
  echo "RESULT: deployment steady, no non-routine restarts. Review the log scan above for genuine errors vs. normal noise before declaring it fully clean."
fi
