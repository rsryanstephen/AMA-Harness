#!/usr/bin/env bash
# Stop hook. A reply that DEFERS work until after the US business-hours window (Mon-Fri
# 9am-5pm ET -- the Redshift-heavy, prod-api-test and prod-deploy rules all use it) must
# also SCHEDULE the deferred work: a durable reminder (scripts/reminder.sh, 2026-10-13; was CronCreate) for the next weekday 08:00 LOCAL (2026-10-14; was 17:04 ET, PC is off then) carrying
# the full task. Otherwise the deferral is a promise in prose that nothing fires.
#
# The incident, 2026-10-07 (PROJ-15352): the verification replay, an anchor-loan
# Redshift check and a timing comparison were all correctly pushed past 17:00 ET, and the
# reply ended "owed after 17:00 ET today ... if this session is still open then, I'll run
# them". The user had to ask for a reminder, then asked for the harness to always set one.
# Per CLAUDE.md's "Mechanical Triggers Over Self-Recognition" this is a hook, not a line in
# a skill: the moment of deferral is mid-task, the next thing is always something else, and
# self-recognition is exactly what failed.
#
# Mechanics. Reply-scanning Stop hook, same shape as self-checkable-ask-reminder.sh (last
# assistant turn only, tail-bounded read). Fires only when BOTH hold in the same paragraph:
#   - a deferral phrase ("after 17:00 ET", "after 5pm ET", "outside business hours", "when the
#     window closes/reopens", "owed after", "deferred until"), and
#   - the window itself is named (ET/Eastern/business hours/Redshift window),
# AND no CronCreate tool call appears in the recent transcript (the reminder was not set).
# Then it returns decision:block so the turn continues and sets the reminder; the reason
# carries the exact next-weekday-08:00-local slot (lib-et-now.sh et_next_morning_local;
# never TZ=... date, git-bash ignores it). `stop_hook_active` is honoured:
# a turn resumed by this block is never blocked again, so it cannot loop.
set -u

payload="$(cat)"
case "$payload" in *"stop_hook_active\":true"*) exit 0 ;; esac
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
[ -n "$tr_path" ] || exit 0
[ -f "$tr_path" ] || exit 0

# The reminder is already set if a CronCreate call sits in the recent transcript.
# 2026-10-13: the durable queue (scripts/reminder.sh add) is the preferred form; CronCreate still counts.
tail -n 400 "$tr_path" 2>/dev/null | grep -qE '"name":"CronCreate"|reminder\.sh add' && exit 0

text="$(tail -n 200 "$tr_path" 2>/dev/null | jq -s -r '
  [.[] | select(.type=="assistant")] | last | .message.content[]? |
  select(.type=="text") | .text' 2>/dev/null | tr -d '\r')"
[ -n "$text" ] || exit 0

hit="$(printf '%s\n\n' "$text" | awk '
  BEGIN { para="" }
  /^[[:space:]]*$/ { if (para != "") { print para; print "\x01" }; para=""; next }
  { para = (para=="" ? $0 : para " " $0) }
' | awk -v RS='\x01' '
  {
    p = tolower($0)
    defer = (p ~ /after 17:0[0-9] ?(et|eastern)/ || p ~ /after 5 ?pm ?(et|eastern)/ ||
             p ~ /after 17:00/ || p ~ /until after (17:00|5 ?pm|business hours|the window)/ ||
             p ~ /outside (of )?(us )?business hours/ || p ~ /when the (redshift )?window (closes|reopens|lifts)/ ||
             p ~ /once the (redshift )?window (closes|reopens|lifts)/ || p ~ /owed after/ ||
             p ~ /deferred (to|until)/ || p ~ /wait(s)? until (after )?(17:00|5 ?pm)/ ||
             p ~ /this evening/ && p ~ /(redshift|replay|window)/)
    win = (p ~ /\bet\b/ || p ~ /eastern/ || p ~ /business.hours/ || p ~ /redshift/ || p ~ /window/)
    # A reminder already acknowledged in the same paragraph is not a bare deferral.
    done = (p ~ /reminder (is )?set/ || p ~ /scheduled (a|the) (reminder|wake)/ || p ~ /croncreate/ || p ~ /reminder\.sh/ || p ~ /durable reminder/)
    if (defer && win && !done) { print; exit }
  }
')"
[ -n "$hit" ] || exit 0

# Default slot (user rule 2026-10-14): next weekday 08:00 LOCAL -- the PC is off at 17:04 ET
# (= 23:04 SAST), and 08:00 SAST is 01:00/02:00 ET, outside the window. lib-et-now.sh's
# et_next_morning_local owns the computation (python, never TZ=...; seam DEFER_NOW_LOCAL).
. "${HOOKS_DIR:-$(dirname "$0")}/lib-et-now.sh" 2>/dev/null
slot="$(et_next_morning_local 2>/dev/null)"
if [ -n "$slot" ]; then
  when="durable reminder at $slot local (next weekday 08:00 local, outside the ET window -- the user's PC is off at 17:04 ET; use ~17:04 ET today only if the user explicitly asks for tonight): bash ~/.claude/scripts/reminder.sh add <session-id> \"$slot\" <full task>, plus this session's watcher (Bash run_in_background: bash ~/.claude/scripts/reminder.sh watch <session-id>) if not running."
else
  when="durable reminder (bash ~/.claude/scripts/reminder.sh add <session-id> \"YYYY-MM-DD 08:00\" <full task>) at the next weekday 08:00 LOCAL time (weekend -> Monday; before 08:00 on a weekday -> today), computed with python, never TZ=... date."
fi

snippet="$(printf '%s' "$hit" | cut -c1-200)"
jq -cn --arg s "$snippet" --arg w "$when" '{
  decision: "block",
  reason: ("DEFERRED WORK WITH NO REMINDER: the reply defers work until after the US business-hours window (\"" + $s + "...\") but no reminder was set. User rule 2026-10-07: every deferral past 17:00 ET gets a one-shot reminder in the same turn, default slot next weekday 08:00 local (2026-10-14). Set it NOW: " + $w + " Put the FULL task in the prompt (what to run, where, what passes, what to transition) so a cold wake-up can execute it without this context. It is durable: it fires in whichever open session claims it first, or the next one opened -- tell the user they can close this session. If the deferral was wrong (window already open, or the work is light enough to run now), run it instead.")
}'
exit 0
