#!/usr/bin/env bash
# Durable monitors: a bash poller registered here is restarted after a PC crash, restart or
# sign-out -- by any session's next prompt (hooks/pr-watch-check.sh) and by the scheduled task
# AMA-Harness-Watchers-Ensure (logon, resume, every 30 min), whichever comes first. User rule
# 2026-10-22: reminders and monitors must survive a reboot, all handled the same way -- the 15834
# Test Complete watcher and the RabbitMQ-timeout monitor were detached processes a restart would
# have silently lost. Every long-lived poller a session starts goes through here, never a bare
# nohup/Start-Process (a poller that takes arguments registers ITSELF at start, see
# scripts/octopus-task-watch.sh, and removes itself when done).
#
#   durable-monitor.sh add <name> [--until YYYY-MM-DD] [--pid N] <script> [args...]   register; start if not running
#   durable-monitor.sh remove <name>                                                   unregister (process left alone)
#   durable-monitor.sh list
#   durable-monitor.sh ensure                                                          start every registered monitor whose process is gone
#
# Marker: harness-state/monitors/<name> = command words (script + args, space-separated, no
# spaces inside an argument) / until (or -) / msys pid of the last start. Liveness =
# proc_alive_running (hooks/lib-proc-cmdline.sh): that pid alive AND its command line names the
# script -- never kill -0 alone, pids restart after a reboot. Works from any session or task,
# costs no fork. Started with nohup + disown, the shape pr-watch-check.sh already uses for the
# feedback watchers (they outlive the session that launched them). ensure runs on every prompt.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"
. "$HOME/.claude/hooks/lib-proc-cmdline.sh"
D="$(hstate monitors .keep)"; D="${D%/.keep}"; mkdir -p "$D"

start_monitor() {   # $1 marker path; line 1 = command words
  local -a words; IFS=' ' read -r -a words < "$1"
  # DURABLE_MONITOR_RESTART tells the child it has no session reading its stdout (a restart
  # after a reboot): a poller that reports by printing must file a durable reminder instead.
  # Exit 0 = the monitor FINISHED (fired its reminder, expired) -> deregistered here, else the
  # next ensure would restart it and it would fire again: the 15834 Test Complete watcher filed
  # five "deploy now" reminders in an hour that way (2026-10-22). Non-zero or killed (a reboot,
  # taskkill) = not finished -> marker kept, restarted. The wrapper's argv carries the script
  # path, so proc_alive_running's needle still matches the recorded pid.
  { DURABLE_MONITOR_RESTART=1 DM_MARKER="$1" nohup bash -c 'bash "$@"; rc=$?; [ "$rc" -eq 0 ] && rm -f "$DM_MARKER"; exit $rc' _ "${words[@]}" >/dev/null 2>&1 & } 2>/dev/null
  local pid=$!; disown 2>/dev/null || true
  { sed -n 1,2p "$1"; printf '%s\n' "$pid"; } > "$1.tmp" && mv "$1.tmp" "$1"
  printf 'started %s (pid %s)\n' "${1##*/}" "$pid"
}

case "${1:-}" in
  add)
    name="${2:?name}"; shift 2; until="-"; given=""
    while :; do case "${1:-}" in
      --until) until="${2:?date}"; shift 2 ;;
      --pid) given="${2:?pid}"; shift 2 ;;   # a running poller registering itself: record, don't start
      *) break ;;
    esac; done
    [ -f "${1:-}" ] || { echo "no such script: ${1:-}" >&2; exit 1; }
    m="$D/$name"; pid="$given"; [ -z "$pid" ] && [ -f "$m" ] && pid="$(sed -n 3p "$m")"
    if proc_alive_running "$pid" "${1##*/}"; then
      printf '%s\n%s\n%s\n' "$*" "$until" "$pid" > "$m"; echo "updated $name (already running, pid $pid)"
    else
      printf '%s\n%s\n' "$*" "$until" > "$m"; start_monitor "$m"
    fi ;;
  remove) rm -f "$D/${2:?name}" && echo "removed $2" ;;
  list)
    for m in "$D"/*; do
      [ -f "$m" ] || continue
      { read -r c; read -r u; read -r p; } < "$m"
      s="${c%% *}"; st=dead; proc_alive_running "${p:-}" "${s##*/}" && st="running pid $p"
      printf '%-24s %-18s until=%s  %s\n' "${m##*/}" "$st" "$u" "$c"
    done ;;
  ensure)
    today="$(date +%F)"
    for m in "$D"/*; do
      [ -f "$m" ] || continue
      { read -r c; read -r u; read -r p; } < "$m"
      if [ "$u" != "-" ] && [ "$u" \< "$today" ]; then rm -f "$m"; continue; fi   # expired
      s="${c%% *}"
      [ -f "$s" ] || { rm -f "$m"; printf 'monitor %s: script gone, unregistered\n' "${m##*/}" >&2; continue; }
      proc_alive_running "${p:-}" "${s##*/}" && continue
      start_monitor "$m"
    done ;;
  *) sed -n 11,14p "$0"; exit 2 ;;
esac
