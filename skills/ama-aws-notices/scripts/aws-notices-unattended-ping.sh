#!/usr/bin/env bash
# Unattended weekly DETECTION ping for AWS notices -- never judgment. Scheduled-task
# target (AMA-Harness-AWS-Notices-Ping, weekly, InteractiveToken: runs only while the
# user is logged on -- same guarantee level as fleet-health/embs). The in-session nudge
# (hooks/aws-notices-check.sh) stays the primary scheduler; this exists solely for the
# "no Claude session opened for weeks" hole that nudge structurally can't cover. Direct
# port of embs-notices-unattended-ping.sh's shape -- same problem, same fix.
#
# What it deliberately NEVER does: read notice/case content, tier anything, or write
# .aws-notices-lastrun/-seen. The skill's own header says why an unattended runner was
# skipped there: "an unattended wrong verdict would mark an event seen forever" --
# detection is safe to automate, judgment is not. This script only ever detects staleness
# and asks a human to run the real skill.
set -uo pipefail

# Task Scheduler defaults a task's working directory to %windir%\System32 when nothing
# sets one -- confirmed real via this script's standup-notes sibling (two dead sessions
# logged with cwd C:\WINDOWS\system32, never got a chat file at all, unwritable there).
harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
cd "${harness:-$HOME}" 2>/dev/null || true

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

LOG="$(hstate logs aws-notices-ping.log)"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

LASTRUN="$(hstate notices .aws-notices-lastrun)"
NUDGED="$(hstate notices .aws-notices-nudged)"
PINGED="$(hstate notices .aws-notices-pinged)"
DIGEST="$(hstate notices .aws-notices-digest)"

check_days="$(hr_config '.awsNotices.checkDays' 7)"
today="$(date +%F)"
cutoff="$(date -d "$check_days days ago" +%F 2>/dev/null)" || { log "date arithmetic failed"; exit 1; }

# 1. Not overdue -> quiet exit (the nudge hasn't fired either; nothing to say).
last="(never)"
if [ -s "$LASTRUN" ]; then
  last="$(tr -d ' \r\n' < "$LASTRUN")"
  if ! [ "$last" \< "$cutoff" ]; then exit 0; fi
fi

# 2. A session surfaced the staleness nudge within the window -> the user is around and
# already being nudged in-session; a Slack ping on top is duplicate noise.
if [ -s "$NUDGED" ]; then
  nudged="$(tr -d ' \r\n' < "$NUDGED")"
  if ! [ "$nudged" \< "$cutoff" ]; then log "skip: in-session nudge surfaced $nudged"; exit 0; fi
fi

# 3. Own throttle -- at most one ping per check_days even if the task fires more often.
if [ -s "$PINGED" ]; then
  pinged="$(tr -d ' \r\n' < "$PINGED")"
  if ! [ "$pinged" \< "$cutoff" ]; then exit 0; fi
fi

TARGET="$(hr_config '.awsNotices.reportTarget' '')"
[ -n "$TARGET" ] || { log "no .awsNotices.reportTarget configured -- nothing to ping"; exit 0; }

if ! command -v claude >/dev/null 2>&1; then
  log "claude CLI not on PATH -- cannot run headless"
  printf 'Unattended AWS ping FAILED %s: claude CLI not on PATH (task env). In-session staleness nudge still active.\n' "$today" >> "$DIGEST"
  exit 1
fi
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 120"

# Same framing the in-session nudge already uses (hooks/aws-notices-check.sh) -- the
# ElastiCache EOL miss is why this monitor exists, keep it visible.
msg="$(hr_self_mention "$TARGET")AWS notice sweep is overdue: last run $last, threshold ${check_days}d. Open a Claude session and run the ama-aws-notices skill. A missed ElastiCache EOL notice cost ~\$7.5k/yr in extended-support fees before this existed -- treat it as real work, not a chore. [automated weekly ping -- fires only when no session has shown the in-session nudge for ${check_days}d]"

out="$($TO claude -p "Call mcp__claude_ai_Slack__slack_send_message with channel_id $TARGET and this exact message text: $msg -- then reply with ONLY the word DONE, or FAILED: and the error." \
  --model haiku --allowedTools mcp__claude_ai_Slack__slack_send_message 2>>"$LOG")" || out=""
case "$out" in *"spend limit"*|*"usage limit"*|*"rate limit"*) printf '%s %s\n' "$(date '+%F %T')" "$(basename "$0")" >> "$(hstate notices unattended-blocked.txt)"; log "BLOCKED by a spend/usage limit -- no work done this run";; esac
case "$out" in
  *DONE*)
    printf '%s\n' "$today" > "$PINGED"
    printf 'Unattended AWS ping %s: sweep overdue (last run %s); Slack ping sent to the configured target.\n' "$today" "$last" >> "$DIGEST"
    log "pinged $TARGET: overdue since $last"
    ;;
  *)
    printf 'Unattended AWS ping FAILED %s: Slack send did not confirm (%s). In-session staleness nudge still active.\n' "$today" "$(printf '%s' "$out" | head -c 1200)" >> "$DIGEST"
    # 4000, not 200: a 200-char cap truncated a security finding out of existence in a
    # sibling runner (7892af6), and a failure reply is exactly where detail matters.
    log "slack send failed: $(printf '%s' "$out" | head -c 4000)"
    exit 1
    ;;
esac
