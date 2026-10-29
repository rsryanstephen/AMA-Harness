#!/usr/bin/env bash
# Stop hook. Makes the usage-limit resume audit mechanical (user rule 2026-10-21): when
# limit-resume-check.sh injected an audit (scripts/limit-resume.py audit -> limits/<sid>.owed),
# the reply must carry a `Limit-resume audit` section giving every in-flight item a status.
# Missing -> block once with the reason; the resumed turn (stop_hook_active) is never blocked
# again, and the owed marker is cleared either way so it cannot loop. Same block-once shape as
# deferred-window-reminder-check.sh. Zero forks when nothing is owed.
set -u
payload="$(cat)"
sid="$(printf '%s' "$payload" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$sid" ] || exit 0
owed="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/limits/$sid.owed"
[ -f "$owed" ] || exit 0
case "$payload" in *"stop_hook_active\":true"*) rm -f "$owed"; exit 0 ;; esac
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' | tr -d '\r')"
if [ -n "$tr_path" ] && [ -f "$tr_path" ] && tail -n 400 "$tr_path" 2>/dev/null | jq -s -r '
    [.[] | select(.type=="assistant")] | .[-12:][] | .message.content[]? | select(.type=="text") | .text' 2>/dev/null \
    | grep -qi 'limit-resume audit'; then
  rm -f "$owed"; exit 0
fi
rm -f "$owed"
jq -cn '{decision:"block", reason:"LIMIT-RESUME AUDIT MISSING: this session was cut off by the usage limit and the audit checklist was injected at the start of this turn, but the reply has no `Limit-resume audit` section. User rule 2026-10-21: after a usage limit, nothing in flight is left unfinished. Go back through the checklist (re-run `python ~/.claude/scripts/limit-resume.py audit <session-id>` is a no-op now -- use the injected list above), RESUME each item that is not finished, and end with a `Limit-resume audit` section giving every item its status: already done / resumed now / running in background <id> / not needed, and why."}'
exit 0
