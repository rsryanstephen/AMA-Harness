#!/usr/bin/env bash
# Plays a short audible cue so the user doesn't have to watch the terminal -- registered
# on two events: Notification (fires when Claude needs permission or is waiting on user
# input, e.g. AskUserQuestion) and Stop (turn finished). Real Windows chime files, not a
# synthesized tone or a stock SystemSounds member -- user picked these by ear after
# listening to several candidates (confirmed real preference, not a guess): "Windows
# Ding.wav" for finished, "Windows Notify Calendar.wav" for needs-input.
#
# Volume: the stock files are mastered very quietly (measured peaks: Ding 7% of full
# scale, Notify Calendar 25%) -- inaudible over music (confirmed real complaint). No
# player exposed here can boost past 100% app volume (Media.SoundPlayer has no volume
# control at all), so instead normalize the PCM samples themselves to ~95% of full scale
# once, into a machine-local cache, and play the boosted copy. Pure scaling into real
# headroom -- no clipping, no distortion. Both files verified 16-bit PCM (the scaler
# checks the header and bails to the original for anything else). Delete the cache dir
# to re-generate (e.g. after editing NORM_TARGET).
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"
. "$HOME/.claude/hooks/lib-session-kind.sh"
payload="$(cat)"

# Breadcrumb, written before ANYTHING that can be slow -- PROJ-15356: on a session
# whose transcript reached 96 MB the stop branch's full-file grep pushed this hook past its
# timeout, so it was killed mid-scan and wrote nothing at all. Silence plus an empty log is
# indistinguishable from the hook never being invoked, which is exactly the question this
# log exists to answer. A [start] line with no completion line after it now names that.
#
# ZERO forks on purpose, and placed above the jq block below rather than after it: measured
# on MSYS, the four jq calls alone delay this line past 1.5s, which would have missed the
# very kill it is meant to catch. So: printf's %(..)T builtin instead of date(1), bash
# substring instead of jq+cut, and the path inlined instead of hstate (one $(..) is one
# fork). hstate still resolves $_logfile below for the completion line, keeping its
# mkdir/absorb behaviour -- this write just fails soft if the dir isn't there yet.
printf -v _ts '%(%Y-%m-%dT%H:%M:%S)T' -1
case "$payload" in
  *'"session_id":"'*) _sid0="${payload#*\"session_id\":\"}"; _sid0="${_sid0%%\"*}"; _sid0="${_sid0:0:8}" ;;
  *) _sid0="?" ;;
esac
printf '%s\n' "$_ts ${1:-notification} sid=$_sid0 [start]" \
  >> "${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/logs/notify-sound.log" 2>/dev/null

# Audit trail for "why did a tone just play?" -- confirmed real confusion: tones that
# seem to fire for nothing (a Stop at a mid-task turn end, or Claude Code's own ~60s
# idle-timer Notification) are indistinguishable by ear from a genuine done/needs-input
# cue. One line per invocation: when, which event, which session, and the Notification
# message if any. Machine-local, covered by .gitignore's *.log.
_sid_full="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
_sid="$(printf '%s' "$_sid_full" | cut -c1-8)"
_msg="$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null)"
_tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
_logfile="$(hstate logs notify-sound.log)"

# Suppress Claude Code's ~60s idle-timer re-notification ("Claude is waiting for your
# input", observed firing ~60-75s after a turn's own Stop already dinged) -- user wants
# tones ONLY for a turn finishing or a genuine ask (permission / plan approval /
# AskUserQuestion, which arrive with different messages -- see notify-sound.log for the
# real observed strings). Still logged, marked suppressed, so the audit trail stays
# complete.
suppress=""
case "$_msg" in *"waiting for your input"*) suppress=1 ;; esac

# Exception to the suppression above, <harnessEpicKey>: this exact idle-timer
# notification is also the ONLY signal that fires after a turn dies on a 529/etc API
# error -- confirmed real, twice: Stop never fires on an API-error-terminated turn (see
# on-stop.sh's mirror_reply -- last stop_hook_summary sat well before the error, nothing
# between the error and the user's own next "continue"). Without this check a stalled
# turn goes fully silent and the user only notices by accident (confirmed: an 8-minute
# gap once). Detected by tailing the transcript and scanning backwards past any trailing
# "system"-typed entries (a turn_duration entry always follows the error) to the last
# real content entry -- both observed real samples happened to end [error,
# turn_duration], but that offset isn't trusted since a subagent turn or a
# hook-summary entry could push the error further back.
api_error_status=""
if [ -n "$suppress" ]; then
  [ -f "$_tr_path" ] || _tr_path="$(ls "$HOME/.claude/projects"/*/"$_sid_full".jsonl 2>/dev/null | head -1)"
  if [ -f "$_tr_path" ]; then
    last_real="$(tail -n 20 "$_tr_path" 2>/dev/null | jq -c 'select(.type != "system")' 2>/dev/null | tail -1)"
    if [ -n "$last_real" ]; then
      is_err="$(printf '%s' "$last_real" | jq -r '.isApiErrorMessage // false' 2>/dev/null)"
      if [ "$is_err" = "true" ]; then
        api_error_status="$(printf '%s' "$last_real" | jq -r '.apiErrorStatus // "?"' 2>/dev/null)"
        suppress=""
      fi
    fi
  else
    # Transcript unresolvable -- a silent failure here would be indistinguishable from
    # the exact bug this is fixing, so it stays logged even though we still suppress.
    api_error_status="check-skipped"
  fi
fi

# Suppress the Stop ding when the turn ended with live background work (a backgrounded
# Bash task or async agent still running) -- that Stop is a hand-off, not "done"; user
# wants the ding only when the session is genuinely idle awaiting the next prompt. The
# task's completion re-invokes the model, and THAT turn's Stop dings as normal. Live =
# launched IDs ("backgroundTaskId" for Bash, async_launched "agentId" for agents,
# "taskId"+"timeoutMs" launch records for Monitors -- the JSON keys, NOT the "Monitor
# started (task X" prose, which false-matches when a turn merely PRINTS that phrase;
# real JSON keys appear escaped (\") inside quoted text so they can't) minus IDs
# already seen in a TERMINAL
# <task-id> notification -- terminal means it carries a <status> tag. That filter
# exists for Monitors (confirmed real ping, session 431272bb): a Monitor emits a
# notification PER EVENT while still running, and those intermediates have no <status>
# tag -- only the final "stream ended" one does (Bash/agent completions always carry
# <status>). The [^"]* bridge in the pattern is safe: task-id/tool-use-id/output-file
# sit before <status> with no quote bytes between, while an intermediate's <summary>
# hits a \" first. Verified against three real multi-week transcripts: every launch
# eventually pairs with a terminal notification, zero stale leftovers.
# The Stop hook's own "Mirroring reply text to session log" statusMessage
# (settings.json UI text, per explicit user concern) never appears in the transcript,
# so it can't be miscounted. Residual risk: a task killed before any notification would
# suppress dings for the rest of that session -- diagnosable via the [bg-live:] IDs
# logged below.
#
# Extraction/set-difference is deliberately pure bash after the one grep -- confirmed
# real miss (f7feade0, 2026-08-07 17:47:21): 3 agent launch records were on disk 17-37s
# before the Stop, a replay of the pipeline against that exact file state finds all 3,
# yet the live run saw none and dinged -- a transient subprocess failure under spawn
# load (3 subagents cold-starting; this hook took 11.5s vs its usual 1.4-3s), with the
# old `comm -23 <(sed..) <(sed..)` the prime suspect (msys emulates process substitution
# via named pipes, flaky under Windows load) and every error swallowed by 2>/dev/null.
# Hence: no procsub, rc-checked grep with one retry, and a fail-open [bg-check-error]
# log marker so a recurrence is diagnosable, never silent.
bg_live=""
bg_check_err=""
headless=""
if [ "${1:-}" = "stop" ]; then
  _tr="$_tr_path"
  [ -f "$_tr" ] || _tr="$(ls "$HOME/.claude/projects"/*/"$_sid_full".jsonl 2>/dev/null | head -1)"
  if [ -f "$_tr" ]; then
    # Headless run (`claude -p` from a hook/unattended runner) -- inherits this settings.json
    # Stop hook and dings on completion, but nobody is waiting on it and the tone is
    # identical to the user's own session finishing (confirmed real confusion: a headless
    # support-notices sweep dinged 2s before an unrelated advisor result landed in another
    # session and read as the advisor's). 14/14 historical headless runs dinged, all `stop`
    # (headless can't prompt, so Notification is untouched -- extending this there would
    # also silently kill the API-error-stall chime for headless runs, unasked-for).
    # Classification (and why it's matched the way it is) lives in lib-session-kind.sh.
    if session_is_headless "$_tr"; then headless=1; suppress=1; fi
    # Last alternative: a TaskStop result. A stopped task gets NO <status> notification, so
    # without it every task Claude stopped itself stayed "live" and muted the session's dings
    # (2026-10-21, f4d6fe04).
    _bgpat='"backgroundTaskId":"[^"]*"\|"status":"async_launched","agentId":"[^"]*"\|"taskId":"[a-z0-9]*","timeoutMs":\|<task-id>[^<]*</task-id>[^"]*<status>\|Successfully stopped task: [a-z0-9]*'
    # Read a TAIL WINDOW, never the whole transcript (PROJ-15356). These files only
    # grow -- one hit 96 MB / 48k lines, and scanning all of it cost more than the hook's
    # whole timeout, so the hook was killed before it could log or play anything. A task
    # launched thousands of lines ago cannot still be live, and the window fails in the
    # SAFE direction: a launch record that scrolls out is simply not seen, so the Stop
    # DINGS rather than being wrongly muted. Measured on that 96 MB file: 2.84s vs 0.16s
    # warm, and far more than that on a cold read.
    _BGWIN=3000
    _bgkeys="$(tail -n "$_BGWIN" "$_tr" 2>/dev/null | grep -oh "$_bgpat" 2>/dev/null)"; _rc=$?
    if [ "$_rc" -ge 2 ]; then
      sleep 1
      _bgkeys="$(tail -n "$_BGWIN" "$_tr" 2>/dev/null | grep -oh "$_bgpat" 2>/dev/null)"; _rc=$?
      [ "$_rc" -ge 2 ] && { bg_check_err="$_rc"; _bgkeys=""; }
    fi
    _launched=""; _terminal=""
    while IFS= read -r _k; do
      case "$_k" in
        '"backgroundTaskId":"'*)
          _id="${_k#\"backgroundTaskId\":\"}"; _id="${_id%\"}" ;;
        '"status":"async_launched","agentId":"'*)
          _id="${_k#*\"agentId\":\"}"; _id="${_id%\"}" ;;
        '"taskId":"'*)
          _id="${_k#\"taskId\":\"}"; _id="${_id%%\"*}" ;;
        '<task-id>'*)
          _id="${_k#<task-id>}"; _id="${_id%%<*}"
          [ -n "$_id" ] && _terminal="$_terminal $_id"
          continue ;;
        'Successfully stopped task: '*)
          _id="${_k#Successfully stopped task: }"
          [ -n "$_id" ] && _terminal="$_terminal $_id"
          continue ;;
        *) continue ;;
      esac
      [ -n "$_id" ] && _launched="$_launched $_id"
    done <<EOF
$_bgkeys
EOF
    # Staleness guard, monitors only: a Monitor that dies at its own timeout (or with the
    # session) emits NO terminal notification at all -- confirmed real in this machine's
    # own transcripts (a "Watch resumed session" monitor's last event landed exactly at
    # its 300000ms timeout, then nothing). Without this, one such monitor mutes every
    # later Stop ding in the session. A monitor cannot outlive launch + its recorded
    # timeout, so a candidate whose launch line is found but whose window has passed is
    # dead, not live. Bash/agent candidates have no such line and pass through.
    _now="$(date +%s)"
    for _id in $_launched; do
      case " $_terminal " in *" $_id "*) continue ;; esac
      case ",$bg_live," in *",$_id,"*) continue ;; esac
      # Same tail window as the scan above, for the same cost reason -- and it stays
      # correct because every candidate in $_launched came OUT of that window, so its
      # launch line is in there too if it has one. Do NOT treat "not found" as dead:
      # Bash/agent candidates never have a timeoutMs line at all, and the empty-$_launch
      # branch below is exactly how they pass through to bg_live.
      _launch="$(tail -n "$_BGWIN" "$_tr" 2>/dev/null | grep -m1 "\"taskId\":\"$_id\",\"timeoutMs\":" 2>/dev/null)"
      if [ -n "$_launch" ]; then
        _tms="$(printf '%s' "$_launch" | grep -oh "\"taskId\":\"$_id\",\"timeoutMs\":[0-9]*" | grep -oh '[0-9]*$')"
        _lts="$(printf '%s' "$_launch" | jq -r '.timestamp // empty' 2>/dev/null)"
        _exp="$(( $(date -d "$_lts" +%s 2>/dev/null || echo 0) + ${_tms:-0} / 1000 ))"
        [ "$_now" -lt "$_exp" ] || continue
      fi
      # A durable-reminder watcher (reminder-watch.sh / reminder.sh watch) runs for the
      # session's whole life by design and is now asked for in every session -- it is not a
      # hand-off, and counting it muted every later Stop ding (2026-10-21, f4d6fe04). Its
      # launch result names the tool_use id; the tool_use line carries the command.
      _rl="$(tail -n "$_BGWIN" "$_tr" 2>/dev/null | grep -m1 "\"backgroundTaskId\":\"$_id\"" 2>/dev/null)"
      if [ -n "$_rl" ]; then
        _tu="${_rl#*\"tool_use_id\":\"}"; _tu="${_tu%%\"*}"
        if [ -n "$_tu" ] && [ "$_tu" != "$_rl" ] && tail -n "$_BGWIN" "$_tr" 2>/dev/null \
             | grep -F "\"id\":\"$_tu\"" 2>/dev/null | grep -q 'reminder-watch\.sh\|reminder\.sh watch'; then
          continue
        fi
      fi
      bg_live="${bg_live:+$bg_live,}$_id"
    done
    [ -n "$bg_live" ] && suppress=1
  fi
fi

logline="$(date +%Y-%m-%dT%H:%M:%S) ${1:-notification} sid=${_sid:-?}${_msg:+ msg=\"$_msg\"}${headless:+ [headless]}${bg_live:+ [bg-live: $bg_live]}${bg_check_err:+ [bg-check-error rc=$bg_check_err]}${suppress:+ [suppressed]}"
case "$api_error_status" in
  ""|"false") : ;;
  "check-skipped") logline="$logline [api-error-check-skipped: no transcript found]" ;;
  *) logline="$logline [api-error-stall status=$api_error_status]" ;;
esac
printf '%s\n' "$logline" >> "$_logfile" 2>/dev/null
[ -n "$suppress" ] && exit 0
[ -n "${NOTIFY_SOUND_DRY:-}" ] && exit 0   # tests: decide + log, never play

MEDIA="C:\\Windows\\Media"
CACHE="$(hstate logs .notify-sound-cache)"
NORM_TARGET="0.95"

if [ "${1:-}" = "stop" ]; then
  name="Windows Ding.wav"
elif [ -n "$api_error_status" ] && [ "$api_error_status" != "false" ] && [ "$api_error_status" != "check-skipped" ]; then
  # Distinct chime for an escaped API-error stall -- per explicit user instruction, this
  # must NOT reuse Ding (finished) or Notify Calendar (ordinary needs-input) even as a
  # fallback, so a stalled turn is never mistakable by ear for one of those two. Both
  # candidates confirmed present on this machine (see ls of C:\Windows\Media).
  name="Windows Critical Stop.wav"
  [ -f "$MEDIA\\$name" ] || name="Windows Hardware Fail.wav"
else
  name="Windows Notify Calendar.wav"
fi
src="$MEDIA\\$name"
boosted="$CACHE/$name"

if [ ! -f "$boosted" ]; then
  mkdir -p "$CACHE" 2>/dev/null
  # One-time normalization: find the 16-bit PCM data chunk, scale every sample so the
  # loudest hits NORM_TARGET of full scale. Anything unexpected (non-PCM, no headroom,
  # write failure) leaves no cache file and we fall through to the quiet original.
  powershell.exe -NoProfile -Command "
    \$b = [IO.File]::ReadAllBytes('$src')
    if ([BitConverter]::ToUInt16(\$b, 20) -ne 1 -or [BitConverter]::ToUInt16(\$b, 34) -ne 16) { exit 1 }
    \$pos = 12
    while (\$pos -lt \$b.Length - 8) {
      \$id = [Text.Encoding]::ASCII.GetString(\$b, \$pos, 4)
      \$sz = [BitConverter]::ToUInt32(\$b, \$pos + 4)
      if (\$id -eq 'data') { break }
      \$pos += 8 + \$sz + (\$sz % 2)
    }
    if (\$id -ne 'data') { exit 1 }
    \$start = \$pos + 8; \$end = [Math]::Min(\$start + \$sz, \$b.Length)
    \$peak = 1
    for (\$i = \$start; \$i -lt \$end - 1; \$i += 2) {
      \$a = [Math]::Abs([int][BitConverter]::ToInt16(\$b, \$i)); if (\$a -gt \$peak) { \$peak = \$a }
    }
    \$gain = ($NORM_TARGET * 32767) / \$peak
    if (\$gain -le 1) { exit 1 }
    for (\$i = \$start; \$i -lt \$end - 1; \$i += 2) {
      \$s = [Math]::Round([BitConverter]::ToInt16(\$b, \$i) * \$gain)
      if (\$s -gt 32767) { \$s = 32767 } elseif (\$s -lt -32768) { \$s = -32768 }
      \$v = [BitConverter]::GetBytes([int16]\$s); \$b[\$i] = \$v[0]; \$b[\$i+1] = \$v[1]
    }
    [IO.File]::WriteAllBytes('$(cygpath -w "$boosted" 2>/dev/null || printf '%s' "$boosted")', \$b)
  " >/dev/null 2>&1
fi

if [ -f "$boosted" ]; then
  wav="$(cygpath -w "$boosted" 2>/dev/null || printf '%s' "$boosted")"
else
  wav="$src"
fi

# Playback goes through notify-sound-play.ps1 rather than an inline SoundPlayer one-liner
# because it also repairs powershell's per-app Volume Mixer volume afterwards -- Windows had
# it stuck at 0% for this endpoint, which makes PlaySync report success and emit silence
# (PROJ-15360; see that script's header for why this recurs and why it is per-endpoint).
# Any status it reports is appended to the same log, so a repair is visible rather than silent.
_play="$HOME/.claude/hooks/notify-sound-play.ps1"
if [ -f "$_play" ]; then
  _pout="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$_play" 2>/dev/null || printf '%s' "$_play")" -Wav "$wav" -AsmCache "$(cygpath -w "$CACHE" 2>/dev/null || printf '%s' "$CACHE")" 2>/dev/null)"
  case "$_pout" in
    "") : ;;
    *) printf '%s\n' "$(date +%Y-%m-%dT%H:%M:%S) ${1:-notification} sid=${_sid:-?} [$(printf '%s' "$_pout" | tr -d '\r' | tr '\n' ';')]" >> "$_logfile" 2>/dev/null ;;
  esac
else
  # Fall back to the original inline call if the helper is missing, so a tone still plays.
  powershell.exe -NoProfile -Command "(New-Object Media.SoundPlayer '$wav').PlaySync()" >/dev/null 2>&1
fi
