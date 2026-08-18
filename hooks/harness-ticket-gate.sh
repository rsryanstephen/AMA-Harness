#!/usr/bin/env bash
# PreToolUse hook (mcp__*__createJiraIssue). Denies creating a NEW ticket whose Epic
# Link is the AMA Harness epic (<harnessEpicKey>) -- harness work never gets its own
# sub-ticket, commit against the epic directly instead. This exact rule flip-flopped
# twice already (own-ticket-per-change, reversed, reversed back) before prose alone
# held -- mechanical this time, same as commit-ticket's own note says to do.
set -u

# Also covers ama-jira-api's jira-create-issue.sh -- same fixed-payload-file read as
# jira-ticket-fields-gate.sh, never command-text JSON parsing.
IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq/config fork (precedent:
# aggregation-secret-gate.sh) -- both arms below need either the MCP createJiraIssue
# tool name or a jira-create-issue.sh invocation, each leaving its literal substring
# in the raw payload. The config reads moved below this filter too: they forked 4
# processes on every Bash call before the payload was even looked at. ~60ms/fork.
case "$payload" in *createJiraIssue*|*jira-create-issue*) ;; *) exit 0 ;; esac

CONFIG="$HOME/.claude/harness-config.json"
harness_epic="<harnessEpicKey>"
[ -f "$CONFIG" ] && harness_epic="$(jq -r '.atlassian.harnessEpicKey // "<harnessEpicKey>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
[ -n "$harness_epic" ] || harness_epic="<harnessEpicKey>"
# The Epic Link field's customfield ID is per-Jira-instance, not universal -- read it
# from config instead of hardcoding <epicLinkFieldId>, which was this instance's ID only.
epic_field="<epicLinkFieldId>"
[ -f "$CONFIG" ] && epic_field="$(jq -r '.atlassian.epicLinkFieldId // "<epicLinkFieldId>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
[ -n "$epic_field" ] || epic_field="<epicLinkFieldId>"

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

epic=""
case "$tool" in
  mcp__*__createJiraIssue)
    epic="$(printf '%s' "$payload" | jq -r --arg f "$epic_field" '.tool_input.additional_fields[$f] // empty' 2>/dev/null | sed 's/\r$//')"
    ;;
  *)
    printf '%s' "$command" | grep -qP '(^|[;&|]\s*)(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*jira-create-issue\.sh|(^|[;&|]\s*)\.[/\\]\S*jira-create-issue\.sh' || exit 0
    PAYLOAD_FILE="$HOME/.claude/.jira-write-payload.json"
    [ -f "$PAYLOAD_FILE" ] || exit 0
    epic="$(jq -r --arg f "$epic_field" '.additional_fields[$f] // empty' "$PAYLOAD_FILE" 2>/dev/null | sed 's/\r$//')"
    ;;
esac

[ "$epic" = "$harness_epic" ] || exit 0

jq -cn --arg e "$harness_epic" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Harness work never gets its own ticket -- this is our own harness gate, not a Jira requirement. Commit directly against " + $e + " (\"" + $e + ": <description>\") and update ama-claude-harness/AGENTS.md instead of creating a sub-ticket. See commit-ticket'"'"'s \"Harness work\" section.")
  }
}'
