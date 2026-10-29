#!/usr/bin/env bash
# One gate suite at a time, machine-wide. Sourced by check-gates.sh and mutate-gates.sh.
#
# Why (2026-10-22): three filtered check-gates runs from three sessions overlapped 12:34-12:54
# while a mutate-gates pass followed at 12:58. Each run is ~5k forks; together they pushed
# bash-start from ~40 ms to 1-2.7 s and every live hook in every other session past its
# timeout (fail-open gates, 4-min prompts). AGENTS.md already said "never run two suites
# concurrently" -- prose, so it happened anyway.
#
# suite_lock <name>: take $HOME/.claude/harness-state/logs/.suite.lock (mkdir = atomic) holding
# the WINDOWS pid of the holder. Held by a live SUITE -> wait, 15 s polls, up to 20 min
# (SUITE_LOCK_MAX_POLLS overrides, for tests), one "waiting" line naming the lock; holder gone
# -> stale, taken over. Nested runs (mutate-gates.sh runs check-gates.sh as a child) inherit it
# via SUITE_LOCK_HELD and skip. suite_unlock: release, only if this process took it -- call it
# from the EXIT trap.
#
# The holder check proves the pid is still a SUITE (command line names check-gates or
# mutate-gates), never merely "some bash": a hard-killed run (low-memory supervisor,
# taskkill /F, restart) never ran its EXIT trap, Windows recycles pids fast, and with 100+ bash
# processes here a recycled pid on an unrelated bash would stall every later suite 20 min.
# Runs only on the already-held path, so the one powershell fork never touches a normal start.
suite_lock_holder_live() {
  local cl
  cl="$(powershell.exe -NoProfile -Command "(Get-CimInstance Win32_Process -Filter 'ProcessId=$1').CommandLine" 2>/dev/null)"
  case "$cl" in *check-gates*|*mutate-gates*) return 0 ;; esac
  return 1
}
suite_lock() {
  [ -n "${SUITE_LOCK_HELD:-}" ] && return 0
  local name="${1:-suite}" dir="$HOME/.claude/harness-state/logs" wp=$$ hp n=0 max="${SUITE_LOCK_MAX_POLLS:-80}"
  _suite_lock_dir="$dir/.suite.lock"
  mkdir -p "$dir"
  [ -r "/proc/$$/winpid" ] && IFS= read -r wp < "/proc/$$/winpid"
  until mkdir "$_suite_lock_dir" 2>/dev/null; do
    hp=""; [ -r "$_suite_lock_dir/pid" ] && IFS= read -r hp < "$_suite_lock_dir/pid"
    if [ -z "$hp" ] || ! suite_lock_holder_live "$hp"; then
      rm -rf "$_suite_lock_dir"; continue
    fi
    [ "$n" -eq 0 ] && printf '%s: another suite is running (pid %s, %s) -- waiting for it, up to 20 min; lock = %s\n' \
      "$name" "$hp" "$(cat "$_suite_lock_dir/name" 2>/dev/null)" "$_suite_lock_dir" >&2
    n=$((n + 1))
    if [ "$n" -gt "$max" ]; then
      printf '%s: gave up, suite pid %s still running -- rerun later, or if it is dead: rm -rf %s\n' "$name" "$hp" "$_suite_lock_dir" >&2
      return 3
    fi
    sleep 15
  done
  printf '%s\n' "$wp" > "$_suite_lock_dir/pid"; printf '%s\n' "$name" > "$_suite_lock_dir/name"
  export SUITE_LOCK_HELD="$wp"; _suite_lock_mine=1
}
suite_unlock() { [ -n "${_suite_lock_mine:-}" ] && rm -rf "$_suite_lock_dir"; return 0; }
