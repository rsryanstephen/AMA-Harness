#!/usr/bin/env bash
# Shared readiness gate for unattended scheduled runs. Source it, then call
# `wait_until_online <log-fn>` before invoking a headless `claude -p`.
#
# Why this exists (confirmed live 2026-08-25, user-reported): the PC was off/asleep with no
# network at 09:30. Two separate failures came out of that one fact, and the second is the
# one this file fixes:
#   1. The fire was skipped entirely -- fixed at the TASK level (StartWhenAvailable=True,
#      DisallowStartIfOnBatteries=False; see AGENTS.md's scheduled-task-defaults section).
#   2. With catch-up now enabled, the task fires the moment the machine wakes -- and then
#      runs BEFORE the network and the claude.ai MCP connectors are back. A run in that
#      window fails with "every mcp__claude_ai_Slack__* tool is unavailable", which looks
#      like a broken connector rather than a cold start. Reproduced exactly: the 10:32 run
#      failed that way, and a probe minutes later returned AVAILABLE with nothing changed.
#
# Deliberately NOT an MCP probe: verifying the connector itself costs a whole extra
# `claude -p` invocation per run. Cheap network reachability plus the task's own
# restart-on-failure (RestartCount/RestartInterval) covers the same window for free.

# wait_until_online <log-fn> [max-waits] [sleep-seconds]
# Returns 0 once reachable, 1 if it gave up (caller decides whether to proceed anyway).
wait_until_online() {
  local logfn="${1:-:}" max="${2:-20}" nap="${3:-30}" i=0 waited=0

  while [ "$i" -lt "$max" ]; do
    # Any 2xx/3xx/4xx answer proves DNS + routing + TLS are up; the status code itself is
    # irrelevant, so --fail is deliberately NOT used.
    if curl -sS -o /dev/null --max-time 10 https://slack.com 2>/dev/null; then
      [ "$waited" -gt 0 ] && "$logfn" "network reachable after ${waited}s"
      return 0
    fi
    i=$((i + 1)); waited=$((waited + nap))
    [ "$i" -eq 1 ] && "$logfn" "no network yet (likely a just-woken machine) -- waiting"
    sleep "$nap"
  done

  "$logfn" "still no network after ${waited}s -- proceeding anyway, the run may fail on MCP"
  return 1
}
