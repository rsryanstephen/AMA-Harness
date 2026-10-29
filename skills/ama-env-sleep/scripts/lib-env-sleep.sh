#!/usr/bin/env bash
# PROJ-15653: shared schedule predicate for the QA/Staging sleep window. Sourced by
# morning-wake.sh, scale-env.sh and hooks/env-sleep-check.sh (on-prompt hot path, so
# fork-free: printf %()T builtin, POSIX TZ string -- SAST is UTC+2, no DST, and git-bash
# ignores named zones like Africa/Johannesburg but honours SAST-2).
#
# Awake window: Mon-Fri 07:00-21:59 SAST. Everything else = asleep (AWS shutdown 22:00).
# ENV_SLEEP_NOW="YYYY-MM-DD HH D" (D = ISO weekday 1-7) overrides the clock for tests.

# Sets ES_DAY ES_HOUR ES_DOW ES_WINDOW (awake|asleep).
env_sleep_now() {
  local now="${ENV_SLEEP_NOW:-}"
  [ -n "$now" ] || TZ=SAST-2 printf -v now '%(%F %H %u)T' -1
  read -r ES_DAY ES_HOUR ES_DOW <<<"$now"
  ES_HOUR=$((10#$ES_HOUR))
  if [ "$ES_DOW" -le 5 ] && [ "$ES_HOUR" -ge 7 ] && [ "$ES_HOUR" -lt 22 ]; then
    ES_WINDOW=awake
  else
    ES_WINDOW=asleep
  fi
}
