#!/usr/bin/env bash
# PostToolUse hook (mcp__claude-in-chrome__tabs_close_mcp). Closing the verify tab is the
# nearest thing an interactive `--chrome` verify loop has to a "done" event, so the dev
# server(s) THIS session started die right then -- not ~25 min later
# (dev-server-teardown-reminder.sh, a nudge) and not at exit (on-session-end.sh).
#
# Why (<harnessEpicKey>, 2026-09-27): the box paged at 1.3 GB free with an `ng serve` at
# 3.7 GB still up in a worktree whose verification was long over. The reminder had fired
# and been ignored; nothing mechanical ran until session end. User rule: clean up the
# moment the work is done, and a tab close is the moment.
#
# Same sibling as chrome-verify-compact-nudge.sh (same matcher), kept separate because
# that one is one-shot per session and this must fire every time. Kill scope is the
# session's own markers only (lib-devserver-teardown.sh) -- another session's server on
# the same pinned port is untouched. Says what it killed via decision:block so Claude can
# restart it (`npx ng serve ... --port N`, 1-2 min) if the loop was NOT actually over;
# silent when nothing was listening. No fork until a marker for some session exists, and
# jq only when something was killed.
set -u
IFS= read -r -d '' payload || true

source "${BASH_SOURCE[0]%/*}/lib-devserver-teardown.sh"
set -- "$DEVSERVER_STATE"/devserver-*
[ -e "$1" ] || exit 0

sid=""
[[ $payload =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]+)\" ]] && sid="${BASH_REMATCH[1]}"
[ -n "$sid" ] || exit 0

killed="$(devserver_kill_session_ports "$sid")"
[ -n "$killed" ] || exit 0

list="$(printf '%s\n' "$killed" | awk '{printf "%sport %s (PID %s)", (NR>1?", ":""), $1, $2}')"
jq -cn --arg l "$list" '{
  decision: "block",
  reason: ("Verify tab closed, so the dev server this session started was killed: " + $l + ". That is the standing rule (server dies the moment the verification is done, <harnessEpicKey>). If the fix -> re-verify loop is NOT over, start it again the same way as before (npx ng serve ... --port N, run_in_background) -- about 1-2 minutes.")
}'
exit 0
