#!/usr/bin/env bash
# Direct Jira REST read, replacing getTransitionsForJiraIssue for the highest-call-count
# read in the harness (re-checked after every status-transition hop, per
# commit-ticket/SKILL.md's own rule). An MCP tool result is injected into context
# verbatim -- this trims to "id\tname" per transition instead of the full nested
# transition-object array, before anything reaches context. Confirmed real: field-
# scoping alone can't do this (avatarUrls/self/statusCategory are the API's own shape,
# not something the MCP server adds) -- only a script that pipes through jq first can.
# Usage: jira-get-transitions.sh <ticket-key>
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

key="${1:?usage: jira-get-transitions.sh <ticket-key>}"

if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

# Basic auth, NOT Bearer -- same gotcha ama-bitbucket-api/SKILL.md already documents
# for this same Atlassian API token type (starts ATAT, ~192 chars).
resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  "https://${HOST}/rest/api/3/issue/${key}/transitions")"
status="${resp##*$'\n'}"
body="${resp%$'\n'*}"

if [ "$status" != "200" ]; then
  printf 'jira-get-transitions.sh: HTTP %s for %s\n%s\n' "$status" "$key" "$body" >&2
  exit 1
fi

printf '%s' "$body" | jq -r '.transitions[] | "\(.id)\t\(.name)"'
