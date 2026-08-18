#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Nudges Claude to run the
# ama-embs-notices skill once the last triage run is older than .embs.noticeCheckDays.
#
# This is the PRIMARY scheduler. Gmail is MCP-only, so no plain bash job can read the
# notices -- but headless `claude -p --allowedTools mcp__claude_ai_...` CAN (verified
# 2026-08-17), so a weekly scheduled task (AMA-Harness-EMBS-Notices-Ping ->
# skills/ama-embs-notices/scripts/embs-notices-unattended-ping.sh) backstops the one hole
# this nudge can't cover: no session opened for weeks. That ping DETECTS only (counts +
# Slack DM + digest line); triage judgment stays in-session on purpose -- an unattended
# wrong verdict would mark a notice seen forever. schtasks caveat applies: InteractiveToken,
# runs only while logged on.
#
# Pure bash, no network, two tiny state-file reads -- on-prompt.sh runs on EVERY prompt and
# is fork-cost/30s-timeout sensitive.
#
# The one-shot digest below is written by that unattended ping (or any future unattended
# runner), mirroring the .usage-notices pattern: read once, then truncate.
#
# Sets $embs_notices_notice (empty if nothing to say). Throttled once per calendar day.
embs_notices_notice=""
LASTRUN_FILE="$HOME/.claude/.embs-notices-lastrun"
NUDGED_FILE="$HOME/.claude/.embs-notices-nudged"
DIGEST_FILE="$HOME/.claude/.embs-notices-digest"
today="$(date +%F)"

# One-shot digest wins over the staleness nudge -- it carries actual findings.
if [ -s "$DIGEST_FILE" ]; then
  embs_notices_notice="eMBS notice triage found items needing attention: $(cat "$DIGEST_FILE") Surface these distinctly, then continue with the task."
  : > "$DIGEST_FILE"
  return 0 2>/dev/null || exit 0
fi

# Config read is deliberately defaulted here, unlike the skill's senders/prefix: a wrong
# cadence nudges too often, a wrong mailbox reads nothing. Only the latter is a real bug.
check_days=7
if [ -f "$HOME/.claude/harness-config.json" ]; then
  v="$(jq -r '.embs.noticeCheckDays // empty' < "$HOME/.claude/harness-config.json" 2>/dev/null | sed 's/\r$//')"
  case "$v" in ''|*[!0-9]*) ;; *) check_days="$v" ;; esac
fi

due=0
if [ ! -s "$LASTRUN_FILE" ]; then
  due=1
else
  last="$(tr -d ' \r\n' < "$LASTRUN_FILE")"
  cutoff="$(date -d "$check_days days ago" +%F 2>/dev/null || true)"
  # last < cutoff  =>  overdue. String compare is safe on YYYY-MM-DD.
  [ -n "$last" ] && [ -n "$cutoff" ] && [ "$last" \< "$cutoff" ] && due=1
fi

if [ "$due" = "1" ]; then
  last_nudge="$(cat "$NUDGED_FILE" 2>/dev/null || true)"
  if [ "$last_nudge" != "$today" ]; then
    embs_notices_notice="eMBS Data Notices have not been triaged in over $check_days days -- run the ama-embs-notices skill. A vendor change announced in one of these and missed cost a production incident before, so treat it as real work, not a chore."
    printf '%s\n' "$today" > "$NUDGED_FILE"
  fi
fi
