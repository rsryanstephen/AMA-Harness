#!/usr/bin/env bash
# PostToolUse hook (Bash|PowerShell), dispatched. Records the dev servers Claude tool calls
# start, and KILLS any of them -- from ANY session -- once idle. Name kept for its wiring;
# since 2026-10-12 it no longer only reminds.
#
# Why. ama-ui-verify launches `ng serve` / `python -m http.server` with run_in_background
# and they outlive their verification: 4210 + an http.server sat for hours (2026-09-14), an
# npm-start server on 4201 for hours (2026-10-12), and a 3 GB `ng serve` from another
# session took available RAM to 2.7 GB while Defender was busy and every terminal crawled
# (2026-10-12). The once-per-port nudge this hook used to send was ignored, and nothing
# reaped a server whose session was idle or gone. User rule (2026-10-12): be strict about
# stopping superfluous processes. Mechanical Triggers Over Self-Recognition: a hook kills.
#
# Detects by PORT, not the background-task list: TaskStop kills the wrapper bash and the
# `npx ng serve` node CHILD survives holding the port (2026-09-14), so the task list lies.
#
# RECORD (on the starting call): `ng serve --port N` / `http.server N` for ANY N, or for an
# npm start script / bare `ng serve`, the angular.json port (usually the user's 4200/4201).
# Recorded only if the port was FREE at launch -- busy means someone else's server (ours
# would fail to bind) and it must never be claimed. Marker: devserver-<sid>-<port>, content
# filled with the listener PID on first sight.
#
# IN USE = marker mtime, refreshed (no fork) whenever any Bash/PowerShell payload mentions
# `:<port>` -- curl, a verify script's URL, netstat -- and by chrome-activity-track.sh for a
# browser call naming it, and here whenever an ESTABLISHED TCP connection sits on the port
# (a tab open on it, including the user's own local sign-off). A marker whose port is not
# listening YET stays until IDLE_SECS old (compile window, 2026-10-19), see the sweep.
#
# KILL when: marker untouched for IDLE_SECS (20 min) AND no ESTABLISHED connection AND the
# listener is still the PID we recorded (lib PID guard -- a stranger on a reused port is
# never killed), AND no unexpired hold (scripts/devserver-hold.sh, for the user's sign-off). Sweeps EVERY session's markers, so an idle or dead session's server is
# reaped by whichever session runs next; markers only ever exist for servers a Claude tool
# call started, so the user's own servers are never candidates. Tells Claude what it killed
# (decision:block, informational) so a still-needed server gets restarted, not mourned.
#
# Fork budget: @ALWAYS in the dispatcher (its trigger is "a marker exists", not payload
# text). No markers anywhere = exit before any fork. Netstat probe throttled per session.
set -u

IDLE_SECS="${AMA_DEVSERVER_IDLE_SECS:-1200}"
PROBE_SECS="${AMA_DEVSERVER_PROBE_SECS:-300}"

IFS= read -r -d '' payload || true
source "${BASH_SOURCE[0]%/*}/lib-devserver-teardown.sh"
STATE="$DEVSERVER_STATE"   # honours CLAUDE_STATE_DIR -- see the lib's seam note

starting=0
case "$payload" in *"ng serve"*|*"http.server"*|*"run start"*) starting=1 ;; esac

# Any markers at all? Glob, no fork. None and not starting = nothing to do.
markers=()
for _m in "$STATE"/devserver-*; do
  [ -f "$_m" ] && devserver_is_marker "$_m" && markers+=("$_m")
done
[ "$starting" = 1 ] || [ "${#markers[@]}" -gt 0 ] || exit 0

# --- in use: a payload naming the port refreshes that marker (no fork) ------------------
for _m in "${markers[@]}"; do
  _p="${_m##*-}"
  case "$payload" in *":$_p"[!0-9]*|*":$_p") touch -c "$_m" 2>/dev/null ;; esac
done

sid=""
[[ $payload =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]+)\" ]] && sid="${BASH_REMATCH[1]}"
[ -n "$sid" ] || exit 0
mkdir -p "$STATE" 2>/dev/null

# --- record -------------------------------------------------------------------------------
if [ "$starting" = 1 ]; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  port="$(printf '%s' "$cmd" | grep -oE '[-][-]port[= ]+[0-9]+' | grep -oE '[0-9]+$' | head -1)"
  if [ -z "$port" ]; then
    port="$(printf '%s' "$cmd" | grep -oE 'http\.server[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' | head -1)"
  fi
  if [ -z "$port" ]; then
    case "$cmd" in
      *"run start"*|*"ng serve"*)
        dir="$(printf '%s' "$cmd" | grep -oE '[-][-]prefix[= ]+[^ ;&|]+' | head -1 | sed -E 's/^--prefix[= ]+//')"
        [ -n "$dir" ] || dir="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
        [ -n "$dir" ] && [ -f "$dir/angular.json" ] && \
          port="$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$dir/angular.json" | grep -oE '[0-9]+$' | head -1)"
        [ -n "$dir" ] && [ -f "$dir/angular.json" ] && [ -z "$port" ] && port=4200
        ;;
    esac
  fi
  [ -n "$port" ] || exit 0
  # Busy already = someone else's server (ours would fail to bind) -- often the user's own on
  # 4200/4201. Never claim it, or the first sweep would adopt THEIR PID as ours.
  devserver_listen_text | awk -v p=":$port" '$1=="TCP" && toupper($4)=="LISTENING" && substr($2, length($2)-length(p)+1)==p {f=1} END{exit !f}' \
    || : > "$STATE/devserver-$sid-$port" 2>/dev/null
  exit 0
fi

# --- sweep (throttled per session) --------------------------------------------------------
now=$EPOCHSECONDS
probe_stamp="$STATE/devserver-probed-$sid"
if [ -f "$probe_stamp" ]; then
  age=$(( now - $(stat -c %Y "$probe_stamp" 2>/dev/null || echo 0) ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$PROBE_SECS" ] && exit 0
fi
touch "$probe_stamp" 2>/dev/null

text="$(devserver_listen_text)"
killed=""
for marker in "${markers[@]}"; do
  [ -f "$marker" ] || continue
  port="${marker##*-}"
  b="${marker##*/}"; msid="${b#devserver-}"; msid="${msid%-"$port"}"
  pid="$(printf '%s\n' "$text" | awk -v p=":$port" '$1=="TCP" && toupper($4)=="LISTENING" && substr($2, length($2)-length(p)+1)==p {print $5; exit}')"

  # Not listening: torn down already (or never came up) -- drop the marker, stay silent. But a
  # YOUNG marker is a server still compiling (`ng serve` here takes ~3 min before it listens):
  # dropping it left the reaper (reap-orphan-conhost.ps1) no marker to spare, and it killed a
  # live dev server on 2026-10-19 12:28, after the 10-16 fix. Keep it; the idle window decides.
  if [ -z "$pid" ]; then
    m_age=$(( now - $(stat -c %Y "$marker" 2>/dev/null || echo 0) ))
    [ "$m_age" -lt "$IDLE_SECS" ] && continue
    rm -f -- "$marker" "$STATE/devserver-nudged-$msid-$port" 2>/dev/null
    continue
  fi
  # First sight: record the listener PID, keeping the in-use time (mtime) unchanged -- but
  # ONLY while the marker is young. A PID-less marker older than the idle window cannot be
  # attributed: whatever listens now may be a different server that took the port later.
  # Drop it, never kill. Without this, the hook's first live run (2026-10-12 18:35) adopted
  # a stale test marker and killed another session's in-use `ng serve` on 4210.
  if [ ! -s "$marker" ]; then
    m_age=$(( now - $(stat -c %Y "$marker" 2>/dev/null || echo "$now") ))
    if [ "$m_age" -ge "$IDLE_SECS" ]; then
      rm -f -- "$marker" "$STATE/devserver-nudged-$msid-$port" 2>/dev/null
      continue
    fi
    printf '%s\n' "$pid" > "$marker.tmp" 2>/dev/null && touch -r "$marker" "$marker.tmp" 2>/dev/null \
      && mv -f "$marker.tmp" "$marker" 2>/dev/null
  fi
  # The sweep kills only a server whose PID it recorded itself; re-read to be sure.
  rec=""; read -r rec < "$marker" 2>/dev/null; rec="${rec%$'\r'}"
  [ "$rec" = "$pid" ] || { rm -f -- "$marker" 2>/dev/null; continue; }
  # Held for the user's own sign-off (scripts/devserver-hold.sh): nobody touches the port
  # until the user opens it, which is exactly when an idle kill strands them (2026-10-15).
  # File content = expiry epoch; past expiry the hold is dropped and the idle rule resumes.
  hold=""; read -r hold < "$STATE/devserver-hold-$port" 2>/dev/null; hold="${hold%$'\r'}"
  if [[ $hold =~ ^[0-9]+$ ]]; then
    if [ "$hold" -gt "$now" ]; then touch -c "$marker" 2>/dev/null; continue; fi
    rm -f -- "$STATE/devserver-hold-$port" 2>/dev/null
  fi
  # An open connection on the port = in use (local side or remote side naming it).
  if printf '%s\n' "$text" | awk -v p=":$port" 'toupper($4)=="ESTABLISHED" && (substr($2, length($2)-length(p)+1)==p || substr($3, length($3)-length(p)+1)==p) {f=1} END{exit !f}'; then
    touch -c "$marker" 2>/dev/null
    continue
  fi
  started="$(stat -c %Y "$marker" 2>/dev/null || echo "$now")"
  [ $(( now - started )) -ge "$IDLE_SECS" ] || continue

  k="$(devserver_kill_marker "$marker" "$text")"
  [ -n "$k" ] || continue
  who="this session"; [ "$msid" = "$sid" ] || who="session ${msid:0:8}"
  killed="${killed}${killed:+, }port ${k% *} (PID ${k#* }, started by ${who})"
done

[ -n "$killed" ] || exit 0
log="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/logs/dev-server-reap.log"
[ -d "${log%/*}" ] || mkdir -p "${log%/*}" 2>/dev/null
printf '%(%Y-%m-%dT%H:%M:%S)T by=%s idle>=%ss %s\n' -1 "${sid:0:8}" "$IDLE_SECS" "$killed" >> "$log" 2>/dev/null
jq -cn --arg k "$killed" --arg m "$(( IDLE_SECS / 60 ))" '{
  decision: "block",
  reason: ("Idle dev server(s) killed to keep memory free: " + $k + ". Rule (<harnessEpicKey>): a server a Claude session started is stopped after " + $m + " minutes with no command, browser call or open connection touching its port. If one is still needed, start it again the same way (npx ng serve ... --port N, run_in_background), about 1-2 minutes. Nothing to do otherwise.")
}'
exit 0
