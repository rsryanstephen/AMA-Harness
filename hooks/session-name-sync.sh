#!/usr/bin/env bash
# PostToolUse hook, matcher "*" (every tool call, every session). Keeps the one-name-
# per-session sync (lib-fallback-rename.sh's sync_session_name) from waiting for Stop.
# Without this, a long turn -- hours, for a scheduled monitor session -- leaves the
# chat file, sessions.txt and sessions.md stale for its whole duration even though
# Claude Code's own aiTitle/agentName/customTitle can change mid-turn (confirmed real:
# session 1ce24e66 re-titled 4 times across one multi-hour turn, none of which reached
# sessions.txt until the turn finally ended). on-stop.sh's own sync stays as the
# authoritative end-of-turn pass; this is just an earlier chance to converge.
#
# Throttled BEFORE any real work: a `.namesync` statefile timestamp gates this to once
# per 120s per session, cheap enough (one stat) to tolerate firing after every tool
# call. This is a timing optimization only -- sync_session_name's own basename check is
# the real idempotence guarantee, so firing this more or less often is always safe.
set -u

IFS= read -r -d '' payload || true
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
[ -n "$sid" ] || exit 0
[ -n "$cwd" ] || exit 0
# Headless/`-p`/SDK invocation -- see on-prompt.sh's matching guard for the full
# rationale. Nothing to keep in sync for a session with no display row.
source "${BASH_SOURCE[0]%/*}/lib-session-kind.sh"
session_is_headless "$tr_path" && exit 0
cwd="$(printf '%s' "$cwd" | tr '\134' '/')"
case "$cwd" in */.session-chatfiles) cwd="${cwd%/.session-chatfiles}" ;; esac

STATED="$HOME/.claude/.session-chatfiles"
THROTTLE="$STATED/$sid.namesync"
now="$(date +%s)"
last=0
[ -f "$THROTTLE" ] && last="$(cat "$THROTTLE" 2>/dev/null)"
[ -n "$last" ] || last=0
if [ $((now - last)) -lt 120 ]; then
  exit 0
fi
mkdir -p "$STATED" 2>/dev/null
printf '%s' "$now" > "$THROTTLE" 2>/dev/null

source "$(dirname "${BASH_SOURCE[0]}")/lib-chatfile-link.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-fallback-rename.sh"

SF="$STATED/$sid"
default="$(chatfile_default_path "$cwd" "$sid")"
if [ -f "$SF" ]; then chat="$(cat "$SF")"; else chat="$default"; fi
[ -f "$chat" ] || exit 0

old_base="$(basename "$chat")"
sync_session_name "$sid" "$chat" "$(dirname "$chat")" "$tr_path"

# If that actually renamed the file, tell Claude the new path NOW -- flush-reply.sh's
# reverse lookup (scan .session-chatfiles/* for the statefile pointing at a given path)
# hard-fails on the stale pre-rename path, and the dequeue-before-ending-turn
# convention calls it in exactly this window. additionalContext, not {decision:"block"}:
# the tool succeeded, and block renders as a red "blocking error" in the UI.
new_chat=""
[ -f "$SF" ] && new_chat="$(cat "$SF")"
if [ -n "$new_chat" ] && [ "$new_chat" != "$chat" ]; then
  new_base="$(basename "$new_chat")"
  jq -cn --arg r "Session renamed: the chat file is now \"$new_base\" (Claude Code's own session name changed). If you call flush-reply.sh or dequeue-prompt.sh before this turn ends, use this new path, not the old one: $new_chat" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$r}}'
fi
exit 0
