#!/usr/bin/env bash
# Plans a support-notification triage run. Emits the search window, configured senders,
# already-triaged Gmail message ids, and -- unique to this monitor -- today's cadence
# classification. Claude (the skill) does the actual reading/judging via Gmail MCP;
# Gmail is MCP-only, no bash can read it, so this script only plans (same split as
# embs-notices-plan.sh).
#
# Cadence source: ~/.claude/.embs-reminders-synced (written by ama-embs-reminders),
# TSV `<processing-date>\t<GNM|FNM_FHL>`. No Google Calendar call needed -- that file
# already IS the processing-day table, locally, for free.
#
#   processing -- today has a row               -> act every hour
#   post1/post2 -- today-1 / today-2 has a row   -> act every postProcessingEveryHours
#   normal     -- neither                        -> act at dailyCheckHour every day, PLUS
#                  weekendMorningCheckHour on Sat/Sun, PLUS a one-shot catch-up tick if
#                  no successful run is recorded for today by the time any designated
#                  hour for today has passed (missed-window guard -- a machine asleep
#                  at the exact designated hour must not silently lose the whole day).
#
# Coverage-cliff guard: .embs-reminders-synced only covers dates already synced
# (tracked by ~/.claude/.embs-coverage, a bare YYYY-MM). Once the current month reaches
# that ceiling, "no row for today" stops meaning "not a processing day" and starts
# meaning "unknown" -- silently treating it as `normal` would downgrade a real
# processing day from 24 checks/day to 1. So past the cliff this exits non-zero with
# SCHEDULE-UNRESOLVED instead of guessing; the caller fails loud rather than falling
# through.
#
# Usage: support-notices-plan.sh
# Output: one JSON object on stdout, or SCHEDULE-UNRESOLVED on stderr + exit 1.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

# Decides WHOSE mailbox gets read and WHERE findings land -- silent defaults here are
# the bug, not a convenience (same reasoning as hr_config_required's own comment).
SENDERS_JSON="$(jq -c '.supportNotices.senders // empty' < "$HR_CONFIG_FILE" 2>/dev/null | sed 's/\r$//')"
if [ -z "$SENDERS_JSON" ] || [ "$SENDERS_JSON" = "[]" ]; then
  printf '.supportNotices.senders not configured -- run /harness-setup\n' >&2
  exit 1
fi
MODE="$(hr_config_required '.supportNotices.mode')" || exit 1
ACK_TARGET="$(hr_config_required ".supportNotices.targets.$MODE.ack")" || exit 1
ETL_TARGET="$(hr_config_required ".supportNotices.targets.$MODE.etlOwner")" || exit 1

LOOKBACK_H="$(hr_config '.supportNotices.lookbackHours' 36)"
TZ_CFG="$(hr_config '.supportNotices.timezone' 'Africa/Johannesburg')"
DAILY_HOUR="$(hr_config '.supportNotices.dailyCheckHour' 17)"
WEEKEND_HOUR="$(hr_config '.supportNotices.weekendMorningCheckHour' 9)"
POST_DAYS="$(hr_config '.supportNotices.postProcessingDays' 2)"
POST_EVERY="$(hr_config '.supportNotices.postProcessingEveryHours' 3)"
CREATE_TICKETS="$(hr_config '.supportNotices.createTickets' 'false')"
AUTO_FIX="$(hr_config '.supportNotices.autoFix' 'false')"
AUTO_HOTFIX="$(hr_config '.supportNotices.autoHotfix' 'false')"

SEEN="$(hstate notices .support-notices-seen)"
LASTRUN="$(hstate notices .support-notices-lastrun)"
LASTDAY="$(hstate notices .support-notices-lastday)"
touch "$SEEN" "$LASTDAY"

SYNCED="$(hstate notices .embs-reminders-synced)"
COVERAGE="$(hstate notices .embs-coverage)"
touch "$SYNCED"

today_ymd="$(TZ="$TZ_CFG" date +%F)" || { printf 'support-notices-plan.sh: date arithmetic failed (need GNU date)\n' >&2; exit 1; }
this_month="${today_ymd%-*}"

# Coverage-cliff guard, checked BEFORE classification: if this month is at or past the
# last month .embs-reminders-synced actually covers, and today has no row, we cannot
# tell processing from normal -- refuse rather than guess.
# cat (not a bare < redirect): a missing file's redirect error prints BEFORE 2>/dev/null
# applies, polluting stderr on any machine that hasn't run ama-embs-reminders yet.
coverage="$(cat "$COVERAGE" 2>/dev/null | tr -d ' \r\n' || true)"
has_today_row=0
grep -qF -- "$(printf '%s\t' "$today_ymd")" "$SYNCED" 2>/dev/null && has_today_row=1

if [ "$has_today_row" -eq 0 ] && [ -n "$coverage" ] && ! [ "$this_month" \< "$coverage" ]; then
  printf 'SCHEDULE-UNRESOLVED: .embs-coverage is %s, current month %s is at/past it, and today (%s) has no row in .embs-reminders-synced -- cannot tell a processing day from a normal one. Run ama-embs-reminders to extend coverage.\n' \
    "$coverage" "$this_month" "$today_ymd" >&2
  exit 1
fi

day="normal"
if [ "$has_today_row" -eq 1 ]; then
  day="processing"
else
  d=1
  while [ "$d" -le "$POST_DAYS" ]; do
    check_ymd="$(TZ="$TZ_CFG" date -d "$today_ymd -$d day" +%F 2>/dev/null)" || check_ymd=""
    if [ -n "$check_ymd" ] && grep -qF -- "$(printf '%s\t' "$check_ymd")" "$SYNCED" 2>/dev/null; then
      day="post$d"
      break
    fi
    d=$((d + 1))
  done
fi

hour="$(TZ="$TZ_CFG" date +%H)" || { printf 'support-notices-plan.sh: hour read failed\n' >&2; exit 1; }
hour=$((10#$hour))  # strip any leading zero so arithmetic doesn't read it as octal
dow="$(TZ="$TZ_CFG" date +%u)" || { printf 'support-notices-plan.sh: dow read failed\n' >&2; exit 1; }
is_weekend=0; [ "$dow" -ge 6 ] && is_weekend=1   # 6=Sat, 7=Sun

act="no"; cadence="none"
case "$day" in
  processing)
    cadence="hourly"; act="yes"
    ;;
  post1|post2)
    cadence="${POST_EVERY}h"
    [ "$((hour % POST_EVERY))" -eq 0 ] && act="yes"
    ;;
  normal)
    cadence="daily@${DAILY_HOUR}"
    [ "$is_weekend" -eq 1 ] && cadence="daily@${DAILY_HOUR}+weekend@${WEEKEND_HOUR}"
    # Scheduled ticks: the designated hour(s) for today, independent of each other.
    if [ "$hour" -eq "$DAILY_HOUR" ]; then
      act="yes"
    elif [ "$is_weekend" -eq 1 ] && [ "$hour" -eq "$WEEKEND_HOUR" ]; then
      act="yes"
    fi
    # Catch-up: no successful run recorded for today yet, and today's earliest
    # designated hour has already passed -- a machine asleep at the exact designated
    # hour must not silently lose the whole day. Never SUPPRESSES a scheduled tick
    # above (both can independently set act=yes on the same day) -- it only ADDS one.
    earliest_hour="$DAILY_HOUR"
    [ "$is_weekend" -eq 1 ] && [ "$WEEKEND_HOUR" -lt "$earliest_hour" ] && earliest_hour="$WEEKEND_HOUR"
    lastday="$(tr -d ' \r\n' < "$LASTDAY" 2>/dev/null || true)"
    if [ "$lastday" != "$today_ymd" ] && [ "$hour" -gt "$earliest_hour" ]; then
      act="yes"
      cadence="${cadence}+catchup"
    fi
    ;;
esac

# Gmail's after: takes YYYY/MM/DD -- hours don't apply to the query, only to gating
# whether this tick acts at all (above). Use a floor date, not a timestamp.
since="$(TZ="$TZ_CFG" date -d "$LOOKBACK_H hours ago" +%Y/%m/%d 2>/dev/null)" || since=""
[ -n "$since" ] || { printf 'support-notices-plan.sh: lookback date arithmetic failed\n' >&2; exit 1; }

# field 1 of the seen file is the Gmail message id.
seen_ids="$(cut -f1 "$SEEN" | sed '/^$/d' | jq -Rsc 'split("\n") | map(select(length>0))' 2>/dev/null)"
[ -n "$seen_ids" ] || seen_ids='[]'

# Rows whose disposition column is `pending` -- re-emitted every run so an unanswered
# exception can't be forgotten (same rule as the sibling skills' pendingIds).
pending_ids="$(awk -F'\t' '$4=="pending"{print $1}' "$SEEN" | jq -Rsc 'split("\n") | map(select(length>0))' 2>/dev/null)"
[ -n "$pending_ids" ] || pending_ids='[]'

jq -nc \
  --arg since "$since" \
  --arg today "$today_ymd" \
  --arg day "$day" \
  --arg cadence "$cadence" \
  --arg act "$act" \
  --arg mode "$MODE" \
  --arg ackTarget "$ACK_TARGET" \
  --arg etlTarget "$ETL_TARGET" \
  --argjson senders "$SENDERS_JSON" \
  --argjson seenIds "$seen_ids" \
  --argjson pendingIds "$pending_ids" \
  --argjson createTickets "$CREATE_TICKETS" \
  --argjson autoFix "$AUTO_FIX" \
  --argjson autoHotfix "$AUTO_HOTFIX" \
  '{since:$since, today:$today, day:$day, cadence:$cadence, act:$act, mode:$mode,
    ackTarget:$ackTarget, etlOwnerTarget:$etlTarget, senders:$senders,
    seenIds:$seenIds, seenCount:($seenIds|length),
    pendingIds:$pendingIds, pendingCount:($pendingIds|length),
    dials:{createTickets:$createTickets, autoFix:$autoFix, autoHotfix:$autoHotfix}}' \
  | sed 's/\r$//'
