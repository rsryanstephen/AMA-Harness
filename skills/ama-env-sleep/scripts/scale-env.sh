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

rc=0
for arn in $arns; do
  svc=${arn##*/}
  target=$COUNT
  while read -r suffix || [ -n "$suffix" ]; do
    suffix=${suffix%$'\r'}
    case "$suffix" in ''|'#'*) continue ;; esac
    [[ "$svc" == *"$suffix" ]] && { target=0; break; }
  done < "$ZERO_FILE"
  if aws ecs update-service --cluster "$CLUSTER" --service "$svc" --desired-count "$target" \
       --region "$REGION" --no-cli-pager >/dev/null; then
    echo "$svc -> $target"
  else
    echo "FAILED $svc -> $target" >&2; rc=1
  fi
done

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
