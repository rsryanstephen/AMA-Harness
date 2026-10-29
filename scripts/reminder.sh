#!/usr/bin/env bash
# Durable cross-session reminders (user instruction 2026-10-13). Replaces session-only
# CronCreate one-shots: a reminder lives on disk, fires in whichever interactive session
# CLAIMS it first (atomic rename -> never twice, never in duplicate sessions), and waits
# for the next session when none is open.
#
# Delivery, two paths, both via `claim`:
#   1. hooks/reminder-check.sh (sourced by on-prompt.sh) -- every prompt in any session.
#   2. `watch <sid>` -- a per-session Bash run_in_background loop: zero tokens while waiting,
#      exits printing the reminder when it claims one, which re-invokes that IDLE session.
#      on-prompt asks a session to start one whenever reminders are pending and it has none.
# The ORIGIN session (the one that added it, has the context) gets first refusal: other
# sessions only claim once a reminder is ORIGIN_GRACE seconds past due.
#
# usage:
#   reminder.sh add <sid> "<YYYY-MM-DD HH:MM local>" <text...>   -> prints id
#   reminder.sh list | cancel <id> | fired
#   reminder.sh claim <sid>     -> prints claimed reminders (id<TAB>text), moves them to fired/
#   reminder.sh done <id>       -> ack a claimed reminder finished (fired/<id>.<sid>.rem -> .done).
#                                  Unacked + claimer cut off by the usage limit = re-queued by
#                                  scripts/limit-resume.py sweep (2026-10-21: a claimed check was lost).
#   reminder.sh watch <sid>     -> blocks until it claims one, prints it, exits
#   reminder.sh slack-unclaimed -> Slack-DM the user once per reminder nobody claimed (see function)
# Text should carry the FULL task (what to run, preconditions, what to do if not ready --
# e.g. re-add for later) -- a cold session executes it with none of the origin's context.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"
D="$(dirname "$(hstate reminders pending/.keep)")"; D="${D%/pending}"
mkdir -p "$D/pending" "$D/fired" "$D/watchers" 2>/dev/null
ORIGIN_GRACE="${REMINDER_ORIGIN_GRACE:-300}"
POLL="${REMINDER_POLL:-60}"
SLACK_AFTER="${REMINDER_SLACK_AFTER:-900}"
LIMDIR="$(dirname "$D")/limits"
LIMPY="${LIMIT_RESUME_PY:-$HOME/.claude/scripts/limit-resume.py}"

# sid_owner_alive <sid>: a ~/.claude/sessions/<pid>.json naming this sid AND that pid running.
# No sessions dir (other platform / CLI change) -> fail open, old behaviour.
sid_owner_alive() {
  local sid="$1" sd="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}" f pid
  [ -d "$sd" ] || return 0
  for f in "$sd"/*.json; do
    [ -f "$f" ] || continue
    grep -q "\"sessionId\":\"$sid\"" "$f" 2>/dev/null || continue
    pid="${f##*/}"; pid="${pid%.json}"
    tasklist.exe //FI "PID eq $pid" //NH 2>/dev/null | grep -qi claude && return 0
  done
  return 1
}

# File format: line1 due-epoch, line2 origin sid, line3 due-human, rest = text.
claim() {
  local sid="$1" now f id due origin human text out=""
  now="$(date +%s)"
  for f in "$D"/pending/*.rem; do
    [ -f "$f" ] || continue
    { read -r due; read -r origin; read -r human; } < "$f"
    [ "$now" -ge "${due:-0}" ] 2>/dev/null || continue
    [ "$origin" = "$sid" ] || [ "$now" -ge $(( due + ORIGIN_GRACE )) ] || continue
    id="${f##*/}"; id="${id%.rem}"
    mv "$f" "$D/fired/$id.$sid.rem" 2>/dev/null || continue   # lost the race: another session has it
    touch "$D/fired/$id.$sid.rem" 2>/dev/null                  # mtime = claim time (limit-resume.py)
    text="$(tail -n +4 "$D/fired/$id.$sid.rem")"
    out="${out}${id}	(due ${human}) ${text}"$'\n'
  done
  printf '%s' "$out"
}

# slack_unclaimed (user rule 2026-10-29): a reminder still in pending/ SLACK_AFTER s past due was
# claimed by nobody -- no session open, or none listening (a live watcher claims within
# ORIGIN_GRACE + POLL). DM the user once, naming the origin session's resume command, and LEAVE
# the .rem in pending/: the next session still shows it in full, so a missed or ignored DM loses
# nothing. Marker slacked/<id> = failed-attempt count, then "sent"; 3 failures -> give up on the
# DM only. Run by hooks/pr-watch-check.sh when task AMA-Harness-Watchers-Ensure runs it directly,
# and by the detached job `add` starts for a reminder due within the hour -- never on-prompt (a
# session is open then, and claude -p would blow the hook timeout).
# Seams: REMINDER_SLACK_DRY_RUN=1 prints instead of sending (=fail simulates a failed send);
# REMINDER_SESSIONS_FILE replaces sessions.txt.
slack_unclaimed() {
  local sd="$D/slacked" now f id due origin human m n first row name cmd target msg reply online=""
  mkdir -p "$sd" 2>/dev/null
  mkdir "$sd/.lock" 2>/dev/null \
    || { [ -n "$(find "$sd/.lock" -maxdepth 0 -mmin +15 2>/dev/null)" ] && rmdir "$sd/.lock" && mkdir "$sd/.lock"; } \
    || return 0
  trap "rmdir '$sd/.lock' 2>/dev/null" EXIT   # expanded now: $sd is local, gone by EXIT time
  for m in "$sd"/*; do [ -f "$m" ] && [ ! -f "$D/pending/${m##*/}.rem" ] && rm -f "$m"; done   # claimed/cancelled
  . "$HOME/.claude/hooks/lib-harness-repos.sh"
  target="$(hr_config '.user.slackSelfDmChannelId' '' | tr -d '\r')"
  [ -n "$target" ] || target="$(hr_config '.user.slackUserId' '' | tr -d '\r')"
  [ -n "$target" ] || return 0
  [ -n "${REMINDER_SLACK_DRY_RUN:-}" ] || command -v claude >/dev/null 2>&1 || return 0
  now="$(date +%s)"
  for f in "$D"/pending/*.rem; do
    [ -f "$f" ] || continue
    { read -r due; read -r origin; read -r human; } < "$f"
    [ "$now" -ge $(( ${due:-0} + SLACK_AFTER )) ] 2>/dev/null || continue
    id="${f##*/}"; id="${id%.rem}"; m="$sd/$id"; n=0
    [ -f "$m" ] && IFS= read -r n < "$m"
    [ "$n" = sent ] && continue
    [ "${n:-0}" -lt 3 ] 2>/dev/null || continue
    first="$(tail -n +4 "$f" | tr '\n' ' ' | sed -E 's/([.!?]) .*/\1/' | cut -c1-200)"
    name=""; cmd=""
    case "$origin" in ????????-????-????-????-????????????)
      row="$(grep -F -- "$origin" "${REMINDER_SESSIONS_FILE:-$HOME/.claude/sessions.txt}" 2>/dev/null | head -1 | tr -d '\r')"
      name="${row%% cd *}"; cmd="cd ${row#* cd }"
      [ -n "$row" ] && [ "$row" != "$name" ] || { name="${origin:0:8}"; cmd="claude -r $origin"; } ;;
    esac
    msg="$(hr_self_mention "$target")Reminder due ${human} and no Claude session picked it up: ${first}"
    [ -n "$cmd" ] && msg="$msg Reopen the session that set it, \`${name}\`: \`${cmd}\`"
    msg="$msg -- It stays queued, so the next Claude session you open shows it in full too."
    if [ -n "${REMINDER_SLACK_DRY_RUN:-}" ]; then
      printf 'DM %s: %s\n' "$id" "$msg"
      reply="DONE"; [ "$REMINDER_SLACK_DRY_RUN" = fail ] && reply="FAILED: dry run"
    else
      if [ -z "$online" ]; then
        . "$HOME/.claude/hooks/lib-unattended-ready.sh"
        wait_until_online : 4 30 || return 0   # offline: not an attempt, the next pass retries
        online=1
      fi
      reply="$(timeout 120 claude -p "Call mcp__claude_ai_Slack__slack_send_message with channel_id ${target} and this exact message text: ${msg} -- then reply with ONLY the word DONE, or FAILED: and the error." \
        --model haiku --allowedTools mcp__claude_ai_Slack__slack_send_message 2>&1 | tr -d '\r')"
      case "$reply" in *"spend limit"*|*"usage limit"*|*"rate limit"*)
        printf '%s %s\n' "$(date '+%F %T')" "reminder.sh slack-unclaimed" >> "$(hstate notices unattended-blocked.txt)" ;;
      esac
    fi
    if ! printf '%s\n' "$reply" | grep -q '^FAILED:' && printf '%s\n' "$reply" | grep -qx 'DONE'; then
      echo sent > "$m"
    else
      echo $(( ${n:-0} + 1 )) > "$m"
    fi
    printf '%s %s %s\n' "$(date '+%F %T')" "$id" "$(head -1 "$m")" >> "$D/slack.log"
  done
}

case "${1:-}" in
  add)
    sid="${2:?sid}"; when="${3:?when}"; shift 3; text="$*"; [ -n "$text" ] || { echo "text required" >&2; exit 2; }
    due="$(date -d "$when" +%s)" || { echo "bad time: $when" >&2; exit 2; }
    id="$(date +%Y%m%d%H%M%S)-$$"
    printf '%s\n%s\n%s\n%s\n' "$due" "$sid" "$(date -d "@$due" '+%Y-%m-%d %H:%M %Z')" "$text" > "$D/pending/$id.tmp" \
      && mv "$D/pending/$id.tmp" "$D/pending/$id.rem" && echo "$id" || exit 1
    # Due within the hour (a PR merge, a deploy outcome): check it SLACK_AFTER past due, not at the
    # next 30-min Watchers-Ensure pass (2026-10-29). Detached so it outlives the caller; the task
    # pass stays the backstop. Never under a test state dir (it would outlive the dir) unless the
    # seam REMINDER_DM_DELAY=<s> forces one.
    dly=$(( due - $(date +%s) + SLACK_AFTER + 30 )); [ "$dly" -gt 0 ] || dly=0
    if [ -n "${REMINDER_DM_DELAY:-}" ] || { [ -z "${CLAUDE_STATE_DIR:-}" ] && [ "$dly" -le $(( 3600 + SLACK_AFTER + 30 )) ]; }; then
      { nohup bash -c "sleep ${REMINDER_DM_DELAY:-$dly}; exec bash '$HOME/.claude/scripts/reminder.sh' slack-unclaimed" </dev/null >/dev/null 2>&1 & } 2>/dev/null
      disown 2>/dev/null || true
    fi ;;
  list)
    for f in "$D"/pending/*.rem; do [ -f "$f" ] || continue
      { read -r due; read -r origin; read -r human; } < "$f"; id="${f##*/}"
      printf '%s\t%s\torigin %s\t%s\n' "${id%.rem}" "$human" "${origin:0:8}" "$(tail -n +4 "$f" | head -c 120 | tr '\n' ' ')"
    done ;;
  cancel) rm -f "$D/pending/${2:?id}.rem" && echo "cancelled ${2}" ;;
  fired) ls -t "$D/fired" 2>/dev/null | head -20 ;;
  done)
    id="${2:?id}"; n=0
    for f in "$D"/fired/"$id".*.rem; do [ -f "$f" ] && mv -f "$f" "${f%.rem}.done" && n=1; done
    [ "$n" = 1 ] && echo "done $id" || { echo "no claimed reminder $id in $D/fired" >&2; exit 1; } ;;
  claim) claim "${2:?sid}" ;;
  slack-unclaimed) slack_unclaimed ;;
  watch)
    sid="${2:?sid}"
    # One watcher per session (2026-10-22): a re-arm while the previous one still polls (the
    # nudge replayed after compaction, two re-arms in one turn) stacks 4 bash processes per
    # duplicate. Same liveness test reminder-check.sh uses before it asks for one.
    _wp=""; [ -f "$D/watchers/$sid.pid" ] && IFS= read -r _wp < "$D/watchers/$sid.pid"
    . "$HOME/.claude/hooks/lib-proc-cmdline.sh"
    if [ "${_wp:-}" != "$$" ] && proc_alive_running "$_wp" "$sid"; then
      printf 'reminder watcher for %s already running (pid %s) -- nothing to do\n' "${sid:0:8}" "$_wp"
      exit 0
    fi
    echo "$$" > "$D/watchers/$sid.pid"
    trap 'rm -f "$D/watchers/$sid.pid"' EXIT
    while :; do
      # Watcher outlives its session on /clear (same claude.exe, new sid) and on exit (orphan
      # bash) -> claimed under a dead sid, printed to nobody; 4 reminders lost 2026-10-15.
      # Claim only while a live claude process still holds THIS sid (sessions/<pid>.json).
      sid_owner_alive "$sid" || exit 0
      # Usage-limit wake (2026-10-21): an open session cut off by the limit is not always
      # auto-continued by Claude Code (44b3716a was not), and nothing else wakes an idle one.
      # Once the window has reset (+5 min, so the CLI's own continue goes first), exiting here
      # IS the wake-up. limit-resume.py stalled prints only once per limit hit.
      if [ -f "$LIMDIR/window-hit" ]; then
        IFS= read -r _wr < "$LIMDIR/window-hit"; _wr="${_wr//[^0-9]/}"
        if [ -n "$_wr" ] && [ "$(date +%s)" -ge $(( _wr + 300 )) ] && python "$LIMPY" stalled "$sid" >/dev/null 2>&1; then
          printf 'LIMIT-RESET-WAKE: the usage limit has reset and this session was cut off mid-task by it. Run `python ~/.claude/scripts/limit-resume.py audit %s` and resume every unfinished item it lists, then re-arm this watcher (same Bash run_in_background command).
' "$sid"
          exit 0
        fi
      fi
      # Keeps polling even when the queue is empty: another session may add one later, and an
      # idle session has no other way to notice. A sleep loop costs no tokens.
      got="$(claim "$sid")"
      [ -n "$got" ] && { printf 'DURABLE REMINDER(S) DUE -- act on each now, ack each finished one with `bash ~/.claude/scripts/reminder.sh done <id>`, then re-arm this watcher (same Bash run_in_background command) so this session keeps catching later ones:\n%s' "$got"; exit 0; }
      sleep "$POLL"
    done ;;
  *) sed -n 2,23p "$0"; exit 2 ;;
esac
