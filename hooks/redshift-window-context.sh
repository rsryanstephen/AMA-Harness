#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell). Context-only -- NEVER a decision. When rs-query.sh runs
# inside US business hours (Mon-Fri 9am-5pm ET), inject the standing rule about
# Redshift-heavy work so the agent judges the query's weight with the clock in view.
#
# Why not a deny gate: ama-postgres-access's own reasoning stands -- the shared cluster
# serves QA, Staging AND Production users, but a hook cannot tell a light metadata SELECT
# from a report-scale query, and denying every rs-query.sh in the window would false-block
# constant legitimate use. GATES-AND-HOOKS.md's middle option: additionalContext with no
# permissionDecision. ET via lib-et-now.sh (never TZ=... date -- git-bash ignores TZ).
set -u
payload="$(cat)"
case "$payload" in *rs-query*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0
printf '%s' "$command" | grep -qE 'rs-query\.sh' || exit 0
# EXPLAIN is planner-only and always fine.
printf '%s' "$command" | grep -qiE 'rs-query\.sh[[:space:]]+"?[[:space:]]*explain' && exit 0

. "$HOME/.claude/hooks/lib-et-now.sh" 2>/dev/null || exit 0
state="$(et_window_state)"
case "$state" in
  inside*)
    jq -cn --arg et "${state#inside }" '{hookSpecificOutput:{hookEventName:"PreToolUse",
      additionalContext:("It is " + $et + " -- inside US business hours (Mon-Fri 9am-5pm ET). Standing rule (ama-postgres-access): NO Redshift-heavy work in this window; the one cluster serves QA, Staging and Production users. Light metadata SELECTs, single-row lookups and EXPLAIN are fine; ONE report-scale run for an urgent prod bug is allowed after the user explicit yes (separate from any deploy override). If this rs-query.sh executes a report-scale query, a load test, or a calibration matrix, timeshift it outside the window -- and SCHEDULE the deferred work in the same turn: a durable reminder (scripts/reminder.sh add) for the next weekday 08:00 LOCAL (the PC is off at 17:04 ET) carrying the full task. deferred-window-reminder-check.sh blocks a deferral that sets none.")}}'
    ;;
esac
exit 0
