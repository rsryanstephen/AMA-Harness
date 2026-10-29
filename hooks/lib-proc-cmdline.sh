#!/usr/bin/env bash
# proc_alive_running <pid> <needle>: 0 when <pid> is a live MSYS process whose command line
# has a word containing <needle>. The one liveness test for every recorded watcher/monitor pid
# (durable-monitor.sh, reminder-check.sh, reminder.sh watch, pr-watch-check.sh).
#
# kill -0 alone is not enough: MSYS pids restart from scratch after a reboot and the hooks spawn
# ~100 bash per prompt, so a recorded pid lands on an unrelated process easily -- then "alive"
# means a dead watcher is never restarted, the exact outcome the restart exists to prevent
# (side-agent review 2026-10-22; same flaw scripts/lib-suite-lock.sh's holder check had).
# Fork-free: /proc/<pid>/cmdline is NUL-separated, read with the builtin; the last word has no
# trailing NUL, hence the `|| [ -n "$w" ]`. Sourced by on-prompt hooks, so it must stay this cheap.
proc_alive_running() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null || return 1
  [ -r "/proc/$1/cmdline" ] || return 1
  local w=""
  while IFS= read -r -d '' w || [ -n "$w" ]; do
    case "$w" in *"$2"*) return 0 ;; esac
    w=""
  done < "/proc/$1/cmdline"
  return 1
}
