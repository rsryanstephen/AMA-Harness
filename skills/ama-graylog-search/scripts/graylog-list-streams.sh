#!/usr/bin/env bash
# List Graylog streams: <id> TAB <title>, for resolving a stream name to the id
# graylog-search.sh's filter param needs.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
# graylog.host decides WHICH COMPANY'S Graylog gets queried -- no safe default.
BASE_URL="$(hr_config_required '.graylog.host')" || exit 1

if [ -z "${GRAYLOG_PAT:-}" ]; then
  echo "GRAYLOG_PAT not set" >&2
  exit 1
fi

curl -s -m 30 -u "${GRAYLOG_PAT}:token" "${BASE_URL}/api/streams" -H "Accept: application/json" \
  | jq -r '.streams[] | "\(.id)\t\(.title)"'
