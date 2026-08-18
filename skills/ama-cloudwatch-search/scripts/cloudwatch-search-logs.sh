#!/usr/bin/env bash
# Search a CloudWatch log group directly -- use when Graylog has nothing (infra-level
# failures: container crash-loop, ECS task provisioning errors, missing env vars,
# ld.so/preload errors, Lambda cold-start/timeout/OOM -- these happen outside or before
# the app's own logging pipeline, so they never reach Graylog at all).
# Usage: cloudwatch-search-logs.sh <log-group-name> <since-utc> <until-utc> <filter-pattern-or-empty> <limit>
#   <since-utc>/<until-utc>: anything `date -d` accepts, e.g. "2026-07-21T08:00:00Z", "1 hour ago"
#   <filter-pattern-or-empty>: CloudWatch Logs filter pattern syntax (NOT Lucene) --
#     e.g. "ERROR", "?ERROR ?Exception" (OR), "" for everything in the window.
set -uo pipefail

LOG_GROUP="${1:?usage: cloudwatch-search-logs.sh <log-group-name> <since-utc> <until-utc> <filter-pattern-or-empty> <limit>}"
SINCE="${2:?usage: cloudwatch-search-logs.sh <log-group-name> <since-utc> <until-utc> <filter-pattern-or-empty> <limit>}"
UNTIL="${3:?usage: cloudwatch-search-logs.sh <log-group-name> <since-utc> <until-utc> <filter-pattern-or-empty> <limit>}"
FILTER="${4:-}"
LIMIT="${5:-50}"

# This file had zero config plumbing before wave 2 -- the console link hardcoded
# us-east-1 twice despite the actual query relying on the AWS CLI's own configured
# default region, which could differ. aws.region decides WHICH REGION'S console link
# is shown -- no safe default.
. "$HOME/.claude/hooks/lib-harness-repos.sh"
AWS_REGION="$(hr_config_required '.aws.region')" || exit 1

since_epoch_ms="$(( $(date -u -d "${SINCE}" +%s 2>/dev/null) * 1000 ))"
until_epoch_ms="$(( $(date -u -d "${UNTIL}" +%s 2>/dev/null) * 1000 ))"
if [ "${since_epoch_ms}" -eq 0 ] || [ "${until_epoch_ms}" -eq 0 ]; then
  echo "Couldn't parse SINCE/UNTIL: '${SINCE}' / '${UNTIL}'" >&2
  exit 1
fi

args=(--log-group-name "${LOG_GROUP}" --start-time "${since_epoch_ms}" --end-time "${until_epoch_ms}" --max-items "${LIMIT}")
[ -n "${FILTER}" ] && args+=(--filter-pattern "${FILTER}")

# MSYS_NO_PATHCONV=1: see cloudwatch-find-log-group.sh -- same git-bash path-mangling
# issue applies to --log-group-name here too.
# PYTHONUTF8=1: confirmed real bug -- aws-cli (a bundled Python exe) crashes with
# "'charmap' codec can't encode character" trying to write non-ASCII log content (seen:
# a plain "✓" in a log line) to Windows' console codepage, corrupting the captured
# output and making it fail JSON parsing below. PYTHONIOENCODING=utf-8 alone did NOT
# fix this (tested, still crashed) -- PYTHONUTF8=1 (Python's forceful UTF-8 mode
# override) did.
result="$(MSYS_NO_PATHCONV=1 PYTHONUTF8=1 aws logs filter-log-events "${args[@]}" 2>&1)"
if ! printf '%s' "${result}" | jq -e '.events' >/dev/null 2>&1; then
  echo "Query failed:" >&2
  echo "${result}" >&2
  exit 1
fi

encoded_group="$(printf '%s' "${LOG_GROUP}" | sed 's|/|%2F|g; s/\$/%24/g')"
echo "Log group: ${LOG_GROUP}"
echo "Console: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#logsV2:log-groups/log-group/${encoded_group}"
echo "---"
# jq on this machine has no gmtime/strftime -- convert timestamps with `date` instead.
# One compact JSON object per line (jq -c), not a bare tab-split -- confirmed real bug:
# log messages routinely contain embedded newlines (e.g. "...DONE\n"), which broke a
# tab-delimited `read` loop (the embedded newline was read as a row boundary, leaving
# the next "row" with no timestamp field at all and a bash arithmetic error). Compact
# JSON keeps embedded newlines escaped as literal `\n` within one line, safe to read
# one event per iteration regardless of what's in the message text.
printf '%s' "${result}" | jq -c '.events[]' | while IFS= read -r event; do
  ts="$(printf '%s' "${event}" | jq -r '.timestamp')"
  msg="$(printf '%s' "${event}" | jq -r '.message')"
  ts_human="$(date -u -d "@$(( ts / 1000 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  printf '%s %s\n' "${ts_human:-$ts}" "${msg}"
done
