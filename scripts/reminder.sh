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
#   reminder.sh watch <sid>     -> blocks until it claims one, prints it, exits
# Text should carry the FULL task (what to run, preconditions, what to do if not ready --
# e.g. re-add for later) -- a cold session executes it with none of the origin's context.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"
D="$(dirname "$(hstate reminders pending/.keep)")"; D="${D%/pending}"
mkdir -p "$D/pending" "$D/fired" "$D/watchers" 2>/dev/null
ORIGIN_GRACE="${REMINDER_ORIGIN_GRACE:-300}"
POLL="${REMINDER_POLL:-60}"

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
    text="$(tail -n +4 "$D/fired/$id.$sid.rem")"
    out="${out}${id}	(due ${human}) ${text}"$'\n'
  done
  printf '%s' "$out"
}

case "${1:-}" in
  add)
    sid="${2:?sid}"; when="${3:?when}"; shift 3; text="$*"; [ -n "$text" ] || { echo "text required" >&2; exit 2; }
    due="$(date -d "$when" +%s)" || { echo "bad time: $when" >&2; exit 2; }
    id="$(date +%Y%m%d%H%M%S)-$$"
    printf '%s\n%s\n%s\n%s\n' "$due" "$sid" "$(date -d "@$due" '+%Y-%m-%d %H:%M %Z')" "$text" > "$D/pending/$id.tmp" \
      && mv "$D/pending/$id.tmp" "$D/pending/$id.rem" && echo "$id" ;;
  list)
    for f in "$D"/pending/*.rem; do [ -f "$f" ] || continue
      { read -r due; read -r origin; read -r human; } < "$f"; id="${f##*/}"
      printf '%s\t%s\torigin %s\t%s\n' "${id%.rem}" "$human" "${origin:0:8}" "$(tail -n +4 "$f" | head -c 120 | tr '\n' ' ')"
    done ;;
  cancel) rm -f "$D/pending/${2:?id}.rem" && echo "cancelled ${2}" ;;
  fired) ls -t "$D/fired" 2>/dev/null | head -20 ;;
  claim) claim "${2:?sid}" ;;
  watch)
    sid="${2:?sid}"; echo "$$" > "$D/watchers/$sid.pid"
    trap 'rm -f "$D/watchers/$sid.pid"' EXIT
    while :; do
      # Watcher outlives its session on /clear (same claude.exe, new sid) and on exit (orphan
      # bash) -> claimed under a dead sid, printed to nobody; 4 reminders lost 2026-10-15.
      # Claim only while a live claude process still holds THIS sid (sessions/<pid>.json).
      sid_owner_alive "$sid" || exit 0
      # Keeps polling even when the queue is empty: another session may add one later, and an
      # idle session has no other way to notice. A sleep loop costs no tokens.
      got="$(claim "$sid")"
      [ -n "$got" ] && { printf 'DURABLE REMINDER(S) DUE -- act on each now, then re-arm this watcher (same Bash run_in_background command) so this session keeps catching later ones:\n%s' "$got"; exit 0; }
      sleep "$POLL"
    done ;;
  *) sed -n 2,22p "$0"; exit 2 ;;
esac
