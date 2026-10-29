#!/usr/bin/env bash
# Self-test for support-notices-record.sh's refusal gates and support-notices-plan.sh's
# day classification / hour gating / coverage-cliff guard. Modelled on
# aws-notices-selftest.sh: negative cases assert the REFUSAL MESSAGE, not just a nonzero
# exit ("command not found" is nonzero too).
#
# Runs entirely against throwaway copies -- never touches live state or the live config.
# CLAUDE_STATE_DIR isolates every hstate path in this script AND the scripts under test
# (hstate's absorb branch is disabled under an override -- lib-claude-paths.sh);
# HR_CONFIG_FILE (lib-harness-repos.sh test seam) points plan.sh's config reads at a temp
# COPY of the live config, which the hour-gating cases then edit freely. Replaces the old
# backup/truncate/restore machinery, whose non-atomic restore lost real ledger state when
# the Bash tool's 2m timeout SIGKILLed a run (2026-08-28) -- a hard kill now costs only a
# leaked temp dir.
#
# Usage: support-notices-selftest.sh
# Exit: 0 = all passed, 1 = at least one failure.
set -uo pipefail

# Detach stdin. Without this the suite HANGS FOREVER on the first refusal-path assertion
# ("add bad verdict refused") when run with an inherited stdin -- which is every run from a
# Claude session. It looks like a slow test, not a stuck one: no output, no error, and the
# Bash tool kills it at its timeout with exit 143, so the suite reads as "too slow to run"
# rather than "blocked on a read". Confirmed 2026-09-15: identical run with `</dev/null`
# finishes 28/0 in well under 4 minutes.
exec </dev/null

R="${BASH_SOURCE[0]%/*}/support-notices-record.sh"
P="${BASH_SOURCE[0]%/*}/support-notices-plan.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/support-notices-selftest.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
export CLAUDE_STATE_DIR="$SANDBOX/state"
export HR_CONFIG_FILE="$SANDBOX/harness-config.json"
cp "$HOME/.claude/harness-config.json" "$HR_CONFIG_FILE"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
SEEN="$(hstate notices .support-notices-seen)"
LASTDAY="$(hstate notices .support-notices-lastday)"
SYNCED="$(hstate notices .embs-reminders-synced)"
COVERAGE="$(hstate notices .embs-coverage)"
CONFIG="$HR_CONFIG_FILE"
: > "$SEEN"
# Healthy-machine baseline: coverage extends past this month, so the day-classification
# and hour-gating cases don't trip the coverage-cliff guard (tested on its own below).
date -d "$(date +%F) +2 month" +%Y-%m > "$COVERAGE"

pass=0; fail=0
chk() { # chk <desc> <0|expected-stderr-substring> <cmd...>
  local d="$1" want="$2"; shift 2
  local out got
  out="$("$@" 2>&1)"; got=$?
  if [ "$want" = 0 ]; then
    if [ "$got" = 0 ]; then pass=$((pass+1)); printf 'PASS  %s\n' "$d"
    else fail=$((fail+1)); printf 'FAIL  %s (wanted success, got exit %s: %s)\n' "$d" "$got" "$(printf '%s' "$out" | head -1)"; fi
  else
    if [ "$got" = 0 ]; then
      fail=$((fail+1)); printf 'FAIL  %s (expected refusal, but it SUCCEEDED)\n' "$d"
    elif printf '%s' "$out" | grep -qF -- "$want"; then
      pass=$((pass+1)); printf 'PASS  %s (refused as expected)\n' "$d"
    else
      fail=$((fail+1)); printf 'FAIL  %s (refused, but not for the expected reason -- wanted %s, got: %s)\n' "$d" "$want" "$(printf '%s' "$out" | head -1)"
    fi
  fi
}

# --- record.sh: add ---------------------------------------------------------------------
chk "add etl with no disposition refused"        "REFUSING etl row"        bash "$R" add M1 2026-08-21 etl - some-slug
chk "add app with no disposition refused"        "REFUSING app row"        bash "$R" add M2 2026-08-21 app - some-slug
chk "add no-action with empty slug refused"      "REFUSING no-action"      bash "$R" add M3 2026-08-21 no-action - ""
chk "add no-action with a slug succeeds"         0                         bash "$R" add M3 2026-08-21 no-action - routine-heartbeat
chk "add etl with ticket succeeds"               0                         bash "$R" add M4 2026-08-21 etl PROJ-99999 sample-etl-fail
chk "add app with pending succeeds"              0                         bash "$R" add M5 2026-08-21 app pending sql-error-pending-diagnosis
chk "add duplicate msg-id is idempotent"         0                         bash "$R" add M4 2026-08-21 etl PROJ-99999 sample-etl-fail
chk "add bad verdict refused"                    "verdict must be"         bash "$R" add M6 2026-08-21 bogus PROJ-1 x
chk "add bad date refused"                       "received must be"       bash "$R" add M7 21-08-2026 etl PROJ-1 x

# --- record.sh: settle -------------------------------------------------------------------
chk "settle pending app row to a ticket succeeds"  0                       bash "$R" settle M5 app PROJ-88888
chk "settle etl to bare dash refused"              "REFUSING: a settled"   bash "$R" settle M4 etl -
chk "settle no-action to bare dash succeeds"       0                       bash "$R" settle M3 no-action -
chk "settle missing row refused"                   "no seen row"          bash "$R" settle NOPE etl PROJ-1

# --- record.sh: finish --------------------------------------------------------------------
chk "finish with an uncovered candidate refused"  "REFUSING to update"     bash "$R" finish UNRECORDED-ID
chk "finish with every candidate covered succeeds" 0                      bash "$R" finish M3 M4 M5
chk "finish --none succeeds"                       0                      bash "$R" finish --none

# --- plan.sh: day classification (uses REAL today, so it stays correct as dates move) --
today="$(date +%F)"
d1="$(date -d "$today -1 day" +%F)"
d2="$(date -d "$today -2 day" +%F)"

: > "$SYNCED"
echo "$today	GNM" >> "$SYNCED"
out="$(bash "$P" 2>&1)"; day="$(printf '%s' "$out" | jq -r '.day' 2>/dev/null)"
[ "$day" = "processing" ] && { pass=$((pass+1)); printf 'PASS  today-row classifies processing\n'; } \
  || { fail=$((fail+1)); printf 'FAIL  today-row classifies %s (wanted processing): %s\n' "$day" "$out"; }

: > "$SYNCED"
echo "$d1	FNM_FHL" >> "$SYNCED"
out="$(bash "$P" 2>&1)"; day="$(printf '%s' "$out" | jq -r '.day' 2>/dev/null)"
[ "$day" = "post1" ] && { pass=$((pass+1)); printf 'PASS  yesterday-row classifies post1\n'; } \
  || { fail=$((fail+1)); printf 'FAIL  yesterday-row classifies %s (wanted post1): %s\n' "$day" "$out"; }

: > "$SYNCED"
echo "$d2	GNM" >> "$SYNCED"
out="$(bash "$P" 2>&1)"; day="$(printf '%s' "$out" | jq -r '.day' 2>/dev/null)"
[ "$day" = "post2" ] && { pass=$((pass+1)); printf 'PASS  2-days-ago-row classifies post2\n'; } \
  || { fail=$((fail+1)); printf 'FAIL  2-days-ago-row classifies %s (wanted post2): %s\n' "$day" "$out"; }

: > "$SYNCED"
out="$(bash "$P" 2>&1)"; day="$(printf '%s' "$out" | jq -r '.day' 2>/dev/null)"
[ "$day" = "normal" ] && { pass=$((pass+1)); printf 'PASS  no rows classifies normal\n'; } \
  || { fail=$((fail+1)); printf 'FAIL  no rows classifies %s (wanted normal): %s\n' "$day" "$out"; }

# --- plan.sh: hour gating on a normal day (dailyCheckHour pinned deterministically) -----
# Read in the SAME tz plan.sh uses (config's supportNotices.timezone), not machine
# local time -- the two can differ (SAST vs this box's clock) and did during the first
# run of this test.
tz_cfg="$(jq -r '.supportNotices.timezone // "Africa/Johannesburg"' "$CONFIG")"
cur_hour="$(TZ="$tz_cfg" date +%H)"; cur_hour=$((10#$cur_hour))
other_hour=$(( (cur_hour + 1) % 24 ))
weekend_pin=$(( (cur_hour + 2) % 24 ))   # distinct from cur_hour and other_hour -- keeps
                                          # the weekend branch from accidentally matching
                                          # either assertion below on an actual Sat/Sun.
: > "$LASTDAY"; printf '%s\n' "$today" > "$LASTDAY"   # lastday=today -- isolate hour
                                                        # gating from the catch-up branch,
                                                        # tested separately below.
jq --argjson h "$cur_hour" --argjson w "$weekend_pin" \
  '.supportNotices.dailyCheckHour = $h | .supportNotices.weekendMorningCheckHour = $w' \
  "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
out="$(bash "$P" 2>&1)"; act="$(printf '%s' "$out" | jq -r '.act' 2>/dev/null)"
[ "$act" = "yes" ] && { pass=$((pass+1)); printf 'PASS  normal day acts at the configured hour\n'; } \
  || { fail=$((fail+1)); printf 'FAIL  normal day act=%s at the configured hour (wanted yes): %s\n' "$act" "$out"; }

jq --argjson h "$other_hour" --argjson w "$weekend_pin" \
  '.supportNotices.dailyCheckHour = $h | .supportNotices.weekendMorningCheckHour = $w' \
  "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
out="$(bash "$P" 2>&1)"; act="$(printf '%s' "$out" | jq -r '.act' 2>/dev/null)"
[ "$act" = "no" ] && { pass=$((pass+1)); printf 'PASS  normal day quiet off the configured hour\n'; } \
  || { fail=$((fail+1)); printf 'FAIL  normal day act=%s off the configured hour (wanted no): %s\n' "$act" "$out"; }

# --- plan.sh: today field ---------------------------------------------------------------
today_field="$(printf '%s' "$out" | jq -r '.today' 2>/dev/null)"
[ "$today_field" = "$today" ] && { pass=$((pass+1)); printf 'PASS  plan JSON carries today in the configured tz\n'; } \
  || { fail=$((fail+1)); printf 'FAIL  plan .today=%s (wanted %s): %s\n' "$today_field" "$today" "$out"; }

# --- plan.sh: catch-up (missed-window guard) --------------------------------------------
# Both designated hours pinned to a hour already past today -- isolates catch-up from the
# scheduled branch (neither dailyCheckHour nor weekendMorningCheckHour equals cur_hour).
# 1-in-24 flake at cur_hour=0 (mirrors the existing off-hour case above): past_hour can't
# be "already past" at midnight either.
past_hour=0; [ "$cur_hour" -eq 0 ] && past_hour=23
jq --argjson h "$past_hour" \
  '.supportNotices.dailyCheckHour = $h | .supportNotices.weekendMorningCheckHour = $h' \
  "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

rm -f "$LASTDAY"
out="$(bash "$P" 2>&1)"; act="$(printf '%s' "$out" | jq -r '.act' 2>/dev/null)"
cadence="$(printf '%s' "$out" | jq -r '.cadence' 2>/dev/null)"
if [ "$act" = "yes" ] && printf '%s' "$cadence" | grep -qF 'catchup'; then
  pass=$((pass+1)); printf 'PASS  catch-up fires with no lastday recorded\n'
else
  fail=$((fail+1)); printf 'FAIL  catch-up act=%s cadence=%s (wanted yes/+catchup): %s\n' "$act" "$cadence" "$out"
fi

printf '%s\n' "$today" > "$LASTDAY"
out="$(bash "$P" 2>&1)"; act="$(printf '%s' "$out" | jq -r '.act' 2>/dev/null)"
[ "$act" = "no" ] && { pass=$((pass+1)); printf 'PASS  catch-up suppressed once lastday=today\n'; } \
  || { fail=$((fail+1)); printf 'FAIL  catch-up act=%s with lastday=today (wanted no): %s\n' "$act" "$out"; }

# lastday=today must NOT suppress an actual scheduled tick -- the trap this design must
# avoid (catch-up state and the designated-hour check are independent OR'd sources).
jq --argjson h "$cur_hour" '.supportNotices.dailyCheckHour = $h' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
out="$(bash "$P" 2>&1)"; act="$(printf '%s' "$out" | jq -r '.act' 2>/dev/null)"
[ "$act" = "yes" ] && { pass=$((pass+1)); printf 'PASS  scheduled hour still fires despite lastday=today\n'; } \
  || { fail=$((fail+1)); printf 'FAIL  scheduled-hour act=%s with lastday=today (wanted yes): %s\n' "$act" "$out"; }

# --- plan.sh: weekend branch (real DOW -- only assertable on an actual Sat/Sun run) -----
dow="$(TZ="$tz_cfg" date +%u)"
if [ "$dow" -ge 6 ]; then
  jq --argjson h "$cur_hour" --argjson o "$other_hour" \
    '.supportNotices.weekendMorningCheckHour = $h | .supportNotices.dailyCheckHour = $o' \
    "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  printf '%s\n' "$today" > "$LASTDAY"
  out="$(bash "$P" 2>&1)"; act="$(printf '%s' "$out" | jq -r '.act' 2>/dev/null)"
  cadence="$(printf '%s' "$out" | jq -r '.cadence' 2>/dev/null)"
  if [ "$act" = "yes" ] && printf '%s' "$cadence" | grep -qF 'weekend@'; then
    pass=$((pass+1)); printf 'PASS  weekend morning hour acts on Sat/Sun (dow=%s)\n' "$dow"
  else
    fail=$((fail+1)); printf 'FAIL  weekend branch act=%s cadence=%s dow=%s: %s\n' "$act" "$cadence" "$dow" "$out"
  fi
else
  printf 'SKIP  weekend branch not exercised -- today is dow=%s (Mon-Fri), no Sat/Sun to test against\n' "$dow"
fi
rm -f "$LASTDAY"

# --- plan.sh: coverage-cliff guard -------------------------------------------------------
: > "$SYNCED"   # no today row
this_month="${today%-*}"
printf '%s\n' "$this_month" > "$COVERAGE"   # coverage AT the current month, no today row
out="$(bash "$P" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'SCHEDULE-UNRESOLVED'; then
  pass=$((pass+1)); printf 'PASS  coverage cliff fails loud with SCHEDULE-UNRESOLVED\n'
else
  fail=$((fail+1)); printf 'FAIL  coverage cliff did not fail loud (rc=%s): %s\n' "$rc" "$out"
fi

future_month="$(date -d "$today +2 month" +%Y-%m)"
printf '%s\n' "$future_month" > "$COVERAGE"   # coverage still extends past this month -> a real, verified negative
out="$(bash "$P" 2>&1)"; day="$(printf '%s' "$out" | jq -r '.day' 2>/dev/null)"
[ "$day" = "normal" ] && { pass=$((pass+1)); printf 'PASS  coverage still ahead of this month classifies normally, not a refusal\n'; } \
  || { fail=$((fail+1)); printf 'FAIL  coverage-ahead case gave %s (wanted normal, not a refusal): %s\n' "$day" "$out"; }

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
