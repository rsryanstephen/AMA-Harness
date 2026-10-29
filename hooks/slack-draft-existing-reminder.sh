#!/usr/bin/env bash
# PreToolUse reminder (warn-only, never denies) on slack_send_message_draft.
#
# Slack's draft API only CREATES. A chat that already holds a draft keeps it and silently drops
# ours, yet the call still reports "Draft created" (proven 2026-10-12, <uiTesterName> DM; again
# 2026-10-27, Reviewer Two DM: the compliance-ticket draft vanished behind an older SFTP one). No tool
# lists or reads drafts, so the existing-draft state cannot be checked -- the only safe habit is
# to hand the user the full paste text in the reply as well. See memory/slack-message-edit-request.md.
#
# Extra signal we do have: the follow-up ledger records the id of a draft we left unsent
# ("draft_id Dr..."). When the target channel/user id appears on such a row, say so by key.
#
# Emits hookSpecificOutput.additionalContext with NO permissionDecision (an explicit allow could
# override a sibling gate -- same rule as audience-policy-gate.sh).
set -u

payload="$(cat)"
case "$payload" in
  *slack_send_message_draft*) ;;
  *) exit 0 ;;
esac

chan="$(printf '%s' "$payload" | jq -r '.tool_input.channel_id // empty' | tr -d '\r')"

known=""
ledger="${FOLLOWUPS_FILE:-$HOME/.claude/harness-state/notices/.pending-followups}"
if [ -n "$chan" ] && [ -f "$ledger" ]; then
  known="$(grep -F "$chan" "$ledger" 2>/dev/null | grep -F 'draft_id' | cut -f1 | tr -d '\r' | head -3 | paste -sd, -)"
fi

msg="SLACK DRAFT CAVEAT: this chat may already hold a draft, and Slack keeps it and silently drops yours while still answering \"Draft created\" -- no tool can read or list drafts. After this call, ALSO put the full draft text in your reply (paste-over text) and tell the user to check their Drafts."
if [ -n "$known" ]; then
  msg="$msg The follow-up ledger already records an UNSENT draft for this chat (row: $known) -- yours WILL be dropped; hand over the paste text instead of relying on the call."
fi

jq -n --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
exit 0
