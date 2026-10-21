#!/usr/bin/env bash
# SessionStart hook, matcher "compact". chrome-verify-compact-nudge.sh and on-prompt.sh's
# idle-browser check share a one-shot guard (below) so a session nudges /compact once, not
# per tab close or per prompt. A /compact is the user ACTING on that nudge -- the
# screenshots are gone, so the next verify loop in this same session deserves a fresh
# nudge. Delete the guard here, plus the activity marker chrome-activity-track.sh wrote
# (stale activity from before the compact must not trigger the idle nudge afterwards).
# /clear needs nothing: new session id -> new paths.
set -u
payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
[ -n "$sid" ] || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/lib-claude-paths.sh"
rm -f "$(hstate sessions ".usage-state/chrome-compact-nudged-$sid")" \
      "$(hstate sessions ".chrome-active-$sid")"
exit 0
