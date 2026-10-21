#!/usr/bin/env bash
# Sourced helper: may a cohort be CREATED right now? Each POST /cohort queues one report-scale
# generation on the ONE Redshift cluster shared by QA/Staging/Production, and the standing rule is
# no heavy work Mon-Fri 09:00-16:59 ET. Guards production always, qa/staging only when more than
# 10 cohorts are pending (a 4-cohort fixture is light). COHORT_IGNORE_WINDOW=1 overrides.
# Fails CLOSED when ET cannot be resolved (lib-et-now.sh's contract for production actions).
# Also stops from 08:15 ET on a weekday: a batch posted then is still generating at 09:00.
#
# window_blocked <env> <pending-count>  -> prints the reason and returns 0 when creation must wait,
#                                          returns 1 (prints nothing) when it may go ahead.
. "$HOME/.claude/hooks/lib-et-now.sh"

window_blocked() {
  local env="$1" pending="${2:-0}" st et hour dow hm
  [ -n "${COHORT_IGNORE_WINDOW:-}" ] && return 1
  { [ "$env" = production ] || [ "$pending" -gt 10 ]; } || return 1
  st="$(et_window_state)"
  case "$st" in
    inside*)  echo "inside the Mon-Fri 9-5 ET window ($st)"; return 0 ;;
    outside*) ;;
    *)        echo "ET clock unresolved ($st) -- failing closed"; return 0 ;;
  esac
  et="$(et_now)" || { echo "ET clock unresolved -- failing closed"; return 0; }
  hour="${et%% *}"; hour="${hour#0}"
  dow="$(awk '{print $2}' <<<"$et")"; hm="$(awk '{print $3}' <<<"$et")"
  if [[ "$dow" =~ ^[1-5]$ ]] && [ "$hour" -eq 8 ] && [ "${hm#*:}" -ge 15 ]; then
    echo "window opens at 09:00 ET and it is $hm ET -- a batch posted now would still be generating"; return 0
  fi
  return 1
}
