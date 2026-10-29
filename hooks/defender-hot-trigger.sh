#!/usr/bin/env bash
# Starts the elevated AMA-Harness-Defender-Hot-Record task (scripts/defender-hot-record.ps1: a
# 120 s Defender performance recording DURING a slow spell) if the 30-min cooldown allows.
# Usage: defender-hot-trigger.sh <reason>     (reason lands in the log and the report line)
#
# Called by hooks/dispatch.sh when two consecutive once-a-minute bash-start samples are >= 400 ms
# (12 Oct's spell: 444-1797 ms; a lone 500 ms sample is common on this box). The resident
# watcher (scripts/console-window-watch.ps1) fires the same task on MsMpEng CPU in PowerShell
# and shares the marker below, so the two triggers never double-record.
#
# A task that is not registered yet (one-time elevated step: scripts/register-defender-hot-record.ps1)
# fails here with a FAILED line; hooks/defender-hot-check.sh turns that into the registration
# command on the next prompt instead of a silent nothing. Seams: CLAUDE_STATE_DIR,
# DEFENDER_HOT_SCHTASKS (a fake schtasks for check-gates.sh).
set -u
S="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/logs"
M="$S/.defender-hot-last"; L="$S/defender-hot.log"; D="$S/.defender-hot-day"
reason="${1:-unspecified}"
# Slow box -> clear leftover processes NOW (user rule 2026-10-22), not at the next 15-min tick:
# start the AMA-Harness-Orphan-Conhost-Reap task (scripts/reap-orphan-conhost.ps1 -- only
# provably dead leftovers: stuck hooks past timeout, watchers of closed sessions, duplicate
# singletons, orphan consoles/dev servers/test browsers). Own 10-min marker, independent of
# the recording cooldown below. Seam: REAP_SCHTASKS.
RM="$S/.orphan-reap-kick"; rk=0
[ -f "$RM" ] && { IFS= read -r rk < "$RM" || true; }
case "$rk" in ''|*[!0-9]*) rk=0 ;; esac
if [ $((EPOCHSECONDS - rk)) -ge 600 ]; then
  printf '%s' "$EPOCHSECONDS" > "$RM" 2>/dev/null
  "${REAP_SCHTASKS:-schtasks.exe}" //run //tn AMA-Harness-Orphan-Conhost-Reap >/dev/null 2>&1 </dev/null
fi
last=0
[ -f "$M" ] && { IFS=' ' read -r last _ < "$M" || true; }
last="${last%$'\r'}"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ $((EPOCHSECONDS - last)) -ge 1800 ] || exit 0
# Recorder has its OWN 30-min cooldown (newest .etl) and exits 0 silently -- a start then would
# burn a daily slot and log "started" for nothing (2026-10-15). Users can read the output dir.
OD="${DEFENDER_HOT_OUT:-/c/ProgramData/AMA-Harness/defender-hot}"
if [ -n "$(find "$OD" -maxdepth 1 \( -name '*.etl' -o -name '*.report.txt' \) -mmin -30 2>/dev/null | head -1)" ]; then
  printf '%(%Y-%m-%dT%H:%M:%S)T hot-record skipped: recorder cooldown (output < 30 min old) reason=%s\n' -1 "$reason" >> "$L"
  exit 0
fi
# At most DEFENDER_HOT_PER_DAY (2) starts per calendar day on top of the cooldown -- a spiky
# day (8 qualifying samples on 2026-10-15) would otherwise spend the task's whole
# 3-recording budget before lunch. Failed starts count too, so an unregistered task is
# reported twice a day, not every half hour.
today="$(printf '%(%Y-%m-%d)T' -1)"; dday=""; dn=0
[ -f "$D" ] && { IFS=' ' read -r dday dn < "$D" || true; }
# The watcher writes this file with Set-Content (CRLF): without the strip, "1\r" fails the
# digit test below, reads as 0, and the shared cap silently restarts after every watcher start.
dday="${dday%$'\r'}"; dn="${dn%$'\r'}"
[ "$dday" = "$today" ] || dn=0
case "$dn" in ''|*[!0-9]*) dn=0 ;; esac
[ "$dn" -lt "${DEFENDER_HOT_PER_DAY:-2}" ] || exit 0
[ -d "$S" ] || mkdir -p "$S" 2>/dev/null
printf '%s %s\n' "$EPOCHSECONDS" "$reason" > "$M"
printf '%s %s\n' "$today" "$((dn+1))" > "$D"
# Doubled slashes: MSYS rewrites a single /run into a path (AGENTS.md, schtasks trap).
if "${DEFENDER_HOT_SCHTASKS:-schtasks.exe}" //run //tn AMA-Harness-Defender-Hot-Record >/dev/null 2>&1; then
  printf '%(%Y-%m-%dT%H:%M:%S)T hot-record started reason=%s\n' -1 "$reason" >> "$L"
else
  printf '%(%Y-%m-%dT%H:%M:%S)T hot-record FAILED to start (task registered? run scripts/register-defender-hot-record.ps1 from an elevated PowerShell) reason=%s\n' -1 "$reason" >> "$L"
fi
# The task runs an admin-only COPY, refreshed only by re-registering: say so when the copy is
# older than the repo's script, or a fix sits in the repo while the task keeps failing (the
# first live run did exactly that, 2026-10-15). One cmp, only on a trigger. Seam: DEFENDER_HOT_BIN.
bin="${DEFENDER_HOT_BIN:-/c/ProgramData/AMA-Harness/bin/defender-hot-record.ps1}"
src="$HOME/.claude/scripts/defender-hot-record.ps1"
if [ -f "$bin" ] && [ -f "$src" ] && ! cmp -s "$bin" "$src"; then
  printf '%(%Y-%m-%dT%H:%M:%S)T hot-record installed copy differs from the repo script -- re-run scripts/register-defender-hot-record.ps1 (elevated) to refresh it\n' -1 >> "$L"
fi
exit 0
