#!/usr/bin/env bash
# ensure-awake.sh <qa|staging> -- make sure the env is really UP before anything tests it.
#   exit 0 = every service that should run has running == desired >= 1 (and, if this call woke
#            it, a settle period has passed); 1 = still not up after the wait; 2 = bad usage.
#
# Why (2026-10-23, PROJ-15834 hotfix): the export-content tests were triggered at 07:41
# SAST while Staging was still scaled to 0 -- the wake task only ran at 07:45, on PC logon. All
# 8 tests failed, and the same run's "AWS sweep: clean" was a vacuous pass: nothing running,
# nothing unhealthy. A test or error sweep against a sleeping env measures nothing. Called by
# ama-bitbucket-api/scripts/run-pipeline.sh (every api-testing run on qa/staging) and by
# ama-deploy-release/scripts/release-preflight.sh, so no agent has to remember it.
#
# Waking is the standing user rule (ama-env-sleep "Off-hours rule"): wake it yourself, don't
# ask -- via scale-env.sh, which also records an off-hours wake for the sleep reminder.
# Services in always-zero.txt are expected at 0 and ignored. Tunables (tests/slow days):
#   ENSURE_AWAKE_MAX_SECS (default 600) wait ceiling   ENSURE_AWAKE_SETTLE_SECS (default 90)
#   ENSURE_AWAKE_POLL_SECS (default 20)                test seams: ENSURE_AWAKE_COUNTS=<cmd printing env-counts lines>, ENSURE_AWAKE_SCALE=<cmd>
# (the script must never be tested against the real env: scale-env.sh acts on live ECS)
set -uo pipefail
ENV="${1:-}"; case "$ENV" in qa|staging) ;; *) echo "usage: ensure-awake.sh <qa|staging>" >&2; exit 2 ;; esac
D="$(dirname "$0")"; MAX="${ENSURE_AWAKE_MAX_SECS:-600}"; POLL="${ENSURE_AWAKE_POLL_SECS:-20}"; SETTLE="${ENSURE_AWAKE_SETTLE_SECS:-90}"
COUNTS="${ENSURE_AWAKE_COUNTS:-bash $D/env-counts.sh $ENV}"

# Prints the services that are not up: "<name> desired=<d> running=<r>" per line. Empty = all up.
down() {
  local line name d r
  while IFS= read -r line; do
    line="${line%$'\r'}"; [ -n "$line" ] || continue
    name="${line%% *}"
    while IFS= read -r z || [ -n "$z" ]; do
      z="${z%$'\r'}"; case "$z" in ''|'#'*) continue ;; esac
      [[ "$name" == *"$z" ]] && continue 2
    done < "$D/always-zero.txt"
    d="${line#*desired=}"; d="${d%% *}"; r="${line#*running=}"; r="${r%% *}"
    { [ "$d" -ge 1 ] && [ "$r" -eq "$d" ]; } 2>/dev/null || printf '%s\n' "$line"
  done < <($COUNTS 2>/dev/null)
}

woke=0
# Captured, never `down | grep -q`: under pipefail grep -q's early exit SIGPIPEs the producer and
# the test reads false -- a sleeping env was classed "still starting" and never woken.
left="$(down)"
if [ -z "$left" ]; then echo "ensure-awake: $ENV is up"; exit 0; fi
if [[ "$left" == *desired=0* ]]; then
  echo "ensure-awake: $ENV is asleep (services at desired=0) -- waking it (scale-env.sh $ENV 1)"
  ${ENSURE_AWAKE_SCALE:-bash $D/scale-env.sh} "$ENV" 1 >/dev/null 2>&1 || echo "ensure-awake: scale-env.sh reported a failure; waiting anyway" >&2
  woke=1
else
  echo "ensure-awake: $ENV is still starting -- waiting"
fi
t0=$(date +%s)
while :; do
  left="$(down)"
  [ -z "$left" ] && break
  if [ $(( $(date +%s) - t0 )) -ge "$MAX" ]; then
    echo "ensure-awake: $ENV NOT up after ${MAX}s -- still down:" >&2; printf '%s\n' "$left" | sed 's/^/  /' >&2
    exit 1
  fi
  sleep "$POLL"
done
# running == desired is "task started", not "serving": give the app a moment after a wake.
[ "$woke" = 1 ] && { echo "ensure-awake: all services running; settling ${SETTLE}s"; sleep "$SETTLE"; }
echo "ensure-awake: $ENV is up"
exit 0
