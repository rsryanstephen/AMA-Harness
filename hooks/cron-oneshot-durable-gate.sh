#!/usr/bin/env bash
# PreToolUse (CronCreate). Denies a ONE-SHOT CronCreate (recurring:false) and redirects it to
# the durable reminder queue, scripts/reminder.sh (user instruction 2026-10-13): CronCreate is
# session-only (its `durable` flag is a documented no-op), so a reminder set for tomorrow
# morning dies the moment the user closes that session -- 4402d507 had two such reminders
# pinning it open overnight. Recurring crons (/loop) are untouched: they are about THIS session.
# Hatch: put "[session-only]" in the prompt when the reminder genuinely only matters here.
set -u
IFS= read -r -d '' payload || true
case "$payload" in *'"recurring":false'*|*'"recurring": false'*) ;; *) exit 0 ;; esac
case "$payload" in *'[session-only]'*) exit 0 ;; esac
sid="$(printf '%s' "$payload" | jq -r '.session_id // "<sid>"' | tr -d '\r')"
jq -cn --arg s "$sid" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny",
  permissionDecisionReason:("One-shot CronCreate is session-only and dies if this session closes. Use the durable queue instead -- it fires in whichever open session claims it first (never twice), and waits for the next session if none is open: `bash ~/.claude/scripts/reminder.sh add " + $s + " \"YYYY-MM-DD HH:MM\" <FULL task text: what to run, preconditions, what to do if not ready>` (local time), then start this session'"'"'s watcher if not already running: Bash run_in_background:true `bash ~/.claude/scripts/reminder.sh watch " + $s + "`. Tell the user the reminder survives closing the session. Only if it truly matters to this session alone, retry the CronCreate with \"[session-only]\" in the prompt.")}}'
