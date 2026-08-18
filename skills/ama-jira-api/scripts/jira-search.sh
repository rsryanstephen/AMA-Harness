#!/usr/bin/env bash
# Direct Jira REST read, replacing a field-scoped searchJiraIssuesUsingJql call. See
# jira-get-transitions.sh's header for why this exists (MCP results can't be
# post-filtered; a script piping through jq can).
# Usage: jira-search.sh <jql> <fields-csv> [maxResults]
# fields-csv: comma-separated top-level field names, e.g. "summary,status".
# One line per matching issue: "<key>\t<field1>\t<field2>\t...", nested fields
# (assignee, status) print their .name/.displayName, not the full object.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

jql="${1:?usage: jira-search.sh <jql> <fields-csv> [maxResults]}"
fields="${2:?usage: jira-search.sh <jql> <fields-csv> [maxResults]}"
max_results="${3:-50}"

if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

payload="$(jq -cn --arg jql "$jql" --arg fields "$fields" --argjson max "$max_results" '
  {jql: $jql, fields: ($fields | split(",")), maxResults: $max}
')"

resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X POST -H "Content-Type: application/json" -d "$payload" \
  "https://${HOST}/rest/api/3/search/jql")"
status="${resp##*$'\n'}"
body="${resp%$'\n'*}"

if [ "$status" != "200" ]; then
  printf 'jira-search.sh: HTTP %s\n%s\n' "$status" "$body" >&2
  exit 1
fi

# The /search/jql endpoint returns 200 + empty for a syntactically-valid query naming a
# NONEXISTENT value (e.g. a fixVersion that doesn't exist) -- indistinguishable from a
# genuinely empty result. On zero results only, re-check the JQL via strict parse and
# fail loud if it flags anything, instead of reporting a silent false "no tickets match".
if [ "$(printf '%s' "$body" | jq '.issues | length')" -eq 0 ]; then
  verr="$(curl -s -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
    -X POST -H "Content-Type: application/json" \
    -d "$(jq -cn --arg q "$jql" '{queries: [$q]}')" \
    "https://${HOST}/rest/api/3/jql/parse?validation=strict" \
    | jq -r '.queries[0].errors // [] | .[]')"
  if [ -n "$verr" ]; then
    printf 'jira-search.sh: 0 results, and strict JQL validation reports:\n%s\n' "$verr" >&2
    exit 1
  fi
fi

printf '%s' "$body" | jq -r --arg fields "$fields" '
  ($fields | split(",")) as $wanted
  | .issues[] | .key as $k | .fields as $f
  | [$k] + [$wanted[] | ($f[.] // "") |
      if type == "object" then (.name // .displayName // (tostring)) else tostring end]
  | join("\t")
'
