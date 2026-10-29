#!/usr/bin/env bash
# Direct Jira REST read, replacing a field-scoped searchJiraIssuesUsingJql call. See
# jira-get-transitions.sh's header for why this exists (MCP results can't be
# post-filtered; a script piping through jq can).
# Usage: jira-search.sh <jql> <fields-csv> [maxResults]
# fields-csv: comma-separated top-level field names, e.g. "summary,status".
# One line per matching issue: "<key>\t<field1>\t<field2>\t...", nested fields
# (assignee, status) print their .name/.displayName, not the full object.
#
# maxResults is a CEILING on issues returned, not a page size. /search/jql caps its own
# page at 100 no matter what is asked for, and used to drop the rest silently -- a
# 120-key query asked for 200 returned 100 with no truncation signal, so a backlog
# pickup lost the tail and looked complete. Now paged via nextPageToken until the
# ceiling is reached or the server says isLast. Callers that already chunk at 100 by
# hand (backlog-prune-resolved.sh, backlog-candidates.sh) are unaffected -- a ceiling
# below one page still returns one page.
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

SERVER_PAGE_CAP=100
collected=0
page_token=""
first_page=1

while [ "$collected" -lt "$max_results" ]; do
  want=$(( max_results - collected ))
  [ "$want" -gt "$SERVER_PAGE_CAP" ] && want="$SERVER_PAGE_CAP"

  payload="$(jq -cn --arg jql "$jql" --arg fields "$fields" --argjson max "$want" \
    --arg token "$page_token" '
    {jql: $jql, fields: ($fields | split(",")), maxResults: $max}
    + (if $token == "" then {} else {nextPageToken: $token} end)
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

  n="$(printf '%s' "$body" | jq '.issues | length')"

  # The /search/jql endpoint returns 200 + empty for a syntactically-valid query naming a
  # NONEXISTENT value (e.g. a fixVersion that doesn't exist) -- indistinguishable from a
  # genuinely empty result. On zero results only, re-check the JQL via strict parse and
  # fail loud if it flags anything, instead of reporting a silent false "no tickets match".
  # FIRST page only -- a later page coming back empty is exhaustion, not a bad query.
  if [ "$first_page" -eq 1 ] && [ "$n" -eq 0 ]; then
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
        if type == "object" then (.name // .displayName // .key // (tostring)) else tostring end]
    | join("\t")
  '

  collected=$(( collected + n ))
  first_page=0

  [ "$n" -eq 0 ] && break
  [ "$(printf '%s' "$body" | jq -r '.isLast')" = "true" ] && break
  page_token="$(printf '%s' "$body" | jq -r '.nextPageToken // empty')"
  [ -n "$page_token" ] || break
done

# Hitting the ceiling exactly is the one case where the caller cannot tell a complete
# result from a truncated one -- say so on stderr rather than let it read as complete.
if [ "$collected" -ge "$max_results" ] && [ -n "${page_token:-}" ]; then
  printf 'jira-search.sh: ceiling %s reached; more issues match.\n' "$max_results" >&2
fi
