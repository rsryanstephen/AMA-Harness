#!/usr/bin/env bash
# PostToolUse hook (mcp__claude-in-chrome__tabs_close_mcp). Closing a verify tab means
# a claude-in-chrome loop just ended -- its screenshots (base64, confirmed the biggest
# single driver of claude-in-chrome's context cost, see session-ctx-sizes.pl's own
# header) have served their purpose and never need to be carried forward. Mechanical
# backstop for ama-ui-verify's "recommend /compact after a verify loop" rule -- a skill
# line alone relies on self-recognition (CLAUDE.md: unreliable). Writes into the SAME
# per-session notice file statusline.sh's check_context uses (.ctx-notices-$sid),
# relayed by on-prompt.sh -- no new pipeline. One-shot per session so a multi-tab
# verify loop doesn't nag on every close.
set -u

payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
[ -n "$sid" ] || exit 0

STATE="$HOME/.claude/harness-state/sessions/.usage-state"; mkdir -p "$STATE"
statefile="$STATE/chrome-compact-nudged-$sid"
[ -f "$statefile" ] && exit 0
touch "$statefile"

mkdir -p "$HOME/.claude/harness-state/sessions" 2>/dev/null
printf 'Closed a claude-in-chrome verify tab. Claude-in-Chrome context from UI verification (base64 screenshots, page reads) has piled up and uses a lot of tokens on every later turn. Recommend /compact now if this verify loop is finished.\n' \
  >> "$HOME/.claude/harness-state/sessions/.ctx-notices-$sid"
