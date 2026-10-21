#!/usr/bin/env bash
# Reassemble a multi-part SQL log line from Graylog.
# Usage: graylog-reconstruct-sql.sh <application> <window> [prefix] [env]
#   window  : seconds relative, or <from>..<to> ISO-8601 UTC (same as graylog-search.sh)
#   prefix  : default "ExecuteAsync::SQL" (search-api); also ExecuteTopRowAsync::SQL,
#             ExecuteRowCountAsync::SQL, BuildQueryForExport::SQL (resultsprocessor)
#
# search-api splits long queries into "ExecuteAsync::SQL\n\nSQL Part N:\n\n<chunk>" messages
# at near-identical timestamps. The skill used to say: fetch ALL of them, sort by Part number
# (not timestamp -- parts tie), strip each prefix, concatenate. That is a sort and a join
# the agent was doing by eye, and the doc records it going wrong. Uses full_message --
# GELF's short `message` truncates around 500 chars.
#
# Parts of DIFFERENT queries in one window are separated by their timestamp second; each
# group prints under a "=== <timestamp> (N parts)" header, newest last.
set -uo pipefail
APP="${1:?usage: graylog-reconstruct-sql.sh <application> <window> [prefix]}"
WINDOW="${2:?usage: graylog-reconstruct-sql.sh <application> <window> [prefix]}"
PREFIX="${3:-ExecuteAsync::SQL}"
# env (optional 4th): qa|staging|production. One application name spans every environment --
# without it a window mixes QA and Staging SQL. GRAYLOG_RECON_LIMIT raises the 200-message cap.
ENVQ=""; [ -n "${4:-}" ] && ENVQ="environment:$4 AND "

GS="$(dirname "$0")/graylog-search.sh"
raw="$(bash "$GS" "${ENVQ}application:$APP AND \"$PREFIX\"" "$WINDOW" "" "${GRAYLOG_RECON_LIMIT:-200}" "timestamp,full_message")"
printf '%s' "$raw" | jq -e '.messages' >/dev/null 2>&1 || { printf '%s\n' "$raw"; exit 1; }

# Distinct queries land in the SAME second routinely, so grouping by timestamp merges them.
# Parts of one query are consecutive in time and their Part numbers count up from 1; a new
# query starts wherever the Part number resets (or the message carries no Part marker).
printf '%s' "$raw" | jq -r --arg p "$PREFIX" '
  [.messages[]
    | . as $m
    | ($m.full_message // "") as $fm
    | (($fm | capture("SQL Part (?<n>[0-9]+):") | .n | tonumber) // 1) as $part
    | ($fm | sub("^[\\s\\S]*?SQL Part [0-9]+:\\s*"; "") | sub("^" + $p + "\\s*"; "") | sub("^SQL:\\s*"; "")) as $body
    | {ts: $m.timestamp, part: $part, body: $body}]
  | sort_by(.ts, .part)
  | reduce .[] as $x ([]; if $x.part <= 1 or length == 0 then . + [[$x]] else .[:-1] + [(.[-1] + [$x])] end)
  | .[]
  | "=== \(.[0].ts[0:23]) (\(length) part(s), from part \(.[0].part))",
    (map(.body) | join("")), ""'
