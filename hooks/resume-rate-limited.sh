#!/usr/bin/env bash
# Scheduled-task target (created by on-stop.sh's check_rate_limit_hit), fired once at
# the usage window's resets_at. Resumes every session queued in
# ~/.claude/.rate-limited-sessions with "continue" (per explicit user preference:
# resume + auto-continue, keep working unattended -- not resume-and-wait), then
# clears the queue and deletes the scheduled task that ran it (one-shot, self-cleaning).
set -u

QUEUE="$HOME/.claude/.rate-limited-sessions"
[ -f "$QUEUE" ] || exit 0

while IFS='|' read -r sid cmd; do
  [ -n "$sid" ] || continue
  # Resume in the background, one process per session -- don't block waiting for one
  # to finish before starting the next.
  (eval "$cmd" >/dev/null 2>&1 &)
done < "$QUEUE"

: > "$QUEUE"

# Delete whichever AMA-ResumeAtReset-* task just fired -- find by matching this
# script's own invocation rather than assuming a single fixed name (multiple could
# exist if this ever fires close together for two different windows).
export MSYS_NO_PATHCONV=1
for t in $(schtasks.exe /query /fo csv /nh 2>/dev/null | grep -oP 'AMA-ResumeAtReset-[0-9]+'); do
  epoch="${t#AMA-ResumeAtReset-}"
  now="$(date +%s)"
  # Only delete a task whose scheduled time has actually passed (this run), not a
  # future one that hasn't fired yet.
  if [ "$epoch" -le "$now" ]; then
    schtasks.exe /delete /tn "$t" /f >/dev/null 2>&1
  fi
done
