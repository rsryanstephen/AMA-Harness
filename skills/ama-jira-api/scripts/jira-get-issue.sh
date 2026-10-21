#!/usr/bin/env bash
# Direct Jira REST read, replacing a field-scoped getJiraIssue call. See
# jira-get-transitions.sh's header for why this exists (MCP results can't be
# post-filtered; a script piping through jq can).
# Usage: jira-get-issue.sh <ticket-key> <fields-csv>
# fields-csv: comma-separated top-level field names, e.g. "summary,status,assignee".
# Each requested field is printed tab-separated, one line, in the order given --
# nested fields (assignee, status) print their .name/.displayName, not the full object.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

key="${1:?usage: jira-get-issue.sh <ticket-key> <fields-csv>}"
fields="${2:?usage: jira-get-issue.sh <ticket-key> <fields-csv>}"

if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" -G \
  --data-urlencode "fields=${fields}" \
  "https://${HOST}/rest/api/3/issue/${key}")"
status="${resp##*$'\n'}"
body="${resp%$'\n'*}"

if [ "$status" != "200" ]; then
  printf 'jira-get-issue.sh: HTTP %s for %s\n%s\n' "$status" "$key" "$body" >&2
  exit 1
fi

# Flatten each requested field to a scalar: object fields print .name or .displayName
# (whichever exists), everything else prints as-is.
printf '%s' "$body" | jq -r --arg fields "$fields" '
  ($fields | split(",")) as $wanted
  | .fields as $f
  | [$wanted[] | ($f[.] // "") |
      if type == "object" then (.name // .displayName // (tostring)) else tostring end]
  | join("\t")
'
