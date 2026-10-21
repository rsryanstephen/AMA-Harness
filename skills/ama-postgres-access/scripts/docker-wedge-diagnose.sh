#!/usr/bin/env bash
# docker-wedge-diagnose.sh -- is a hung Docker engine the Resource-Saver-then-sleep wedge?
#
# Read-only. Prints evidence lines then ONE verdict line:
#   VERDICT: HEALTHY               engine answers; nothing to fix
#   VERDICT: RESOURCE_SAVER_SLEEP  hung + Resource Saver on + last pause never unpaused
#                                  + host slept after it -> restart, AND suggest turning
#                                  Resource Saver off (README prerequisite)
#   VERDICT: WEDGED_OTHER          hung, but evidence doesn't fit -> restart only, do NOT
#                                  suggest Resource Saver
#   VERDICT: NOT_RUNNING           not a wedge: the engine's named pipe is absent because
#                                  Docker Desktop is not running (2026-09-26: AutoStart off,
#                                  host rebooted the day before) -> docker-ensure.sh starts it
#
# Signature (seen 2026-09-22/23): backend log has "Docker Desktop is pausing..." with no
# later "unpause successful"; Windows Kernel-Power sleep (42) / Modern Standby (506) after it.
#
# Seams (tests): DOCKER_LOG_DIR, DOCKER_SETTINGS_FILE, DOCKER_PROBE_RC (skip live probe;
# DOCKER_PROBE_ERR = its stderr), DOCKER_SLEEPS_SINCE (skip Windows event query).
set -u

LOG_DIR="${DOCKER_LOG_DIR:-$HOME/AppData/Local/Docker/log/host}"
SETTINGS="${DOCKER_SETTINGS_FILE:-$HOME/AppData/Roaming/Docker/settings-store.json}"

if [ -n "${DOCKER_PROBE_RC:-}" ]; then
  rc="$DOCKER_PROBE_RC"; err="${DOCKER_PROBE_ERR:-}"
else
  err="$(timeout 20 docker images -q 2>&1 >/dev/null)"; rc=$?
fi
echo "probe: timeout 20 docker images -> rc=$rc"
if [ "$rc" = 0 ]; then echo "VERDICT: HEALTHY"; exit 0; fi
# A fast failure (not rc 124) whose error is "cannot connect" means nothing is listening:
# Docker Desktop is not running. The wedge checks below only apply to a HUNG engine.
if [ "$rc" != 124 ]; then
  case "$err" in
    *"cannot find the file specified"*|*"Is Docker Desktop running"*|*"error during connect"*|*"daemon running"*)
      echo "engine: not running (${err%%$'\n'*})"; echo "VERDICT: NOT_RUNNING"; exit 0 ;;
  esac
fi

# Absent key = Docker's default (on).
saver=on
grep -q '"UseResourceSaver": *false' "$SETTINGS" 2>/dev/null && saver=off
echo "resource saver: $saver ($SETTINGS)"

# Host-clock timestamp = first [..] on the line. "unpause successful" is taken from the
# WSLBootstrap re-log only: the bare init line carries the VM clock, which drifts on sleep.
logs=("$LOG_DIR"/com.docker.backend.exe.log*)
last_pause="$(grep -h 'is pausing' "${logs[@]}" 2>/dev/null | cut -c2-31 | sort | tail -1)"
last_unpause="$(grep -h 'WSLBootstrap.*unpause successful' "${logs[@]}" 2>/dev/null | cut -c2-31 | sort | tail -1)"
echo "last pause:              ${last_pause:-none}"
echo "last unpause successful: ${last_unpause:-none}"

stuck=no
[ -n "$last_pause" ] && [[ "$last_pause" > "${last_unpause:-0}" ]] && stuck=yes
echo "paused without unpause:  $stuck"

if [ -n "${DOCKER_SLEEPS_SINCE:-}" ]; then
  sleeps="$DOCKER_SLEEPS_SINCE"
elif [ "$stuck" = yes ]; then
  sleeps="$(powershell.exe -NoProfile -Command "try { @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=42,506; StartTime=([datetime]'${last_pause:0:19}Z').ToLocalTime()} -ErrorAction Stop).Count } catch { 0 }" 2>/dev/null | tr -d '\r ')"
else
  sleeps=0
fi
echo "host sleeps since pause: ${sleeps:-0}"

if [ "$saver" = on ] && [ "$stuck" = yes ] && [ "${sleeps:-0}" -gt 0 ] 2>/dev/null; then
  echo "VERDICT: RESOURCE_SAVER_SLEEP"
else
  echo "VERDICT: WEDGED_OTHER"
fi
