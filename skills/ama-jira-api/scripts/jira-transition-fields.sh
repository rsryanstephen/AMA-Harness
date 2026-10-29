#!/usr/bin/env bash
# Show required fields per transition for a ticket (read-only).
set -uo pipefail
EMAIL="$(jq -r '.user.email' ~/.claude/harness-config.json)"
HOST="$(jq -r '.atlassian.cloudId' ~/.claude/harness-config.json)"
key="${1:?usage: jira-transition-fields.sh <key>}"
curl -s -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  "https://${HOST}/rest/api/3/issue/${key}/transitions?expand=transitions.fields" \
  | jq -r '.transitions[] | "\(.id)\t\(.name)\t" + ([.fields // {} | to_entries[] | select(.value.required==true) | .key + ":" + .value.name] | join(", "))'
