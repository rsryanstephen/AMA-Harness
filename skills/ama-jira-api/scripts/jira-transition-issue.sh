#!/usr/bin/env bash
# Direct Jira REST write, replacing transitionJiraIssue. Get the transition ID first
# via jira-get-transitions.sh (never hardcode -- per-ticket, see commit-ticket/SKILL.md).
# No payload file needed for a bare transition; if the target transition requires
# fields (see commit-ticket's "missing required information" case), write them to the
# same fixed payload file jira-create-issue.sh/jira-edit-issue.sh use --
# {"fields": {...}} -- picked up here only if that file exists.
# Usage: jira-transition-issue.sh <ticket-key> <transition-id>
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

key="${1:?usage: jira-transition-issue.sh <ticket-key> <transition-id>}"
transition_id="${2:?usage: jira-transition-issue.sh <ticket-key> <transition-id>}"

if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

PAYLOAD_FILE="$HOME/.claude/.jira-write-payload.json"
BODY_FILE="$(mktemp)"
if [ -f "$PAYLOAD_FILE" ]; then
  jq -c --arg id "$transition_id" '{transition: {id: $id}, fields: (.fields // {})}' "$PAYLOAD_FILE" > "$BODY_FILE"
else
  jq -cn --arg id "$transition_id" '{transition: {id: $id}}' > "$BODY_FILE"
fi

# -d @file, never -d "$var" -- a bash-variable-held body corrupts crossing the
# MSYS->Win32 boundary into curl.exe (confirmed live on jira-append-description.sh:
# identical JSON via -d @file got 204, the same content via -d "$body" 400'd with
# "error parsing JSON" -- reproducible, tied to specific byte content, not size alone).
resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X POST -H "Content-Type: application/json" -d "@$BODY_FILE" \
  "https://${HOST}/rest/api/3/issue/${key}/transitions")"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"

rm -f "$BODY_FILE"

if [ "$status" != "204" ]; then
  printf 'jira-transition-issue.sh: HTTP %s for %s -> transition %s\n%s\n' "$status" "$key" "$transition_id" "$respbody" >&2
  exit 1
fi

# Payload consumed only on success -- a failed write keeps it for retry without rewrite.
[ -f "$PAYLOAD_FILE" ] && rm -f "$PAYLOAD_FILE"
echo "OK: ${key} transitioned (id ${transition_id})"
