#!/usr/bin/env bash
# Direct Jira REST write, replacing addCommentToJiraIssue. See jira-create-issue.sh's
# header for why the payload comes from a fixed file, never a command-line argument --
# doubly true here given comment text is free-form prose (non-ASCII em-dashes etc.
# already confirmed to corrupt as literal bash arguments, per ama-bitbucket-api/SKILL.md).
# Payload file shape: {"body": "plain text comment"}
# Usage: jira-add-comment.sh <ticket-key>
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

key="${1:?usage: jira-add-comment.sh <ticket-key>}"

PAYLOAD_FILE="$HOME/.claude/.jira-write-payload.json"
if [ ! -f "$PAYLOAD_FILE" ]; then
  echo "jira-add-comment.sh: $PAYLOAD_FILE not found -- write the payload there first (Write tool, never shell)" >&2
  exit 1
fi
if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

# Jira v3 comments are Atlassian Document Format (ADF), not plain strings -- wrap the
# plain-text body in the minimal valid ADF doc shape.
BODY_FILE="$(mktemp)"
jq -c '{
  body: {
    type: "doc", version: 1,
    content: [{type: "paragraph", content: [{type: "text", text: .body}]}]
  }
}' "$PAYLOAD_FILE" > "$BODY_FILE"

# -d @file, never -d "$var" -- a bash-variable-held body corrupts crossing the
# MSYS->Win32 boundary into curl.exe (confirmed live on jira-append-description.sh:
# identical JSON via -d @file got 204, the same content via -d "$body" 400'd with
# "error parsing JSON" -- reproducible, tied to specific byte content, not size alone).
resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X POST -H "Content-Type: application/json" -d "@$BODY_FILE" \
  "https://${HOST}/rest/api/3/issue/${key}/comment")"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"

rm -f "$BODY_FILE"

if [ "$status" != "200" ] && [ "$status" != "201" ]; then
  printf 'jira-add-comment.sh: HTTP %s for %s\n%s\n' "$status" "$key" "$respbody" >&2
  exit 1
fi

rm -f "$PAYLOAD_FILE"
echo "OK: comment added to ${key}"
