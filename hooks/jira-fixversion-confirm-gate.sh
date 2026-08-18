#!/usr/bin/env bash
# PreToolUse hook (mcp__*__createJiraIssue|editJiraIssue). Denies tagging a ticket with
# a release/* or hotfix/* Fix Version until the user has explicitly confirmed it was
# manually created in Jira -- there's no MCP tool or REST credential here to create one
# (confirmed: ama-cut-release-branch/ama-hotfix both hit this gap). Confirmation is
# recorded via confirm-jira-version.sh into ~/.claude/.confirmed-jira-versions.
set -u

# Also covers ama-jira-api's jira-edit-issue.sh/jira-create-issue.sh -- same
# fixed-payload-file read as jira-ticket-fields-gate.sh, never command-text parsing.
IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- every arm below needs either an MCP *JiraIssue tool
# name or a jira-edit/create-issue.sh invocation in the command, all of which leave
# one of these literal substrings in the raw payload. ~60ms/fork on this machine.
case "$payload" in *JiraIssue*|*jira-edit-issue*|*jira-create-issue*) ;; *) exit 0 ;; esac
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

versions=""
case "$tool" in
  mcp__*__editJiraIssue)
    versions="$(printf '%s' "$payload" | jq -r '.tool_input.fields.fixVersions[]?.name // empty')"
    ;;
  mcp__*__createJiraIssue)
    versions="$(printf '%s' "$payload" | jq -r '.tool_input.additional_fields.fixVersions[]?.name // empty')"
    ;;
  *)
    PAYLOAD_FILE="$HOME/.claude/.jira-write-payload.json"
    if printf '%s' "$command" | grep -qP '(^|[;&|]\s*)(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*jira-edit-issue\.sh|(^|[;&|]\s*)\.[/\\]\S*jira-edit-issue\.sh'; then
      [ -f "$PAYLOAD_FILE" ] || exit 0
      versions="$(jq -r '.fields.fixVersions[]?.name // empty' "$PAYLOAD_FILE" 2>/dev/null)"
    elif printf '%s' "$command" | grep -qP '(^|[;&|]\s*)(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*jira-create-issue\.sh|(^|[;&|]\s*)\.[/\\]\S*jira-create-issue\.sh'; then
      [ -f "$PAYLOAD_FILE" ] || exit 0
      versions="$(jq -r '.additional_fields.fixVersions[]?.name // empty' "$PAYLOAD_FILE" 2>/dev/null)"
    else
      exit 0
    fi
    ;;
esac

[ -n "$versions" ] || exit 0

CONFIRMED="$HOME/.claude/.confirmed-jira-versions"
unconfirmed=""
while IFS= read -r v; do
  v="${v%$'\r'}"
  [ -n "$v" ] || continue
  case "$v" in
    release/*|hotfix/*) : ;;
    *) continue ;;
  esac
  if [ ! -f "$CONFIRMED" ] || ! grep -qxF "$v" "$CONFIRMED"; then
    unconfirmed="$unconfirmed $v"
  fi
done <<< "$versions"

[ -n "$unconfirmed" ] || exit 0

jq -cn --arg v "$unconfirmed" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Fix Version(s)" + $v + " not yet confirmed created in Jira for this harness. Ask the user to create it in Jira project settings first, then run `bash \"$HOME/.claude/hooks/confirm-jira-version.sh\" <version>` before tagging tickets.")
  }
}'
