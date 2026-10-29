#!/usr/bin/env bash
# Query Graylog's legacy universal search API (relative OR absolute window). Confirmed
# working endpoint for this instance (Graylog 4.2.6) -- the newer "Search Scripting API"
# (/api/search/messages) 404s here, doesn't exist on this version.
# Usage: graylog-search.sh <lucene-query> <window> [stream-id] [limit] [fields-csv]
#   <window> = seconds (relative-to-now, e.g. 300)  OR  <from>..<to> ISO-8601 UTC
#              (absolute, e.g. 2026-09-09T10:54:40.000Z..2026-09-09T10:55:20.000Z)
#
# The absolute form exists because "what happened around 06:05 UTC this morning" is
# unanswerable with a relative range once it is hours later, and the skill used to tell
# sessions to hand-roll `curl -u "$GRAYLOG_PAT:token" .../universal/absolute` for it. That
# put the token on the command line, which unanalyzable-script-gate.sh then blocked; its
# fallback remedy ("Write it to a script file") produced a credential-bearing scratch
# script, which drew a manual approval prompt of its own -- twice in one session
# (093daf48, 2026-09-09). Keeping the window here keeps the token inside the script, which
# is the gate's tier-1 remedy and costs no prompt at all.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
# graylog.host decides WHICH COMPANY'S Graylog gets queried -- no safe default.
BASE_URL="$(hr_config_required '.graylog.host')" || exit 1

usage='usage: graylog-search.sh <lucene-query> <seconds|from..to> [stream-id] [limit] [fields-csv]'
query="${1:?$usage}"
window="${2:?$usage}"
stream_id="${3:-}"
limit="${4:-50}"
fields="${5:-}"

if [ -z "${GRAYLOG_PAT:-}" ]; then
  echo "GRAYLOG_PAT not set" >&2
  exit 1
fi

# Graylog's absolute endpoint wants yyyy-MM-ddTHH:mm:ss.SSSZ and 400s on a bare
# seconds-precision stamp, which is the natural thing to type -- fill the millis in.
iso_ms() {
  case "$1" in
    *.*Z) printf '%s' "$1" ;;
    *Z)   printf '%s' "${1%Z}.000Z" ;;
    *)    printf '%s' "$1" ;;
  esac
}

case "$window" in
  *[!0-9]*)
    case "$window" in
      *..*) : ;;
      *) echo "$usage" >&2; echo "window must be seconds or <from>..<to>: got '$window'" >&2; exit 1 ;;
    esac
    from="$(iso_ms "${window%%..*}")"
    to="$(iso_ms "${window##*..}")"
    endpoint="absolute"
    range_args=(--data-urlencode "from=${from}" --data-urlencode "to=${to}")
    ;;
  *)
    endpoint="relative"
    range_args=(--data-urlencode "range=${window}")
    ;;
esac

# Known issues live in the DATA, not in a local list. Graylog carries a team-maintained
# `known_issue` field, and at error level it covers nearly everything: over the 7 days to
# 2026-09-15, 4814 of 4895 level:3 messages were tagged -- 81 untagged. An error sweep that
# does not use it spends its whole budget re-triaging the same handful of signatures, which
# is exactly what happened on the release/130.0.0 Staging sweep.
#
# So an error sweep splits automatically: tagged messages are SEGREGATED, never hidden --
# the count and the tags are always reported, because a tag like `PROJ-2321` means
# "known and tracked", not "benign". Opt out with GRAYLOG_NO_SUPPRESS=1.
suppress=0
case "${GRAYLOG_NO_SUPPRESS:-}" in
  1) ;;
  *)
    case "$query" in
      *known_issue*) ;;
      *level:3*|*"level:<=3"*|*"level:[0 TO 3]"*) suppress=1 ;;
    esac
    ;;
esac

# An `application:` value not in APP-NAME-MAPPING.md is flagged in the output. A wrong name
# returns 0 silently: resultsprocessor searched without its `-api` suffix read as "doesn't
# log to Graylog" and went into a Jira comment (PROJ-15832, 2026-10-21).
unknown_apps=""
map="$(dirname "$0")/../APP-NAME-MAPPING.md"
if [ -f "$map" ]; then
  known_apps="$(grep -oE '`[^`]+`' "$map" | tr -d '`')"
  for a in $(printf '%s' "$query" | grep -oE 'application:(\([^)]*\)|"[^"]*"|[^ )]+)' \
             | sed -E 's/^application://; s/[()"]/ /g; s/(^| )(OR|AND|NOT)( |$)/ /g'); do
    case "$a" in *'*'*) continue ;; esac
    printf '%s\n' "$known_apps" | grep -qxF -- "$a" || unknown_apps="${unknown_apps:+$unknown_apps, }$a"
  done
fi

build_args() { # build_args <query> <limit> <fields>
  args=(-sS -m 30 -G -u "${GRAYLOG_PAT}:token"
    "${BASE_URL}/api/search/universal/${endpoint}"
    --data-urlencode "query=$1"
    "${range_args[@]}"
    --data-urlencode "limit=$2"
    -H "Accept: application/json")
  [ -n "${stream_id}" ] && args+=(--data-urlencode "filter=streams:${stream_id}")
  [ -n "$3" ] && args+=(--data-urlencode "fields=$3")
}

# The non-prod catch-all is NOT a known issue: `Suppress non prod alerts` is a Slack-alert
# rule on nearly every Staging/QA error (191 of 200 sampled, 2026-10-15), so filing it as
# suppressed made the untagged count ~0 by construction and hid 9h of broker failures from
# release-preflight (PROJ-15801, 2026-10-14). Counted on its own, by source, and
# surfaced as `catchall_tagged` plus a `warning` -- never folded into known_issue_suppressed.
CATCHALL='Suppress non prod alerts'
if [ "$suppress" = "1" ]; then
  build_args "(${query}) AND _exists_:known_issue AND NOT known_issue:\"${CATCHALL}\"" 200 "known_issue"
  tagged="$(curl "${args[@]}")"
  known="$(printf '%s' "$tagged" | jq -c '{
      count: .total_results,
      tags: ([.messages[]? | (.message.known_issue // "(unlabelled)")]
             | group_by(.) | map({key: .[0], value: length}) | from_entries)
    }' 2>/dev/null || printf '{"count":null,"tags":{}}')"
  build_args "(${query}) AND known_issue:\"${CATCHALL}\"" 200 "source"
  catchall="$(curl "${args[@]}" | jq -c '{
      count: .total_results,
      by_source: ([.messages[]? | (.message.source // "?")]
                  | group_by(.) | map({key: .[0], value: length}) | from_entries)
    }' 2>/dev/null || printf '{"count":null,"by_source":{}}')"
  query="(${query}) AND NOT _exists_:known_issue"
fi

build_args "$query" "$limit" "$fields"

# Trim the raw response (built_query = the whole rewritten ES query, used_indices = 31
# index objects -- several thousand tokens per call, before any messages) down to what a
# caller actually reads, same pattern as ama-jira-api's read scripts. Non-JSON (error
# body) passes through untouched so failures stay diagnosable.
raw="$(curl "${args[@]}")" || { printf '%s\n' "$raw"; exit 1; }
# index kept per hit (merged flat) -- SKILL.md's single-message deep link needs it.
# `known_issue_suppressed` present => this was an error sweep and tagged messages were
# split out. total_results is then the NEW/untriaged count, which is the number to act on.
printf '%s' "$raw" \
  | jq --argjson known "${known:-null}" --argjson ca "${catchall:-null}" --arg ua "$unknown_apps" \
      '{total_results, messages: [.messages[]? | .message + {index}]}
       + (if $ua == "" then {} else {app_name_warning: ("application value(s) not in APP-NAME-MAPPING.md: \($ua) -- a wrong name returns 0 silently; check the mapping before reading 0 as \"not logged\"")} end)
       + (if $known == null then {} else {known_issue_suppressed: $known} end)
       + (if $ca == null then {} else {catchall_tagged: $ca}
            + (if ($ca.count // 0) > 0 then {warning: ("\($ca.count) error(s) carry the non-prod catch-all tag -- triaged by nobody; see catchall_tagged.by_source")} else {} end) end)' 2>/dev/null \
  || printf '%s\n' "$raw"
