#!/usr/bin/env bash
# Fetch one Graylog pipeline rule by id OR by title (the UI shows titles, the API wants
# ids -- resolves via the list endpoint if what's given isn't a 24-hex-char id).
# Usage: graylog-rule-get.sh <rule-id|title>
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
BASE_URL="$(hr_config_required '.graylog.host')" || exit 1

want="${1:?usage: graylog-rule-get.sh <rule-id|title>}"

if [ -z "${GRAYLOG_PAT:-}" ]; then
  echo "GRAYLOG_PAT not set" >&2
  exit 1
fi

id="$want"
case "$want" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
  *)
    id="$(curl -s -m 30 -u "${GRAYLOG_PAT}:token" -H 'Accept: application/json' \
      "${BASE_URL}/api/system/pipelines/rule" \
      | jq -r --arg t "$want" 'map(select(.title == $t)) | .[0].id // empty')"
    [ -n "$id" ] || { echo "graylog-rule-get.sh: no rule titled '$want'" >&2; exit 1; }
    ;;
esac

curl -sS -m 30 -u "${GRAYLOG_PAT}:token" -H 'Accept: application/json' \
  "${BASE_URL}/api/system/pipelines/rule/${id}"
