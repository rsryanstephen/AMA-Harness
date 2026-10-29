#!/usr/bin/env bash
# Rewrite an existing issue's summary and/or description as WIKI MARKUP, via /rest/api/2.
#
# Why this exists next to jira-edit-issue.sh: that script (and jira-append-description.sh)
# POST to /rest/api/3, where `description` must be ADF -- wiki markup sent there renders as
# literal "h2." text on screen. jira-create-issue.sh already uses v2 for exactly this reason,
# so a ticket created with wiki markup could not be EDITED without losing its formatting.
# Same fixed-payload-file convention as every other write script here (gates read that file).
#
# Payload file shape: {"summary": "...", "description": "wiki markup"}  -- either key optional.
# Usage: jira-edit-description.sh <ticket-key>
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

key="${1:?usage: jira-edit-description.sh <ticket-key>}"

PAYLOAD_FILE="${JIRA_PAYLOAD_FILE:?set JIRA_PAYLOAD_FILE=<per-call path> -- the shared default was retired 2026-09-07 (concurrent sessions clobbered it), see ama-jira-api SKILL.md}"
if [ ! -f "$PAYLOAD_FILE" ]; then
  echo "jira-edit-description.sh: $PAYLOAD_FILE not found -- write the payload there first" >&2
  exit 1
fi
if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

BODY_FILE="$(mktemp)"
jq -c '{fields: ((if .summary then {summary: .summary} else {} end)
               + (if .description then {description: .description} else {} end))}' \
  "$PAYLOAD_FILE" > "$BODY_FILE"

if [ "$(jq -r '.fields | length' "$BODY_FILE")" = "0" ]; then
  echo "jira-edit-description.sh: payload has neither summary nor description" >&2
  rm -f "$BODY_FILE"; exit 1
fi

# -d @file, never -d "$var" -- see jira-create-issue.sh's header for the MSYS->Win32 corruption.
resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X PUT -H "Content-Type: application/json" -d "@$BODY_FILE" \
  "https://${HOST}/rest/api/2/issue/${key}")"
status="${resp##*$'\n'}"
rm -f "$BODY_FILE"

case "$status" in
  204|200) echo "OK: $key updated (v2, wiki markup preserved)" ;;
  *) echo "FAILED ($status): ${resp%$'\n'*}" >&2; exit 1 ;;
esac
