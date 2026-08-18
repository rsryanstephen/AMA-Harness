#!/usr/bin/env bash
# PreToolUse hook (Bash|PowerShell). Denies launching verify-qa-deploy.sh /
# verify-deployment-e2e.sh until the user has explicitly said yes for THIS session --
# docs already said "never run unprompted" in three places (DEPLOY-VERIFICATION.md,
# commit-ticket/SKILL.md) and it still got skipped (launched anyway, reported as
# already-decided). Same pattern as jira-fixversion-confirm-gate.sh.
# Confirmation is ONE-SHOT (per explicit user choice) -- consumed on first allow, not
# valid for a later push in the same session. Recorded via confirm-deploy-verify.sh
# into ~/.claude/.deploy-verify-approved, keyed by session_id.
#
# Match requires an actual invocation prefix (bash/sh/pwsh/powershell/./), not just the
# script name anywhere in the command text -- a bare substring match self-triggered on
# this hook's OWN synthetic test payloads (a `jq --arg` call building test JSON quoted
# the script name, no real invocation) -- same quote-blind trap bare-cd-gate.sh's
# comments already document. Known remaining gap: a command that quotes a full
# `bash .../verify-qa-deploy.sh` invocation as inert text (e.g. `echo "run bash ..."`)
# still matches -- accepted, same tradeoff bare-cd-gate.sh makes.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- the invocation regex below requires one of these two
# literal script names, so a payload without either can exit on zero forks. False
# positives fall through to the unchanged full logic; ~60ms/fork on this machine.
case "$payload" in *verify-qa-deploy*|*verify-deployment-e2e*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"

[ -n "$command" ] || exit 0
printf '%s' "$command" | grep -qP '(^|[;&|]\s*)(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*(verify-qa-deploy|verify-deployment-e2e)\.sh|(^|[;&|]\s*)\.[/\\]\S*(verify-qa-deploy|verify-deployment-e2e)\.sh' || exit 0
[ -n "$sid" ] || exit 0

FILE="$HOME/.claude/.deploy-verify-approved"

if [ -f "$FILE" ] && grep -qxF "$sid" "$FILE"; then
  # One-shot: consume this approval so a later push in the same session asks again.
  # NOTE: grep -v exits 1 when it excludes the only/last line (nothing selected) --
  # confirmed live -- so this must NOT be `grep ... && mv ...` or the mv silently never
  # runs and the approval never actually gets consumed. mv unconditionally instead.
  grep -vxF "$sid" "$FILE" > "$FILE.tmp"
  mv "$FILE.tmp" "$FILE"
  exit 0
fi

jq -cn --arg sid "$sid" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Deploy verification not yet approved by the user this session. Ask first (yes/no) -- declining is a normal answer for a small fix, not a fallback. On yes, run `bash \"$HOME/.claude/hooks/confirm-deploy-verify.sh\" " + $sid + "` then re-run this command. Never call this script from a subagent that returns before it finishes -- launch it from the main session with run_in_background instead, so the completion notification actually fires.")
  }
}'
