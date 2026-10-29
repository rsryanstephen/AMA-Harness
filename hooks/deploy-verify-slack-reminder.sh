#!/usr/bin/env bash
# PostToolUse (Bash|PowerShell). After a deploy-verification script finishes CLEAN, nudge
# the standing instruction: post a short summary to #<amaSupportChannelName>.
#
# DEPLOY-VERIFICATION.md: "Standing instruction (per explicit user request), do this every
# time, not a one-off ask." Nothing fired after the verify scripts finished --
# deploy-verify-confirm-gate.sh gates the START, not the finish -- so the rule lived on the
# agent remembering it (2026-09-15 audit). CLAUDE.md's own rule: a skill meant to fire
# "after X happens" needs a hook behind it. Same pattern as library-version-sync-reminder.sh.
#
# Fires only on a clean result. The "don't post during an active incident" half stays
# judgement, so this nudges rather than acts.
#
# PRODUCTION only (user instruction 2026-09-26): QA/staging deploys get no post. Env read
# from the script's own `Cluster: <env>-v1-AMA` line, falling back to an `AMA_ENV=` prefix
# in the command; neither found = the script's default, qa = silent.
set -u
IFS= read -r -d '' payload || true
case "$payload" in *verify-qa-deploy*|*verify-deployment-e2e*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0
printf '%s' "$command" | grep -qE 'verify-(qa-deploy|deployment-e2e)\.sh' || exit 0

# Clean = the script's own RESULT line says steady and nothing says FAILED/TIMED OUT.
out="$(printf '%s' "$payload" | jq -r '.tool_response.stdout // .tool_response // empty' 2>/dev/null)"
printf '%s' "$out" | grep -q 'RESULT: deployment steady' || exit 0
printf '%s' "$out" | grep -qE 'FAILED|TIMED OUT|crash' && exit 0

env="$(printf '%s' "$out" | grep -oE 'Cluster: [a-z]+-v1-AMA' | head -1 | sed -E 's/Cluster: ([a-z]+)-v1-AMA/\1/')"
[ -n "$env" ] || env="$(printf '%s' "$command" | grep -oE 'AMA_ENV=[a-z]+' | head -1 | cut -d= -f2)"
[ "$env" = production ] || exit 0

CONFIG="$HOME/.claude/harness-config.json"
chan="$(jq -r '.slack.amaSupportChannelName // "#<amaSupportChannelName>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
jq -cn --arg c "$chan" '{decision:"block", reason:("Production deploy verification came back clean. Standing instruction (DEPLOY-VERIFICATION.md, explicit user request, every production deploy): post a short summary to " + $c + " -- repo, environment, version, one line on what was verified. Terse, per memory/slack-messages-terse.md; no hotfix number in the text. Skip only if an incident is live in that channel right now.")}'
exit 0
