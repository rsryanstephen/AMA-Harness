#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell). Denies shell tracing (`bash -x`, `sh -x`, `set -x`,
# `Set-PSDebug -Trace`) of a harness script -- anything under skills/ or hooks/ -- because
# trace output prints every expanded command, Authorization/API-key headers included,
# into the tool result and therefore the transcript.
#
# Hit live 2026-09-15: `bash -x last-prod-deploy-date.sh` printed the Octopus API key in
# its curl -H line. Local transcript only, but a leaked secret is not reversible and
# redact-secret.sh does not cover tool output. Debug a harness script with `set -v`-free
# means: add `echo` lines, or trace with the token redacted (`bash -x 2>&1 | redact-secret`).
# Hatch: AMA_ALLOW_TRACE=1 in the command, when the script provably reads no secret.
set -u
payload="$(cat)"
case "$payload" in *" -x"*|*"set -x"*|*"-Trace"*|*"-xv"*|*"-vx"*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0
case "$command" in *AMA_ALLOW_TRACE=1*) exit 0 ;; esac

. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || exit 0
region="$(printf '%s' "$command" | command_without_heredoc_bodies)"

# Harness script paths: skills/, hooks/, or anything under ~/.claude.
printf '%s' "$region" | grep -qE '(\.claude/|/skills/|/hooks/|~/\.claude)' || exit 0
# A trace form: interpreter -x flag, `set -x` anywhere before it, or PowerShell tracing.
if printf '%s' "$region" | grep -qE '(^|[;&|[:space:]])(bash|sh)([.]exe)?[[:space:]]+-[a-zA-Z]*x' \
   || printf '%s' "$region" | grep -qE '(^|[;&|[:space:]])set[[:space:]]+-[a-zA-Z]*x' \
   || printf '%s' "$region" | grep -qiE 'Set-PSDebug[[:space:]]+-Trace[[:space:]]+[12]'; then
  jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
    permissionDecisionReason:"Tracing a harness script prints every expanded command -- API keys in curl -H headers included -- into the tool output and the transcript (hit live 2026-09-15 on last-prod-deploy-date.sh, Octopus key exposed). A leaked secret is not reversible. Debug with echo lines, run the failing curl by hand with the token in a variable you never print, or pipe the trace through redact-secret.sh. If the script provably reads no secret, re-run with AMA_ALLOW_TRACE=1."}}'
fi
exit 0
