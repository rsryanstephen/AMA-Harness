#!/usr/bin/env bash
# PROJ-15653: scale every ECS service in <env>-v1-AMA to <count>; services matching a
# suffix in always-zero.txt always go to 0. Port of ~/Repos/Scripts/AWS/Cost_Savings/
# scale_all_services.sh (the qa0/qa1/st0/st1 aliases), but keeps going past a failed
# service and exits non-zero at the end -- unattended runs must not leave half an env up.
#   bash scale-env.sh qa 1 | bash scale-env.sh staging 0
set -uo pipefail
ENV=${1:?usage: scale-env.sh <qa|staging> <count>}
COUNT=${2:?usage: scale-env.sh <qa|staging> <count>}
case "$ENV" in qa|staging) ;; *) echo "refusing env '$ENV' (qa|staging only)" >&2; exit 2 ;; esac
CLUSTER="$ENV-v1-AMA"
REGION=us-east-1
ZERO_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/always-zero.txt"

arns=$(aws ecs list-services --cluster "$CLUSTER" --region "$REGION" --query 'serviceArns[]' --output text | tr -d '\r') || exit 1
[ -n "$arns" ] || { echo "no services in $CLUSTER"; exit 0; }

FIRST_FILE="$(dirname "$ZERO_FILE")/wake-first.txt"

# 0 = $1 ends with a suffix listed in file $2
listed() {
  local suffix
  while read -r suffix || [ -n "$suffix" ]; do
    suffix=${suffix%$'\r'}
    case "$suffix" in ''|'#'*) continue ;; esac
    [[ "$1" == *"$suffix" ]] && return 0
  done < "$2"
  return 1
}

rc=0
scale() {
  local svc=$1 target=$COUNT
  listed "$svc" "$ZERO_FILE" && target=0
  if aws ecs update-service --cluster "$CLUSTER" --service "$svc" --desired-count "$target" \
       --region "$REGION" --no-cli-pager >/dev/null; then
    echo "$svc -> $target"
  else
    echo "FAILED $svc -> $target" >&2; rc=1
  fi
}

# Waking: dependencies (wake-first.txt) first, wait until stable, then the rest -- all at once,
# services that need RabbitMQ/fieldtablemapper at start-up crashed (see that file).
first=() rest=(); wake_t0=$(date +%s)
export MSYS_NO_PATHCONV=1   # the /aws/ecs/... log-group name below is mangled into a Windows path otherwise
for arn in $arns; do
  svc=${arn##*/}
  if [ "$COUNT" -gt 0 ] && [ -f "$FIRST_FILE" ] && listed "$svc" "$FIRST_FILE"; then first+=("$svc"); else rest+=("$svc"); fi
done
if [ ${#first[@]} -gt 0 ]; then
  # broker already running before this wake (partial env re-woken): no fresh ready line will come
  rabbit_was_up=0
  for svc in "${first[@]}"; do case "$svc" in *rabbitmq*)
    [ "$(aws ecs describe-services --cluster "$CLUSTER" --services "$svc" --region "$REGION" \
        --query 'services[0].runningCount' --output text 2>/dev/null | tr -d '\r')" -ge 1 ] 2>/dev/null && rabbit_was_up=1 ;;
  esac; done
  for svc in "${first[@]}"; do scale "$svc"; done
  # never leave the env half up: a slow/failed wait only warns, the rest still scales. Capped at
  # 6 min (aws's own is 10): morning-wake.sh does qa then staging inside a 20-min task limit.
  timeout 360 aws ecs wait services-stable --cluster "$CLUSTER" --services "${first[@]}" --region "$REGION" \
    && echo "stable: ${first[*]}" || echo "WARN: ${first[*]} not stable within the wait -- scaling the rest anyway" >&2
  # ECS "stable" = the broker CONTAINER runs, not that RabbitMQ accepts connections: 2026-10-23 QA's
  # broker logged "Server startup complete" at 05:48:11Z while resultsprocessor, started on "stable",
  # crashed from 05:43:52Z (Staging: broker 05:45:07Z, no crash). Wait for the broker's own ready
  # line, newer than this wake. Fails open: no log line in 5 min / query error -> warn, scale on.
  [ "$rabbit_was_up" = 0 ] && case " ${first[*]} " in *rabbitmq*)
    since=$(( wake_t0 * 1000 )); n=0
    until [ -n "$(aws logs filter-log-events --log-group-name "/aws/ecs/$ENV-v1-ama-rabbitmq" --start-time "$since" \
        --filter-pattern '"Server startup complete"' --max-items 1 --query 'events[0].timestamp' --output text 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$')" ]; do
      n=$((n + 1)); [ "$n" -gt 30 ] && { echo "WARN: no 'Server startup complete' from the $ENV broker in 5 min -- scaling the rest anyway" >&2; break; }
      sleep 10
    done
    [ "$n" -le 30 ] && echo "broker ready (Server startup complete)" ;;
  esac
fi
for svc in "${rest[@]}"; do scale "$svc"; done

# Off-hours wake ledger: hooks/env-sleep-check.sh keeps reminding the session to ASK the
# user before scaling back down. Scheduled wakes never record; scaling to 0 clears.
. "$(dirname "${BASH_SOURCE[0]}")/lib-env-sleep.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
woken="$(hstate notices .env-sleep-woken)"
touch "$woken"
grep -v "^$ENV " "$woken" > "$woken.tmp"; mv "$woken.tmp" "$woken"
env_sleep_now
if [ "$COUNT" -gt 0 ] && [ "$ES_WINDOW" = asleep ] && [ -z "${ENV_SLEEP_SCHEDULED:-}" ]; then
  # Line = "<env> <day>": the 22:00 Lambda on <day> sleeps it again, so the reminder
  # expires then (env-sleep-check.sh). Woken at/after 22:00 -> tomorrow's 22:00.
  exp=$ES_DAY
  [ "$ES_HOUR" -ge 22 ] && exp=$(TZ=SAST-2 date -d "$ES_DAY +1 day" +%F)
  echo "$ENV $exp" >> "$woken"
  echo "NOTE: $ENV woken off-hours -- when the task needing it is done, ASK the user before 'scale-env.sh $ENV 0'."
fi
exit $rc
