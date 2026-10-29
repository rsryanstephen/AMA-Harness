#!/usr/bin/env bash
# Add a worklog to a Jira issue (v3 POST). Replaces MCP addWorklogToJiraIssue (retired 2026-08-31).
# Payload file shape: {"timeSpent": "1h 30m", "started": "2026-08-31T09:00:00.000+0000", "comment": "plain text"}
# ("started" optional -- defaults server-side to now; "comment" optional, wrapped into ADF here.)
# Same fixed-payload-file convention as every write script in this skill.
# Usage: JIRA_PAYLOAD_FILE=... jira-add-worklog.sh <ticket-key>
set -uo pipefail
. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1
key="${1:?usage: jira-add-worklog.sh <ticket-key>}"
PAYLOAD_FILE="${JIRA_PAYLOAD_FILE:?set JIRA_PAYLOAD_FILE=<per-call path> -- the shared default was retired 2026-09-07 (concurrent sessions clobbered it), see ama-jira-api SKILL.md}"
[ -f "$PAYLOAD_FILE" ] || { echo "jira-add-worklog.sh: $PAYLOAD_FILE not found -- write the payload there first (Write tool, never shell)" >&2; exit 1; }
[ -n "${ATLASSIAN_API_TOKEN:-}" ] || { echo "ATLASSIAN_API_TOKEN not set" >&2; exit 1; }

BODY_FILE="$(mktemp)"
jq -c '
  {timeSpent: .timeSpent}
  + (if .started then {started: .started} else {} end)
  + (if .comment then {comment: {type:"doc", version:1, content:[{type:"paragraph", content:[{type:"text", text:.comment}]}]}} else {} end)
' "$PAYLOAD_FILE" > "$BODY_FILE"

resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X POST -H "Content-Type: application/json" -d "@$BODY_FILE" \
  "https://${HOST}/rest/api/3/issue/${key}/worklog")"
status="${resp##*$'\n'}"
rm -f "$BODY_FILE"
[ "$status" = "201" ] || { printf 'jira-add-worklog.sh: HTTP %s\n%s\n' "$status" "${resp%$'\n'*}" >&2; exit 1; }
rm -f "$PAYLOAD_FILE"
echo "OK: worklog added to $key"
