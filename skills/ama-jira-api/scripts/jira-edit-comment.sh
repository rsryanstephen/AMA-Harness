#!/usr/bin/env bash
# Direct Jira REST write: REPLACE an existing comment's body. Same fixed payload file and
# -d @file rule as jira-add-comment.sh (see its header). v2 endpoint: body is a plain
# string, so plain text round-trips without ADF wrapping.
# Payload file shape: {"body": "plain text comment"}
# Usage: jira-edit-comment.sh <ticket-key> <comment-id>
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

key="${1:?usage: jira-edit-comment.sh <ticket-key> <comment-id>}"
cid="${2:?usage: jira-edit-comment.sh <ticket-key> <comment-id>}"

PAYLOAD_FILE="${JIRA_PAYLOAD_FILE:?set JIRA_PAYLOAD_FILE=<per-call path> -- the shared default was retired 2026-09-07 (concurrent sessions clobbered it), see ama-jira-api SKILL.md}"
if [ ! -f "$PAYLOAD_FILE" ]; then
  echo "jira-edit-comment.sh: $PAYLOAD_FILE not found -- write the payload there first (Write tool, never shell)" >&2
  exit 1
fi
if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

BODY_FILE="$(mktemp)"
jq -c '{body: .body}' "$PAYLOAD_FILE" > "$BODY_FILE"

resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X PUT -H "Content-Type: application/json" -d "@$BODY_FILE" \
  "https://${HOST}/rest/api/2/issue/${key}/comment/${cid}")"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"

rm -f "$BODY_FILE"

if [ "$status" != "200" ]; then
  printf 'jira-edit-comment.sh: HTTP %s for %s comment %s\n%s\n' "$status" "$key" "$cid" "$respbody" >&2
  exit 1
fi

rm -f "$PAYLOAD_FILE"
echo "OK: comment ${cid} on ${key} replaced"
