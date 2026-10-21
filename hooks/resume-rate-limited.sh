#!/usr/bin/env bash
# Scheduled-task target (registered by statusline.sh's schedule_resume, which also appends the
# queue rows), fired once at the usage window's resets_at. Resumes every QUEUED session with
# "continue" (user preference: resume + auto-continue, keep working unattended), then clears
# the queue and deletes the one-shot task that ran it.
# A row whose transcript has been idle > 8 days (one weekly window + slack) is skipped and
# dropped: the queue held 11 rows for weeks, and the next 99% exhaustion would have
# `claude --resume`d eleven dead sessions (harness-gaps 2026-09-07). Transcripts persist, so
# "exists" is no test; idle age is.
set -u

QUEUE="$HOME/.claude/harness-state/sessions/.rate-limited-sessions"
[ -f "$QUEUE" ] || exit 0
PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

while IFS='|' read -r sid cmd; do
  [ -n "$sid" ] || continue
  if [ -z "$(find "$PROJECTS" -maxdepth 2 -name "$sid.jsonl" -mtime -8 -print -quit 2>/dev/null)" ]; then
    printf '%s skip %s: transcript missing or idle >8 days\n' "$(date '+%F %T')" "$sid" >> "$HOME/.claude/harness-state/logs/resume-rate-limited.log" 2>/dev/null || true
    continue
  fi
  # Resume in the background, one process per session -- don't block waiting for one
  # to finish before starting the next.
  (eval "$cmd" >/dev/null 2>&1 &)
done < "$QUEUE"

: > "$QUEUE"

# Delete whichever AMA-ResumeAtReset-* task just fired -- find by matching this
# script's own invocation rather than assuming a single fixed name (multiple could
# exist if this ever fires close together for two different windows).
export MSYS_NO_PATHCONV=1
for t in $(schtasks.exe //query //fo csv //nh 2>/dev/null | grep -oP 'AMA-ResumeAtReset-[0-9]+'); do
  epoch="${t#AMA-ResumeAtReset-}"
  now="$(date +%s)"
  # Only delete a task whose scheduled time has actually passed (this run), not a
  # future one that hasn't fired yet.
  if [ "$epoch" -le "$now" ]; then
    schtasks.exe //delete //tn "$t" //f >/dev/null 2>&1
  fi
done
