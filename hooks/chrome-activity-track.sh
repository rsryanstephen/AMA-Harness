#!/usr/bin/env bash
# PostToolUse hook (matcher mcp__claude-in-chrome__.*). Records the prompt number of the
# latest claude-in-chrome call in .chrome-active-<sid>. on-prompt.sh reads it: two prompts
# with no browser call = verify loop over -> nudge "close tabs + /compact" WITHOUT relying
# on tabs_close_mcp ever being called (user 2026-09-14: the tab-close-only trigger missed
# every forgotten tab). Same one-shot guard as chrome-verify-compact-nudge.sh, so the two
# never double-fire; chrome-compact-rearm.sh clears both on /compact.
set -u
payload="$(cat)"
# A browser call naming a dev server's port (localhost:4210, [::1]:4211) = that server is in
# use: refresh its marker so dev-server-teardown-reminder.sh's idle kill leaves it alone
# (<harnessEpicKey>, 2026-10-12). Glob + case, no fork.
source "${BASH_SOURCE[0]%/*}/lib-devserver-teardown.sh"
for _m in "$DEVSERVER_STATE"/devserver-*; do
  [ -f "$_m" ] && devserver_is_marker "$_m" || continue
  _p="${_m##*-}"
  case "$payload" in *":$_p"[!0-9]*|*":$_p") touch -c "$_m" 2>/dev/null ;; esac
done
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
[ -n "$sid" ] || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/lib-claude-paths.sh"
pn=0
pnf="$HOME/.claude/.session-chatfiles/$sid.promptn"
[ -f "$pnf" ] && read -r pn < "$pnf" 2>/dev/null
case "$pn" in ''|*[!0-9]*) pn=0 ;; esac
printf '%s' "$pn" > "$(hstate sessions ".chrome-active-$sid")"
exit 0
