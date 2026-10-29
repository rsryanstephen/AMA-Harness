#!/usr/bin/env bash
# Direct Jira REST write, replacing addCommentToJiraIssue. See jira-create-issue.sh's
# header for why the payload comes from a fixed file, never a command-line argument --
# doubly true here given comment text is free-form prose (non-ASCII em-dashes etc.
# already confirmed to corrupt as literal bash arguments, per ama-bitbucket-api/SKILL.md).
# Payload file shape: {"body": "plain text comment"}
# Usage: jira-add-comment.sh <ticket-key>
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

key="${1:?usage: jira-add-comment.sh <ticket-key>}"

PAYLOAD_FILE="${JIRA_PAYLOAD_FILE:?set JIRA_PAYLOAD_FILE=<per-call path> -- the shared default was retired 2026-09-07 (concurrent sessions clobbered it), see ama-jira-api SKILL.md}"
if [ ! -f "$PAYLOAD_FILE" ]; then
  echo "jira-add-comment.sh: $PAYLOAD_FILE not found -- write the payload there first (Write tool, never shell)" >&2
  exit 1
fi
if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

# v2 endpoint, plain-string body -- same as jira-edit-comment.sh and jira-create-issue.sh.
# Until 2026-10-05 this wrapped the whole body in ONE v3 ADF paragraph, so the wiki markup
# every skill writes (h3., *bold*, {{code}}, bullets) rendered as literal characters in a
# single block -- every harness comment the tester read (confirmed on PROJ-15416). v2
# renders wiki markup; v3 would need a real markup->ADF conversion.
BODY_FILE="$(mktemp)"
jq -c '{body: .body}' "$PAYLOAD_FILE" > "$BODY_FILE"

# -d @file, never -d "$var" -- a bash-variable-held body corrupts crossing the
# MSYS->Win32 boundary into curl.exe (confirmed live on jira-append-description.sh:
# identical JSON via -d @file got 204, the same content via -d "$body" 400'd with
# "error parsing JSON" -- reproducible, tied to specific byte content, not size alone).
resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X POST -H "Content-Type: application/json" -d "@$BODY_FILE" \
  "https://${HOST}/rest/api/2/issue/${key}/comment")"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"

rm -f "$BODY_FILE"

if [ "$status" != "200" ] && [ "$status" != "201" ]; then
  printf 'jira-add-comment.sh: HTTP %s for %s\n%s\n' "$status" "$key" "$respbody" >&2
  exit 1
fi

rm -f "$PAYLOAD_FILE"
echo "OK: comment added to ${key}"
