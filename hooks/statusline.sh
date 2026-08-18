#!/usr/bin/env bash
# statusLine command. Claude Code invokes this every render with a JSON payload on
# stdin (model, cost, context_window, session_id, rate_limits.five_hour/.seven_day.
# used_percentage + resets_at -- session_id confirmed via code.claude.com/docs/en/
# statusline, "Unique session identifier"). Renders a colored bar (ANSI -- the terminal
# draws this directly, unlike chat replies which only render markdown, no color) AND, on
# a NEW 75%/90% threshold crossing, appends a one-line notice to .usage-notices for
# on-prompt.sh to relay into chat -- the bar alone is live but easy to not be looking at;
# the in-chat notice is the one-time nudge. See skills/usage-monitor/SKILL.md for the
# full design/rationale.
#
# Also renders/notices context_window.used_percentage the same way (check_context
# below) -- PER-SESSION though, not account-wide like the rate-limit windows, so its
# state/notice files key off $sid. See skills/context-hygiene/SKILL.md trigger 3.
#
# Also owns rate-limit auto-resume scheduling (<harnessEpicKey>) -- moved here from
# on-stop.sh's check_rate_limit_hit, which was confirmed dead code twice over: it hung
# off the Stop hook, which never fires on an API-error-terminated turn (see the 529
# investigation), and even if it had run, its text grep didn't match the real message
# ("You've hit your session limit · resets 2:50am" contains none of "usage limit"/"rate
# limit"/"resets at"). This script needs neither check -- it already gets the
# authoritative used_percentage/resets_at straight from Claude Code's own payload, on
# every render, independent of any hook firing at all.
#
# Fork budget: this renders continuously (Claude Code's own docs: "runs frequently
# during active sessions... can cause lag"), and process creation costs ~60ms on this
# machine (Sysmon/Intune tax, see on-prompt.sh:465's sibling comment). It used to fork
# ~25 processes per render (7 jq on the same payload, awk per threshold check, jq per
# statefile read/write, command-substituted shell functions -- MSYS has no real fork(),
# so even $(shell_function) is a full process). Now: cat + ONE jq + rare-path extras.
payload="$(cat)"

# Single jq for all seven fields (was seven separate jq re-parsing the same payload).
# Payload sends raw floats (eg. 14.000000000000002) -- round once here so both the bar
# AND the .usage-notices/.ctx-notices-$sid text (which quotes these same vars) get
# clean integers, instead of formatting at every print site. `// ""` (never `// empty`)
# so a missing field still emits its line and the positional reads below stay aligned.
# jq.exe emits CRLF and `read` (unlike `$(...)`) does NOT strip the \r, so strip it
# from each explicitly -- resets are compared numerically below, a stray \r breaks that.
model=""; sid=""; five_pct=""; five_reset=""; week_pct=""; week_reset=""; ctx_pct=""
{ IFS= read -r model; IFS= read -r sid; IFS= read -r five_pct; IFS= read -r five_reset
  IFS= read -r week_pct; IFS= read -r week_reset; IFS= read -r ctx_pct; } < <(
  printf '%s' "$payload" | jq -r '
    def r(v): if v == null then "" else ((v + 0.5) | floor) end;
    (.model.display_name // .model.id // "?"),
    (.session_id // ""),
    r(.rate_limits.five_hour.used_percentage),
    (.rate_limits.five_hour.resets_at // ""),
    r(.rate_limits.seven_day.used_percentage),
    (.rate_limits.seven_day.resets_at // ""),
    r(.context_window.used_percentage)
  ' 2>/dev/null)
model="${model%$'\r'}"; sid="${sid%$'\r'}"
five_pct="${five_pct%$'\r'}"; five_reset="${five_reset%$'\r'}"
week_pct="${week_pct%$'\r'}"; week_reset="${week_reset%$'\r'}"
ctx_pct="${ctx_pct%$'\r'}"
[ -n "$model" ] || model="?"

STATE="$HOME/.claude/.usage-state"; [ -d "$STATE" ] || mkdir -p "$STATE"
NOTICES="$HOME/.claude/.usage-notices"
printf -v now '%(%s)T' -1   # bash builtin -- no date fork, no subshell

# Queue this session for auto-resume once its reset time passes, then (separately, gated
# behind $4/already_scheduled since schtasks.exe is not cheap to call at render frequency
# -- confirmed by the CLI's own docs: "runs frequently during active sessions... can
# cause lag") schedule the one-shot task that actually fires the resume. Echoes the
# resets_at it scheduled for (or the pre-existing value if it skipped) so the caller can
# persist it back into the state file.
#
# Queue append is deliberately UNGATED by the schtasks dedup below: the 5-hour/weekly
# windows are account-wide, not per-session, so with more than one session open when a
# shared window exhausts, gating the append on "has a task already been scheduled" would
# only ever queue the first session to notice. resume-rate-limited.sh's own consumer loop
# already expects "one task, N queue entries" -- this is what actually gets it there.
schedule_resume() {
  local reset="$1" already_scheduled="$2"
  [ -n "$reset" ] && [ -n "$sid" ] || { printf '%s' "$already_scheduled"; return 0; }
  [ "$reset" -gt "$now" ] || { printf '%s' "$already_scheduled"; return 0; }

  local QUEUE="$HOME/.claude/.rate-limited-sessions"
  # --no-chrome: this resumes unattended (resume-rate-limited.sh discards all output),
  # so if Chrome-by-default is ever on, a browser-tool prompt here would hang forever
  # with no error surfaced. Keep this flag even if that default gets turned off.
  grep -qF "${sid}|" "$QUEUE" 2>/dev/null || \
    printf '%s\n' "${sid}|claude --resume ${sid} -p \"continue\" --no-chrome" >> "$QUEUE"

  # Cheap gate: only enter the schtasks pair once per window exhaustion, not once per
  # render.
  if [ "$already_scheduled" = "$reset" ]; then
    printf '%s' "$already_scheduled"
    return 0
  fi

  local taskname="AMA-ResumeAtReset-$reset"
  export MSYS_NO_PATHCONV=1
  if ! schtasks.exe /query /tn "$taskname" >/dev/null 2>&1; then
    # Confirmed real bug during testing (moved from check_rate_limit_hit): this
    # machine's schtasks.exe requires yyyy/mm/dd, not mm/dd/yyyy -- locale-dependent,
    # don't assume US format.
    local st sd
    st="$(date -d "@$reset" +%H:%M 2>/dev/null)"
    sd="$(date -d "@$reset" +%Y/%m/%d 2>/dev/null)"
    if [ -n "$st" ] && [ -n "$sd" ]; then
      schtasks.exe /create /sc once /st "$st" /sd "$sd" /tn "$taskname" \
        /tr "bash \"$HOME/.claude/hooks/resume-rate-limited.sh\"" /f >/dev/null 2>&1
    fi
  fi
  printf '%s' "$reset"
}

# Sets $__color instead of printing -- $(shell_function) is a full process creation
# under MSYS (no real fork()), so every command substitution of a local function costs
# like an external tool. Threshold compares are plain bash arithmetic now that the pct
# values are jq-rounded integers (see the payload read above). Caller guards non-empty.
color_for() {
  if [ "$1" -ge 90 ]; then __color=$'\033[1;31m'
  elif [ "$1" -ge 75 ]; then __color=$'\033[1;33m'
  else __color=$'\033[32m'; fi
}

color_for_ctx() {
  if [ "$1" -ge 80 ]; then __color=$'\033[1;31m'
  elif [ "$1" -ge 60 ]; then __color=$'\033[1;33m'
  else __color=$'\033[32m'; fi
}

# Sets $__delta ("~2h13m" / "~45m" / "soon") -- same no-print reasoning as color_for.
human_delta() {
  local secs="$1"
  [ -n "$secs" ] || { __delta='soon'; return; }
  [ "$secs" -lt 0 ] && secs=0
  local h=$((secs / 3600)) m=$(( (secs % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then __delta="~${h}h${m}m"; else __delta="~${m}m"; fi
}

# check_window <state-file-name> <used_pct> <resets_at-epoch> <label>
# Fires (appends to $NOTICES) only the FIRST time a window crosses 75 or 90 since the
# last reset -- re-render every few seconds shouldn't re-notice the same crossing.
check_window() {
  local statefile="$STATE/$1" pct="$2" reset="$3" label="$4"
  [ -n "$pct" ] || return 0
  # Statefile is this script's OWN one-line JSON (written below) with fully controlled
  # values (integers / digit-strings / empty) -- parse and write it with bash regex and
  # printf instead of two jq reads + a jq write per window per render. NOT a general
  # JSON parser; only valid because both sides of the format live in this function.
  local prev_notified=0 prev_scheduled="" state_line=""
  if [ -f "$statefile" ]; then
    IFS= read -r state_line < "$statefile" 2>/dev/null
    [[ "$state_line" =~ \"notified\":([0-9]+) ]] && prev_notified="${BASH_REMATCH[1]}"
    [[ "$state_line" =~ \"scheduled_for\":\"([0-9]*)\" ]] && prev_scheduled="${BASH_REMATCH[1]}"
  fi
  # Re-arm once usage actually falls back under 75% -- the real signal a new window
  # rolled over, not resets_at equality (confirmed unreliable: resets_at can be
  # recomputed with a few seconds of jitter between calls within the SAME window,
  # which would otherwise spuriously reset the notified counter every single call).
  # scheduled_for re-arms the same way, for the same reason -- a rolled-over window gets
  # a fresh resets_at anyway, so this isn't strictly required for schedule_resume's own
  # equality check to do the right thing, but leaving a stale epoch behind is confusing
  # to read in the state file.
  if [ "$pct" -lt 75 ]; then
    prev_notified=0
    prev_scheduled=""
  fi
  local new_notified="$prev_notified" secs=""
  if [ "$pct" -ge 90 ] && [ "$prev_notified" -lt 90 ]; then
    new_notified=90
    secs=""; [ -n "$reset" ] && secs=$((reset - now))
    human_delta "$secs"
    printf '%s usage window at %s%% (crossed 90%%, critical) -- resets in %s.\n' \
      "$label" "$pct" "$__delta" >> "$NOTICES"
  elif [ "$pct" -ge 75 ] && [ "$prev_notified" -lt 75 ]; then
    new_notified=75
    secs=""; [ -n "$reset" ] && secs=$((reset - now))
    human_delta "$secs"
    printf '%s usage window at %s%% (crossed 75%%) -- resets in %s.\n' \
      "$label" "$pct" "$__delta" >> "$NOTICES"
  fi
  local new_scheduled="$prev_scheduled"
  if [ "$pct" -ge 99 ]; then
    new_scheduled="$(schedule_resume "$reset" "$prev_scheduled")"
  fi
  printf '{"notified":%s,"resets_at":"%s","scheduled_for":"%s"}\n' \
    "$new_notified" "$reset" "$new_scheduled" > "$statefile"
}

check_window "five_hour" "$five_pct" "$five_reset" "5-hour"
check_window "seven_day" "$week_pct" "$week_reset" "Weekly"

# check_context -- context-window equivalent of check_window, but PER-SESSION (context
# isn't account-wide like the rate-limit windows, so state/notice files key off $sid).
# Fires once at 60%/80%, re-arms below 60% -- catches a session that fills, /compact's,
# then fills again. Notice goes to .ctx-notices-$sid, relayed+cleared by on-prompt.sh
# for THIS session only -- a shared file here would leak session A's notice into
# session B's next reply. See skills/context-hygiene/SKILL.md trigger 3.
check_context() {
  local pct="$1"
  [ -n "$pct" ] && [ -n "$sid" ] || return 0
  local statefile="$STATE/ctx-$sid"
  local ctx_notices="$HOME/.claude/.ctx-notices-$sid"
  # Same own-format bash parse/write as check_window -- see the comment there.
  local prev_notified=0 state_line=""
  if [ -f "$statefile" ]; then
    IFS= read -r state_line < "$statefile" 2>/dev/null
    [[ "$state_line" =~ \"notified\":([0-9]+) ]] && prev_notified="${BASH_REMATCH[1]}"
  fi
  if [ "$pct" -lt 60 ]; then
    prev_notified=0
  fi
  local new_notified="$prev_notified"
  if [ "$pct" -ge 80 ] && [ "$prev_notified" -lt 80 ]; then
    new_notified=80
    printf 'Context window at %s%% (crossed 80%%) -- consider /compact (same task) or /clear (new task) soon.\n' \
      "$pct" >> "$ctx_notices"
  elif [ "$pct" -ge 60 ] && [ "$prev_notified" -lt 60 ]; then
    new_notified=60
    printf 'Context window at %s%% (crossed 60%%) -- consider /compact (same task) or /clear (new task) when convenient.\n' \
      "$pct" >> "$ctx_notices"
  fi
  printf '{"notified":%s}\n' "$new_notified" > "$statefile"
}

check_context "$ctx_pct"

# Countdown suffix once a window is effectively exhausted -- resets_at/now are
# recomputed fresh on every render, so this ticks down for free with no separate poller;
# Claude Code already re-invokes this script continuously while the terminal sits idle.
# Sets $__suffix -- same no-print reasoning as color_for.
resuming_suffix() {
  local pct="$1" reset="$2"
  __suffix=""
  [ "$pct" -ge 99 ] && [ -n "$reset" ] || return 0
  human_delta $((reset - now))
  __suffix=" (resuming $__delta)"
}

bar="$model"
if [ -n "$ctx_pct" ]; then
  color_for_ctx "$ctx_pct"
  bar="$bar | ${__color}ctx:${ctx_pct}%\033[0m"
fi
if [ -n "$five_pct" ]; then
  color_for "$five_pct"; resuming_suffix "$five_pct" "$five_reset"
  bar="$bar | ${__color}5h:${five_pct}%${__suffix}\033[0m"
fi
if [ -n "$week_pct" ]; then
  color_for "$week_pct"; resuming_suffix "$week_pct" "$week_reset"
  bar="$bar | ${__color}wk:${week_pct}%${__suffix}\033[0m"
fi
printf '%b\n' "$bar"
