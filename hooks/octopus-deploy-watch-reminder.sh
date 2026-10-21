#!/usr/bin/env bash
# PostToolUse (Bash|PowerShell, dispatched). After a deploy POST this session made returns an
# Octopus task id, tell the model to start scripts/octopus-task-watch.sh on it as a background
# task -- so a failed deploy reaches the session on its own, with the cause, and the user never
# has to report it (user rule 2026-10-14). Twin for approvals the user runs from the Octopus UI:
# octopus-approval-watch-check.sh (Stop). Detection = lib-octopus-deploy-detect.sh, like the
# other deploy reminders. Context-only, never blocks.
set -u
IFS= read -r -d '' payload || true
case "$payload" in *deployments*|*octo-deploy*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0
. "$HOME/.claude/hooks/lib-octopus-deploy-detect.sh" 2>/dev/null || exit 0
octo_is_deploy_post "$(octo_scan_region "$command")" || exit 0
octo_response_shows_deploy "$payload" || exit 0

sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' | tr -d '\r')"
tasks="$(printf '%s' "$payload" | jq -r '.tool_response | if type=="string" then . else tostring end' 2>/dev/null | grep -oE 'ServerTasks-[0-9]+' | sort -u | tr '\n' ' ')"
if [ -n "$tasks" ]; then
  cmds=""; for t in $tasks; do cmds="$cmds \`bash ~/.claude/scripts/octopus-task-watch.sh $t $sid\`"; done
  msg="Deployment task(s) created: ${tasks}-- start the watcher NOW for each, as Bash run_in_background:true (no other output):${cmds}. It is silent until the task ends, then reports SUCCESS or FAILED with the error lines and cause. A FAILED report means debug it immediately (user rule 2026-10-14: the user never has to report a failed deploy)."
else
  msg="A deployment was just created but no ServerTasks id is visible in the output. Find it (GET /deployments/<Deployments-N> .TaskId, or octopus-task-watch.sh --next <project> <Environments-N> $sid) and start the watcher as Bash run_in_background:true so the outcome comes back to this session on its own."
fi
jq -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$c}}'
