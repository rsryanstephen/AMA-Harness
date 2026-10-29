#!/usr/bin/env bash
# PROJ-15653: PC half of the QA/Staging sleep schedule. Run by task
# AMA-Harness-Env-Wake (register-env-wake-task.ps1): daily 07:00 SAST repeating every 30
# min until 22:00, plus at logon. Scales QA+Staging up ONCE per weekday, inside the awake
# window only -- a night/weekend logon does nothing, and a manual st0 mid-day is not undone
# by the next repeat. The 22:00 shutdown is AWS-side (deploy-shutdown-schedule.sh).
# ENV_SLEEP_DRY_RUN=1 prints the decision, touches nothing. ENV_SLEEP_NOW: see lib.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib-env-sleep.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
LOG="$(hstate logs env-sleep.log)"
STAMP="$(hstate notices .env-wake-lastday)"
DIGEST="$(hstate notices .env-sleep-digest)"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

env_sleep_now
if [ "$ES_WINDOW" != awake ]; then
  [ -n "${ENV_SLEEP_DRY_RUN:-}" ] && echo "skip: asleep ($ES_DAY h$ES_HOUR d$ES_DOW)"
  exit 0
fi
if [ "$(cat "$STAMP" 2>/dev/null)" = "$ES_DAY" ]; then
  [ -n "${ENV_SLEEP_DRY_RUN:-}" ] && echo "skip: already woke $ES_DAY"
  exit 0
fi
if [ -n "${ENV_SLEEP_DRY_RUN:-}" ]; then echo "wake: qa staging ($ES_DAY h$ES_HOUR)"; exit 0; fi

. "$HOME/.claude/hooks/lib-unattended-ready.sh"
wait_until_online log

rc=0
for env in qa staging; do
  ENV_SLEEP_SCHEDULED=1 bash "$DIR/scale-env.sh" "$env" 1 >> "$LOG" 2>&1 || rc=1
done
if [ "$rc" -eq 0 ]; then
  echo "$ES_DAY" > "$STAMP"
  : > "$(hstate notices .task-ok-AMA-Harness-Env-Wake)"
  : > "$DIGEST"
  log "woke qa+staging"
else
  # No stamp -> the next 30-min repeat retries. Digest relayed once by env-sleep-check.sh.
  echo "QA/Staging morning wake FAILED $ES_DAY $(printf '%02d' "$ES_HOUR"):xx SAST -- see $LOG (will retry every 30 min)." > "$DIGEST"
  log "wake FAILED rc=$rc"
fi
exit $rc
