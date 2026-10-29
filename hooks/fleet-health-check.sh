#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Nudges Claude in-session when the
# nightly fleet-health sweep (AMA-Harness-Fleet-Health-Check task ->
# skills/ama-library-version-sync/scripts/fleet-health-check.sh) hasn't logged a
# completion in run-history.log recently.
#
# <harnessEpicKey>: fleet-health had NO delivery path at all -- deltas sat in results.log
# unread (confirmed: 7 findings had silently accumulated with nobody ever notified). The
# script itself now pings on newly-added RISK/FAIL lines directly (see its own header).
# This hook is the OTHER half: what if the nightly task itself silently stops firing (task
# disabled, machine never on at 01:47, script errors before it can ever reach its own ping
# logic)? A ping that lives only inside the script can't warn about the script not
# running at all. Same shape as embs/aws's staleness nudges -- pure bash, no network,
# three tiny state reads, since on-prompt.sh runs on EVERY prompt and is
# fork-cost/30s-timeout sensitive.
#
# Sets $fleet_health_notice (empty if nothing to say). Throttled once per calendar day.
fleet_health_notice=""
. "$HOME/.claude/hooks/lib-claude-paths.sh"
RUN_HISTORY="$(hstate logs fleet-health/run-history.log)"
NUDGED_FILE="$(hstate notices .fleet-health-nudged)"
DIGEST_FILE="$(hstate notices .fleet-health-digest)"
today="$(date +%F)"

# One-shot digest wins over the staleness nudge -- it carries an actual RISK/FAIL count
# the script's own ping already wrote (see fleet-health-check.sh). No `return || exit`
# idiom here, same reason as aws-notices-check.sh: if the else-branch below ever hit
# `exit 0` while sourced, on-prompt.sh would die before its final jq emit and the whole
# turn's injected context would be silently lost. A plain if/else can't do that.
if [ -s "$DIGEST_FILE" ]; then
  fleet_health_notice="Fleet health: $(cat "$DIGEST_FILE") Surface this distinctly, then continue with the task."
  : > "$DIGEST_FILE"
else
  stale_days=2
  due=0
  if [ ! -s "$RUN_HISTORY" ]; then
    due=1
  else
    last_line="$(tail -1 "$RUN_HISTORY" 2>/dev/null || true)"
    last="${last_line%% *}"
    cutoff="$(date -d "$stale_days days ago" +%F 2>/dev/null || true)"
    [ -n "$last" ] && [ -n "$cutoff" ] && [ "$last" \< "$cutoff" ] && due=1
  fi

  if [ "$due" = "1" ]; then
    last_nudge="$(cat "$NUDGED_FILE" 2>/dev/null || true)"
    if [ "$last_nudge" != "$today" ]; then
      fleet_health_notice="The nightly fleet-health sweep hasn't logged a completion in over $stale_days day(s) -- check whether AMA-Harness-Fleet-Health-Check is still running (Get-ScheduledTaskInfo) rather than assuming the fleet is clean."
      printf '%s\n' "$today" > "$NUDGED_FILE"
    fi
  fi
fi
