#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Relays ONCE each new line of two logs:
#   harness-state/logs/defender-hot.log            -- the user-side trigger (hooks/defender-hot-trigger.sh,
#                                                     the watcher): "started" / "FAILED to start" / "copy differs"
#   %ProgramData%\AMA-Harness\defender-hot\defender-hot.log -- the elevated recording itself
#                                                     (scripts/defender-hot-record.ps1): "recorded ...",
#                                                     "FAILED: <error>", "retired after N".
# The second lives in an admin-owned folder on purpose (the elevated side never writes anywhere a
# user process could redirect); Users can read it. Builtins only -- on-prompt.sh runs on every
# prompt -- and neither file exists in the normal case, so the common path is two -s tests.
# Markers = line count already relayed. Seams: CLAUDE_STATE_DIR, DEFENDER_HOT_ADMIN_LOG.
# The guidance names which kind of line arrived: a bare "FAILED: <error>" means the recording
# RAN (etl/report/csv exist) and only the summary step died -- a peer session read the first one
# as a registration problem (2026-10-15). Sets $defender_hot_notice (empty if nothing new).
defender_hot_notice=""
_dh_state="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}"
_dh_new=""
_dh_relay() {   # <log> <marker>: appends unseen lines to _dh_new, advances the marker
  local log="$1" mk="$2" seen=0 n=0 l
  [ -s "$log" ] || return 0
  [ -f "$mk" ] && { IFS= read -r seen < "$mk" || true; }
  case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
  while IFS= read -r l || [ -n "$l" ]; do
    n=$((n+1)); l="${l%$'\r'}"; l="${l#$'\xEF\xBB\xBF'}"
    [ "$n" -gt "$seen" ] && [ -n "$l" ] && _dh_new="$_dh_new $l"
  done < "$log"
  if [ "$n" -gt "$seen" ]; then
    [ -d "${mk%/*}" ] || mkdir -p "${mk%/*}" 2>/dev/null
    printf '%s' "$n" > "$mk" 2>/dev/null
  fi
}
_dh_relay "$_dh_state/logs/defender-hot.log" "$_dh_state/notices/.defender-hot-seen"
_dh_relay "${DEFENDER_HOT_ADMIN_LOG:-/c/ProgramData/AMA-Harness/defender-hot/defender-hot.log}" "$_dh_state/notices/.defender-hot-seen-admin"
if [ -n "$_dh_new" ]; then
  _dh_g=""
  case "$_dh_new" in *" recorded "*) _dh_g="$_dh_g A 'recorded' line: report the scan share and ms per scan, the window-average engine/sensor/total CPU, queue and memory, the top processes, what it says about the file probe (scanned alone proves nothing was waited for -- tail ~/.claude/harness-state/logs/spell-milestones.log for the validated / refuted / not-seen verdict, after  bash ~/.claude/scripts/spell-milestones.sh check  if it has no line for this recording yet; a decisive one also reaches the owner session as a durable reminder), and the mplog verdict (its .mplog.txt in the same folder names what Defender itself was doing). Then run  bash ~/.claude/scripts/proc-start-latency.sh <that date> --spells  for the slow minutes and their classes, and  bash ~/.claude/scripts/proc-start-latency.sh --since 2026-10-15  for the verdict; report both against the decision rule it prints (memory / cpu / scan-wait / process-start / mixed; insufficient below 3 instrumented spells over 2 days)." ;; esac
  case "$_dh_new" in *"FAILED to start"*) _dh_g="$_dh_g 'FAILED to start' = the one-time elevated registration is missing or the task retired itself: give the user  powershell -ExecutionPolicy Bypass -File \"<harness repo>\\scripts\\register-defender-hot-record.ps1\"  to run as administrator." ;; esac
  case "$_dh_new" in *" FAILED: "*) _dh_g="$_dh_g 'FAILED: <error>' = the recording RAN (its .etl/.report.txt/.cpu.csv are in the admin folder) and only the summary step died in the INSTALLED copy -- not a registration problem; if the repo's defender-hot-record.ps1 already fixes it, the same registration command (elevated) refreshes the copy." ;; esac
  case "$_dh_new" in *"copy differs"*) _dh_g="$_dh_g 'copy differs' = the installed admin-only copy is older than the repo's script: the registration command (elevated) refreshes it." ;; esac
  case "$_dh_new" in *" retired after "*) _dh_g="$_dh_g 'retired' = the recording budget is spent; re-register (optionally -MaxRecordings N) to continue." ;; esac
  defender_hot_notice="DEFENDER HOT RECORDING:$_dh_new Tell the user in this reply.$_dh_g"
  defender_hot_notice="$defender_hot_notice Then append ONE line with your summary to ~/.claude/harness-state/notices/defender-notes.md (- [session <shortid>, <date time>] <summary>)."
  unset _dh_g
fi
# Shared Defender notes (user rule 2026-10-16): every Defender line any session is shown lands
# in ONE file, like harness-gaps.md -- written here mechanically (raw line, which session saw
# it), the session adds its own summary line. The owner session (spell-milestones.owner) gets
# lines it has not seen yet relayed once, so the investigation picks them up in due time.
_dh_notes="$_dh_state/notices/defender-notes.md"; _dh_sid="${sid:-}"
_dh_t=""; printf -v _dh_t '%(%Y-%m-%d %H:%M)T' -1
if [ -n "$_dh_new" ]; then
  [ -f "$_dh_notes" ] || printf '# Defender notes -- one line per note, any session appends; the owner session (harness-state/notices/spell-milestones.owner) reviews them\n\n' > "$_dh_notes" 2>/dev/null
  printf -- '- [session %s, %s] relayed:%s\n' "${_dh_sid:0:8}" "$_dh_t" "$_dh_new" >> "$_dh_notes" 2>/dev/null
fi
_dh_own=""; [ -s "$_dh_state/notices/spell-milestones.owner" ] && { IFS= read -r _dh_own < "$_dh_state/notices/spell-milestones.owner" || true; }
_dh_own="${_dh_own%$'\r'}"
if [ -n "$_dh_sid" ] && [ "$_dh_own" = "$_dh_sid" ] && [ -s "$_dh_notes" ]; then
  _dh_seenf="$_dh_state/notices/.defender-notes-seen-owner"; _dh_s=0; _dh_n=0; _dh_add=""
  [ -f "$_dh_seenf" ] && { IFS= read -r _dh_s < "$_dh_seenf" || true; }; case "$_dh_s" in ''|*[!0-9]*) _dh_s=0 ;; esac
  while IFS= read -r _dh_l || [ -n "$_dh_l" ]; do
    _dh_n=$((_dh_n+1)); [ "$_dh_n" -le "$_dh_s" ] && continue
    case "$_dh_l" in "- ["*) case "$_dh_l" in *"session ${_dh_sid:0:8},"*) ;; *) _dh_add="$_dh_add | ${_dh_l#- }" ;; esac ;; esac
  done < "$_dh_notes"
  printf '%s' "$_dh_n" > "$_dh_seenf" 2>/dev/null
  [ -n "$_dh_add" ] && defender_hot_notice="${defender_hot_notice:+$defender_hot_notice }DEFENDER NOTES from other sessions (you own the Defender investigation; harness-state/notices/defender-notes.md):$_dh_add -- fold them into the investigation and mention what changes."
  unset _dh_seenf _dh_s _dh_n _dh_add _dh_l
fi
unset -f _dh_relay; unset _dh_new _dh_state _dh_notes _dh_t _dh_own _dh_sid
