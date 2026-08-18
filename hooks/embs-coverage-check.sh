#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Nudges Claude to re-run the
# ama-embs-reminders skill once the eMBS calendar's published tag window is about to
# run out -- see skills/ama-embs-reminders/scripts/embs-plan-reminders.sh's header for
# why "coverage" (latest month with an actual matching tag), not the URL, is the real
# refresh signal: the calendar page itself is evergreen/rolling, never goes stale.
#
# Pure bash, no network -- on-prompt.sh runs on EVERY prompt and is fork-cost/30s-
# timeout sensitive (see its own comment near the harness-memory block). This only
# reads two tiny state files under ~/.claude/.
#
# Sets $embs_notice (empty if nothing to say). Caller appends it to $ctx and is
# responsible for throttling via .embs-nudged (done here, once per calendar day).
embs_notice=""
COVERAGE_FILE="$HOME/.claude/.embs-coverage"
NUDGED_FILE="$HOME/.claude/.embs-nudged"
today="$(date +%F)"
this_month="${today%-*}"

due=0
if [ ! -f "$COVERAGE_FILE" ]; then
  due=1
else
  coverage="$(cat "$COVERAGE_FILE" 2>/dev/null)"
  # this_month >= coverage (no `>=` string op in `[ ]` -- negate `<`): the last
  # covered month IS the current month -> no future data left, refresh.
  [ -n "$coverage" ] && ! [ "$this_month" \< "$coverage" ] && due=1
fi

if [ "$due" = "1" ]; then
  last_nudge="$(cat "$NUDGED_FILE" 2>/dev/null || true)"
  if [ "$last_nudge" != "$today" ]; then
    embs_notice="eMBS monthly-file reminder coverage runs out this month -- run the ama-embs-reminders skill now to fetch newly-published dates and create the Google Calendar reminders."
    printf '%s\n' "$today" > "$NUDGED_FILE"
  fi
fi
