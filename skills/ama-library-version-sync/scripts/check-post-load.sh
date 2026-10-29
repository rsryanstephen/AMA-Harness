#!/usr/bin/env bash
# P21 part A (api-testing/BUG-CLASS-AUDIT.md): read-only Production post-load monitor, one arm
# of the nightly fleet-health sweep (fleet-health-check.sh -> run_check "post-load"). Catches a
# monthly load whose cache update silently never ran, failed or stuck (PROJ-15039, -14920).
# AWS metadata only -- no Redshift, no DynamoDB scan (production-v1-cacheupdate-state is ~50k rows).
#
# Lines follow fleet-health's OUTPUT CONTRACT: OK/RISK/FAIL, no timestamps, and each RISK line
# carries its incident's identity (month / execution / CorrelationId) -- .fleet-health-pinged is
# never pruned, so an identical line pings once EVER.
#
#  1. main-after-load: newest monthly loan-level file (GNM_GLLM / FNM_NLLM / FHL_LLM) in
#     s3://yourproduct-clientcorp-data-transfer/raw/embs/<prod>/<yyyy>/<m>/ -> ETL deadline = next day
#     09:30 ET (fixed 14:30 UTC: no tz database in Git Bash; an hour late in summer). Need a
#     SUCCEEDED CacheType=Main execution started after it, judged once deadline + GRACE_H passed.
#     Main is NOT daily -- Oct 2026: GNM deadline Fri 10-09, first Main Sun 10-11 (+40h). Month
#     folders aren't zero-padded: `10/` sorts before `7/`, so pick the max numerically.
#  2. failed: FAILED/TIMED_OUT/ABORTED executions started in the last 25h.
#  3. stuck: cache API GET /latest (auth NONE) -> ProcessRunning=1 for over STUCK_H refuses every
#     later trigger (ama-graylog-search CACHE-UPDATE-DEBUGGING.md, PROJ-15800).
#  4. dlq: production-*-dead-letter queue holding a message older than 1h (CloudWatch
#     ApproximateAgeOfOldestMessage; unknown age = RISK). Month in the line -> re-pings monthly.
#
# Test overrides: POST_LOAD_NOW (epoch), POST_LOAD_GRACE_H (72), POST_LOAD_STUCK_H (3),
# POST_LOAD_LATEST_JSON (fixture for /latest), POST_LOAD_DLQ_MIN (1) + POST_LOAD_DLQ_AGE (3600)
# -- both 0 exercises the DLQ RISK path on empty queues.
set -uo pipefail
export MSYS_NO_PATHCONV=1 AWS_REGION=us-east-1
. "$HOME/.claude/hooks/lib-harness-repos.sh"

NOW="${POST_LOAD_NOW:-$(date +%s)}"
GRACE_H="${POST_LOAD_GRACE_H:-72}"
STUCK_H="${POST_LOAD_STUCK_H:-3}"
DLQ_MIN="${POST_LOAD_DLQ_MIN:-1}"
BUCKET=yourproduct-clientcorp-data-transfer
ACCT="$(hr_config '.aws.accountNumber' '')"
SM="arn:aws:states:us-east-1:${ACCT}:stateMachine:production-v1-cacheupdate-statemachine"
DLQ_AGE="${POST_LOAD_DLQ_AGE:-3600}"
iso() { date -u -d "@$1" +%FT%TZ; }

# exec_rows <status> <max> -> "<epoch>\t<startDate[0:16]>\t<name>\t<arn>", newest first; 1 on any
# failure. The CLI prints startDate with a LOCAL offset (…+02:00) and this host's jq is 1.5rc1
# (no fromdateiso8601) -- one `date -f -` parses them all. A parse miss must fail, not filter
# rows away: an earlier jq-side version printed "OK" with every execution silently dropped.
exec_rows() {
  local json rows
  json="$(aws stepfunctions list-executions --state-machine-arn "${SM}" --status-filter "$1" \
            --max-items "$2" --output json 2>/dev/null)" || return 1
  printf '%s' "${json}" | jq -e '.executions' >/dev/null 2>&1 || return 1
  rows="$(paste <(printf '%s' "${json}" | jq -r '.executions[].startDate' | date -f - +%s) \
                <(printf '%s' "${json}" | jq -r '.executions[] | "\(.startDate[0:16])\t\(.name)\t\(.executionArn)"'))"
  [ -z "${rows}" ] || ! printf '%s\n' "${rows}" | grep -qvE $'^[0-9]+\t' || return 1
  printf '%s\n' "${rows}"
}

# --- 1. main-after-load ---------------------------------------------------------------------
newest_arrival() {   # prints "<epoch> <yyyy-mm>" of the newest monthly loan-level file
  local p y m best=0 bestmon="" lm e year
  year="$(date -u -d "@${NOW}" +%Y)"
  for p in GNM/GLLM FNM/NLLM FHL/LLM; do
    for y in "${year}" "$((year - 1))"; do
      m="$(aws s3api list-objects-v2 --bucket "${BUCKET}" --prefix "raw/embs/${p}/${y}/" --delimiter / \
             --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null | tr '\t' '\n' \
             | sed -nE 's|.*/([0-9]+)/$|\1|p' | sort -n | tail -1)"
      [ -n "${m}" ] || continue
      lm="$(aws s3api list-objects-v2 --bucket "${BUCKET}" --prefix "raw/embs/${p}/${y}/${m}/" \
              --query 'max(Contents[].LastModified)' --output text 2>/dev/null)"
      e="$(date -d "${lm}" +%s 2>/dev/null)" || continue
      [ "${e}" -le "${NOW}" ] && [ "${e}" -gt "${best}" ] && { best="${e}"; bestmon="$(printf '%s-%02d' "${y}" "${m}")"; }
      break
    done
  done
  [ "${best}" -gt 0 ] && echo "${best} ${bestmon}"
}

check_main_after_load() {
  local arr a mon deadline execs arn sd n=0 ct
  arr="$(newest_arrival)" || true
  if [ -z "${arr}" ]; then echo "FAIL post-load main-after-load checker-unavailable"; return; fi
  read -r a mon <<< "${arr}"
  # ET date of arrival (UTC-5 is close enough; files land ~22:30 UTC), deadline next day 14:30 UTC.
  deadline="$(date -u -d "$(date -u -d "@$((a - 18000))" +%F) +1 day 14:30" +%s)"
  if [ "${NOW}" -lt "$((deadline + GRACE_H * 3600))" ]; then
    echo "OK post-load main-after-load ${mon} within-grace"; return
  fi
  execs="$(exec_rows SUCCEEDED 200)" || { echo "FAIL post-load main-after-load checker-unavailable"; return; }
  execs="$(printf '%s\n' "${execs}" | awk -F'\t' -v d="${deadline}" -v n="${NOW}" '$1 >= d && $1 <= n { print $4 }')"
  # Newest-first; stop at the first Main. Search updates run ~5x/day, so cap the describes.
  while read -r arn; do
    [ -n "${arn}" ] || continue
    n=$((n + 1)); [ "${n}" -gt 80 ] && { echo "FAIL post-load main-after-load lookup-capped ${mon}"; return; }
    ct="$(aws stepfunctions describe-execution --execution-arn "${arn}" --query input --output text 2>/dev/null | jq -r '.CacheType // empty' 2>/dev/null)"
    [ "${ct}" = "Main" ] && { echo "OK post-load main-after-load ${mon}"; return; }
  done <<< "${execs}"
  echo "RISK post-load no-main-cache-update-after-load ${mon} -- monthly file landed, no successful Main cache update since the ETL deadline; see ama-graylog-search CACHE-UPDATE-DEBUGGING.md"
}

# --- 2. failed executions in the last 25h ---------------------------------------------------
check_failed() {
  local st rows since
  since="$((NOW - 25 * 3600))"
  for st in FAILED TIMED_OUT ABORTED; do
    rows="$(exec_rows "${st}" 20)" || { echo "FAIL post-load failed checker-unavailable"; return; }
    printf '%s\n' "${rows}" | awk -F'\t' -v a="${since}" -v b="${NOW}" -v st="${st}" \
      '$1 >= a && $1 <= b { printf "RISK post-load cache-update-%s %s %s\n", st, $2, $3 }'
  done
  echo "OK post-load failed checked"
}

# --- 3. stuck ProcessRunning -----------------------------------------------------------------
check_stuck() {
  local json api pr ca cid
  json="${POST_LOAD_LATEST_JSON:-}"
  if [ -z "${json}" ]; then
    api="$(aws apigateway get-rest-apis --query "items[?name=='production-v1-cacheupdate-api-gateway-rest-api'].id | [0]" --output text 2>/dev/null)"
    [ -n "${api}" ] && [ "${api}" != "None" ] && json="$(curl -sS --max-time 20 "https://${api}.execute-api.us-east-1.amazonaws.com/cache/latest" 2>/dev/null)"
  fi
  pr="$(printf '%s' "${json}" | jq -r '.ProcessRunning // empty' 2>/dev/null)"
  if [ -z "${pr}" ]; then echo "FAIL post-load cache-state checker-unavailable"; return; fi
  ca="$(printf '%s' "${json}" | jq -r '.CreatedAt // empty')"
  cid="$(printf '%s' "${json}" | jq -r '.CorrelationId // empty')"
  if [ "${pr}" = "1" ] && [ "$(date -d "${ca}" +%s 2>/dev/null || echo 0)" -lt "$((NOW - STUCK_H * 3600))" ]; then
    echo "RISK post-load cache-state-stuck ProcessRunning=1 ${cid} -- every later cache update is refused; fix in ama-graylog-search CACHE-UPDATE-DEBUGGING.md"
  else
    echo "OK post-load cache-state"
  fi
}

# --- 4. dead-letter queues -------------------------------------------------------------------
check_dlq() {
  local urls u q n age mon
  mon="$(date -u -d "@${NOW}" +%Y-%m)"
  urls="$(aws sqs list-queues --queue-name-prefix production --output json 2>/dev/null | jq -r '.QueueUrls[]?' | grep -- '-dead-letter$')"
  if [ -z "${urls}" ]; then echo "FAIL post-load dlq checker-unavailable"; return; fi
  while read -r u; do
    q="${u##*/}"
    n="$(aws sqs get-queue-attributes --queue-url "${u}" --attribute-names ApproximateNumberOfMessages \
           --query 'Attributes.ApproximateNumberOfMessages' --output text 2>/dev/null)"
    case "${n}" in ''|*[!0-9]*) echo "FAIL post-load dlq ${q} unreadable"; continue ;; esac
    [ "${n}" -ge "${DLQ_MIN}" ] || continue
    age="$(aws cloudwatch get-metric-statistics --namespace AWS/SQS --metric-name ApproximateAgeOfOldestMessage \
             --dimensions Name=QueueName,Value="${q}" --start-time "$(iso $((NOW - 1800)))" --end-time "$(iso "${NOW}")" \
             --period 300 --statistics Maximum --query 'max(Datapoints[].Maximum)' --output text 2>/dev/null)"
    age="${age%%.*}"
    case "${age}" in ''|None|*[!0-9]*) age=999999 ;; esac
    [ "${age}" -ge "${DLQ_AGE}" ] && echo "RISK post-load dlq-nonempty ${q} ${mon}"
  done <<< "${urls}"
  echo "OK post-load dlq checked"
}

check_main_after_load
check_failed
check_stuck
check_dlq
