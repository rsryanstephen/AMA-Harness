#!/usr/bin/env bash
# PreToolUse nudge (Bash|PowerShell, additionalContext only, once per session).
#
# PROJ-15355: a correct fix was pushed, probed 45s after Octopus reported Success,
# measured against the PRE-DEPLOY container, declared broken and reverted. The check that
# "confirmed" the deploy read `describe-services -> services[0].taskDefinition`, which the
# service points at from the MOMENT A ROLLOUT STARTS -- long before the new task serves
# traffic. ama-octopus-deploy/SKILL.md already warned about this in prose and the session
# had quoted it; prose lost, so this is the mechanical trigger (CLAUDE.md: "Mechanical
# Triggers Over Self-Recognition").
#
# Warn, never block: `aws ecs describe-services` is legitimate for plenty of things, and
# `describe-task-definition` on its own is THE way to read a service's env vars (creds,
# connection strings) -- deliberately not matched here, and must never be nagged.
# No permissionDecision -- an explicit allow can override a sibling gate's deny
# (GATES-AND-HOOKS.md).
set -u

IFS= read -r -d '' payload || true
# Needle test before any jq fork. `describe-services` may be in the command text OR inside a
# scratch script the command merely runs, so the cheap pre-check has to admit both.
case "$payload" in *describe-services*|*scratch*|*Temp/claude*|*Temp\\claude*|*temp/claude*) ;; *) exit 0 ;; esac

sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' | tr -d '\r')"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
[ -n "$sid" ] && [ -n "$cmd" ] || exit 0

# The command that caused PROJ-15355 was `bash <scratchpad>/check-qa-image.sh` -- the
# describe-services call was INSIDE the script, so a command-text-only match would have
# missed the very incident this gate exists for. Same bypass lib-scan-script-refs.sh was
# written for (the DB write gates), and the harness's own style gates actively push commands
# into script files, so this is the normal shape rather than an evasion. Scope is that lib's:
# repo scratch/ dirs and the session scratchpad only.
# shellcheck source=/dev/null
. "$HOME/.claude/hooks/lib-scan-script-refs.sh" 2>/dev/null || true
if command -v scan_referenced_scripts >/dev/null 2>&1; then
  cmd="$cmd
$(scan_referenced_scripts "$cmd")"
fi

# Only the shape that answers "what is deployed?" off the SERVICE: describe-services whose
# output is being mined for the task definition or the image. A describe-services used to
# read runningCount/rolloutState/events is fine and not matched.
printf '%s' "$cmd" | grep -qE 'aws[[:space:]]+ecs[[:space:]]+describe-services' || exit 0
printf '%s' "$cmd" | grep -qE 'taskDefinition|\.image|containerDefinitions' || exit 0

STATED="$HOME/.claude/.session-chatfiles"
NF="$STATED/$sid.ecsimage"
[ -f "$NF" ] && exit 0
mkdir -p "$STATED" 2>/dev/null
printf 'nudged\n' >> "$NF" 2>/dev/null

note="A service's registered task definition is NOT what is currently serving. ECS points the service at the new revision when a rolling deploy STARTS; the old task keeps taking traffic until the new one is healthy, so during the whole rollout window describe-services answers \"what did we ask for\", not \"what is running\". To read what is actually serving: aws ecs list-tasks --desired-status RUNNING, then aws ecs describe-tasks --query 'tasks[].containers[0].image' -- every running task, since a part-rolled service serves both versions. Better still, do not hand-roll it: verify-qa-deploy.sh polls to steady state first and then asserts the running tasks' image (pass the expected version as arg 5, or use verify-deployment-e2e.sh which derives it). This cost a real revert of a correct fix (PROJ-15355)."

jq -cn --arg n "$note" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: ("Deploy-verification pointer (once per session): " + $n)
  }
}'
