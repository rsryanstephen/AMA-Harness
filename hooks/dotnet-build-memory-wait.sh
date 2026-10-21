#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell), dispatched via dispatch-pre-bash.manifest. Before a
# `dotnet build|test|publish` starts, WAIT while BOTH hold: free memory is under a floor
# AND another .NET build client is already running (any session). Polls until either
# clears, bounded, then lets the command run and says how long it waited. Never denies.
#
# Why (<harnessEpicKey>, 2026-09-27): the paging episode was two `dotnet test` runs from
# two sessions at once -- ~15 MSBuild nodes plus a test host each -- on a box already at
# 1.3 GB free. Cleanup hooks only shorten the aftermath; this is the one that prevents the
# overlap. User rule: a session MAY wait for another session's build to keep memory from
# piling up, but must never wait when there is plenty to spare. Hence two conditions, and
# the memory test runs first: with room, nothing here costs a fork.
#
# Memory = MemFree from MSYS's /proc/meminfo, which tracks Windows "available" physical
# memory (standby cache included) -- read in the same moment they agreed within ~100 MB
# (2026-09-27). Bash loop, no fork. Unreadable -> treated as plenty (fail open). Floor default
# 6144 MB: one `dotnet test` run here peaks around 3.5 GB, so 6 GB free lets one more start
# without touching the page file. Build-in-flight = lib-dotnet-inflight.sh's process probe
# (one powershell fork, only on the tight-memory path).
#
# Bounds. Poll every 15s; give up after MAX_SECS, then proceed with a warning. A wait that
# outlives the Pre dispatcher's block timeout gets the WHOLE block killed -- every gate's
# decision on that call lost, failing open. The timeout comes from settings.json and loads
# at session START, while the manifest is read live, so sessions older than 2e94795 still
# have 120s. Hence: default 70s (worst case ~86s with poll overshoot, room for the other
# gates under 120); settings.json's env block sets AMA_BUILD_WAIT_MAX_SECS=540 alongside the
# 660s block timeout, and both arrive in the same new session, so they can't mismatch.
# Speaks (additionalContext) ONLY after an actual wait. Log
# harness-state/logs/dotnet-build-wait.log gets a `waiting` line BEFORE the first sleep (a
# Pre hook silent for minutes looks like a frozen tool call -- check this log for an open
# wait) and an end line with why it ended.
#
# Seams: AMA_BUILD_WAIT_FREE_MB (canned free MB), AMA_DOTNET_INFLIGHT (canned count),
# AMA_BUILD_WAIT_MIN_FREE_MB, AMA_BUILD_WAIT_MAX_SECS, AMA_BUILD_WAIT_POLL_SECS.
set -u
IFS= read -r -d '' payload || true
case "$payload" in
  *'dotnet test'*|*'dotnet build'*|*'dotnet publish'*|*'dotnet.exe test'*|*'dotnet.exe build'*|*'dotnet.exe publish'*|*'dotnet.exe\" test'*|*'dotnet.exe\" build'*|*'dotnet.exe\" publish'*) ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0
flat="$(printf '%s' "$command" | tr -d '\r' | tr '\n' ';')"
# Same command-position test as dotnet-build-server-shutdown.sh: an invocation, not a mention.
printf '%s' "$flat" | grep -qE '(^|[;&|(]|&&|\$\()[[:space:]]*(["'"'"']?[^;&|]*[/\\])?dotnet(\.exe)?["'"'"']?[[:space:]]+(test|build|publish)([[:space:]]|$)' || exit 0

MIN_FREE_MB="${AMA_BUILD_WAIT_MIN_FREE_MB:-6144}"
MAX_SECS="${AMA_BUILD_WAIT_MAX_SECS:-70}"
POLL_SECS="${AMA_BUILD_WAIT_POLL_SECS:-15}"

free_mb() {
  local k v _ kb=""
  if [ -n "${AMA_BUILD_WAIT_FREE_MB:-}" ]; then printf '%s' "$AMA_BUILD_WAIT_FREE_MB"; return; fi
  while read -r k v _; do
    [ "$k" = "MemFree:" ] && { kb="$v"; break; }
  done < /proc/meminfo 2>/dev/null
  case "$kb" in ''|*[!0-9]*) printf '%s' 999999 ;; *) printf '%s' $((kb / 1024)) ;; esac
}

free="$(free_mb)"
[ "$free" -lt "$MIN_FREE_MB" ] || exit 0

source "${BASH_SOURCE[0]%/*}/lib-dotnet-inflight.sh"
inflight="$(dotnet_inflight_count)"
[ "$inflight" -gt 0 ] || exit 0

free0="$free"; inflight0="$inflight"
sid8="-"
[[ $payload =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([0-9a-f]{8}) ]] && sid8="${BASH_REMATCH[1]}"
log="$HOME/.claude/harness-state/logs/dotnet-build-wait.log"
[ -d "${log%/*}" ] || mkdir -p "${log%/*}" 2>/dev/null
# Breadcrumb BEFORE the first sleep: a killed wait must still leave a trace (header).
printf '%(%Y-%m-%dT%H:%M:%S)T sid=%s waiting free=%sMB inflight=%s max=%ss\n' -1 "$sid8" "$free0" "$inflight0" "$MAX_SECS" >> "$log" 2>/dev/null
start=$EPOCHSECONDS; waited=0; why=""
while :; do
  sleep "$POLL_SECS"
  waited=$(( EPOCHSECONDS - start ))
  free="$(free_mb)"
  if [ "$free" -ge "$MIN_FREE_MB" ]; then why="free memory recovered to ${free} MB"; break; fi
  inflight="$(dotnet_inflight_count)"
  if [ "$inflight" -eq 0 ]; then why="the other build finished"; break; fi
  if [ "$waited" -ge "$MAX_SECS" ]; then why="gave up after ${MAX_SECS}s with ${inflight} build(s) still running and ${free} MB free"; break; fi
done

printf '%(%Y-%m-%dT%H:%M:%S)T sid=%s waited=%ss free=%sMB inflight=%s end=%s\n' -1 "$sid8" "$waited" "$free0" "$inflight0" "$why" >> "$log" 2>/dev/null

jq -cn --arg w "$waited" --arg f "$free0" --arg m "$MIN_FREE_MB" --arg n "$inflight0" --arg why "$why" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: ("Build serialised (warn-only, the command runs now): waited " + $w + "s before this dotnet command because free memory was " + $f + " MB (floor " + $m + ") and " + $n + " other dotnet build/test client(s) were running -- two concurrent runs paged this machine on 2026-09-27. Ended because " + $why + ". Tell the user a wait happened if it was long.")
  }
}'
exit 0
