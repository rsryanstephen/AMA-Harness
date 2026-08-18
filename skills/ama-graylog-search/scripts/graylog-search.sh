#!/usr/bin/env bash
# Query Graylog's legacy universal/relative search API. Confirmed working endpoint for
# this instance (Graylog 4.2.6) -- the newer "Search Scripting API" (/api/search/messages)
# 404s here, doesn't exist on this version.
# Usage: graylog-search.sh <lucene-query> <range-seconds> [stream-id] [limit] [fields-csv]
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
# graylog.host decides WHICH COMPANY'S Graylog gets queried -- no safe default.
BASE_URL="$(hr_config_required '.graylog.host')" || exit 1

query="${1:?usage: graylog-search.sh <lucene-query> <range-seconds> [stream-id] [limit] [fields-csv]}"
range="${2:?usage: graylog-search.sh <lucene-query> <range-seconds> [stream-id] [limit] [fields-csv]}"
stream_id="${3:-}"
limit="${4:-50}"
fields="${5:-}"

if [ -z "${GRAYLOG_PAT:-}" ]; then
  echo "GRAYLOG_PAT not set" >&2
  exit 1
fi

args=(-s -m 30 -G -u "${GRAYLOG_PAT}:token"
  "${BASE_URL}/api/search/universal/relative"
  --data-urlencode "query=${query}"
  --data-urlencode "range=${range}"
  --data-urlencode "limit=${limit}"
  -H "Accept: application/json")

[ -n "${stream_id}" ] && args+=(--data-urlencode "filter=streams:${stream_id}")
[ -n "${fields}" ] && args+=(--data-urlencode "fields=${fields}")

curl "${args[@]}"
