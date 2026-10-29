#!/usr/bin/env bash
# PostToolUse Bash|PowerShell (dispatched, warn-only): a detached bash poller started outside
# scripts/durable-monitor.sh -- `nohup bash X &`, `setsid bash X`, `Start-Process ... bash.exe X`
# -- dies with the next PC restart or sign-out and nothing restarts it. User rule 2026-10-22:
# reminders and monitors survive a reboot, all handled the same way. Prose alone is
# self-recognition; this is the mechanical trigger (CLAUDE.md "Mechanical Triggers").
# Needle first (no fork on the common path); the harness's own registered watchers are exempt.
set -u
IFS= read -r -d '' payload || true
case "$payload" in *nohup*|*setsid*|*Start-Process*) ;; *) exit 0 ;; esac
case "$payload" in *durable-monitor.sh*|*reminder-watch.sh*|*pr-merge-watch*|*feedback-prod-watch*|*feedback-reply-item*|*pr-review-watch*|*octopus-task-watch*) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0
# Launcher in command position only -- `command -v setsid` is a lookup, not a launch (false fire 2026-10-28).
printf '%s' "$command" | grep -qE '(^|[;&|(`]|then|do|else)[[:space:]]*(nohup|setsid)[[:space:]]|Start-Process' || exit 0
script="$(printf '%s' "$command" | grep -oE "[^ \"']+\.sh" | head -1)"
[ -n "$script" ] || exit 0
msg="You started \`$script\` as a detached process. It will not survive a PC restart or sign-out, and nothing restarts it. Register it instead (it starts it for you): \`bash ~/.claude/scripts/durable-monitor.sh add <name> [--until YYYY-MM-DD] $script [args]\` -- any session's next prompt and the AMA-Harness-Watchers-Ensure task (logon, resume, every 30 min) bring it back. Already running? Kill it and add, or add with --pid <its msys pid>. A one-off that exits by itself is not a monitor -- ignore this."
jq -cn --arg r "$msg" '{decision:"block", reason:$r}'
