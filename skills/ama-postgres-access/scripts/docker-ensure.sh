#!/usr/bin/env bash
# docker-ensure.sh -- make the Docker engine answer, starting or restarting Docker Desktop itself.
#
# User instruction 2026-09-26: Claude starts/restarts Docker Desktop on its own -- an explicit,
# Docker-only exception to memory/machine-changes-recommend-not-apply. Until then pg-connect.sh
# only printed "run docker desktop restart" and the session that hit it stopped short (a
# precedent check for a client notice was skipped because of it).
#
# Three engine states, three actions:
#   answers      -> exit 0, nothing done.
#   not running  -> `docker desktop start`. The named pipe //./pipe/dockerDesktopLinuxEngine is
#                   absent and `docker desktop status` says "Is Docker Desktop running?". Seen
#                   2026-09-26: Docker's AutoStart=false, host rebooted 2026-09-25 11:25, nobody
#                   started it again for a day -- and the old probe reported it as "not
#                   responding (probe timed out)", which sent every reader down the wedge path.
#   hung         -> `docker desktop restart --timeout 240`. The probe times out (rc 124); the
#                   2026-09-22 Resource-Saver-then-sleep wedge, or another one. Kills every
#                   container on the machine, other sessions' throwaway psql/mongo clients included.
# Then waits up to DOCKER_ENSURE_WAIT seconds (default 300) for `docker images` to answer.
# Every action is logged to harness-state/logs/docker-ensure.log so "who restarted Docker?" has
# an answer. Exit 0 = engine ready; 1 = still down (message on stderr names the state).
# Seams: DOCKER_ENSURE_DRY=1 prints the decision and exits 0 without acting; DOCKER_ENSURE_WAIT.
set -u

. "$HOME/.claude/hooks/lib-claude-paths.sh"
LOG="$(hstate logs docker-ensure.log)"
WAIT="${DOCKER_ENSURE_WAIT:-300}"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# probe: 0 answers, 124 hung, anything else = engine not reachable (usually not running).
probe() {
  local err rc
  err="$(timeout 20 docker images -q 2>&1 >/dev/null)"; rc=$?
  PROBE_ERR="$err"
  return "$rc"
}

probe && exit 0
rc=$?
case "$rc" in
  124) state=hung; action="docker desktop restart --timeout 240" ;;
  *)   state=not-running; action="docker desktop start" ;;
esac
echo "docker engine $state (probe rc=$rc): ${PROBE_ERR%%$'\n'*}" >&2
if [ "${DOCKER_ENSURE_DRY:-0}" = 1 ]; then echo "dry: would run: $action" >&2; exit 0; fi

log "engine $state (probe rc=$rc) -> $action [session ${CLAUDE_SESSION_ID:-?}]"
echo "running: $action" >&2
# shellcheck disable=SC2086
timeout 300 $action >/dev/null 2>&1 || log "  $action exited $? (continuing to wait)"

deadline=$(( $(date +%s) + WAIT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if probe; then
    log "  engine ready"
    echo "docker engine ready" >&2
    exit 0
  fi
  sleep 10
done
log "  engine still down after ${WAIT}s: ${PROBE_ERR%%$'\n'*}"
echo "docker engine still down after ${WAIT}s: ${PROBE_ERR%%$'\n'*}" >&2
exit 1
