#!/usr/bin/env bash
# Unattended weekly DETECTION ping for eMBS Data Notices -- never judgment. Scheduled-task
# target (AMA-Harness-EMBS-Notices-Ping, weekly, InteractiveToken: runs only while the
# user is logged on -- same guarantee level as the fleet-health task). The in-session
# nudge (hooks/embs-notices-check.sh) stays the primary scheduler; this exists solely for
# the "no Claude session opened for weeks" hole that nudge structurally can't cover.
#
# When triage is overdue AND no session has surfaced the nudge recently, it counts
# candidate emails via headless `claude -p` (Gmail is MCP-only; headless MCP access
# verified working 2026-08-17 -- a real search_threads/list_labels call executes under
# `claude -p --allowedTools ...`), Slack-DMs .embs.noticeReportTarget, and appends one
# line to .embs-notices-digest so the next session surfaces it too.
#
# What it deliberately NEVER does: read notice bodies, tier anything, or write
# .embs-notices-seen / -lastrun. An unattended wrong verdict would mark a notice seen
# forever; detection is safe to automate, judgment is not.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"

LOG="$HOME/.claude/embs-notices-ping.log"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

LASTRUN="$HOME/.claude/.embs-notices-lastrun"
NUDGED="$HOME/.claude/.embs-notices-nudged"
PINGED="$HOME/.claude/.embs-notices-pinged"
DIGEST="$HOME/.claude/.embs-notices-digest"

check_days="$(hr_config '.embs.noticeCheckDays' 7)"
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

TARGET="$(hr_config '.embs.noticeReportTarget' '')"
[ -n "$TARGET" ] || { log "no .embs.noticeReportTarget configured -- nothing to ping"; exit 0; }
PREFIX="$(hr_config_required '.embs.noticeSubjectPrefix')" || { log "config missing: noticeSubjectPrefix"; exit 1; }
FROMS="$(jq -r '[.embs.noticeSenders[]? | "from:" + .] | join(" ")' < "$HR_CONFIG_FILE" 2>/dev/null | sed 's/\r$//')"

if ! command -v claude >/dev/null 2>&1; then
  log "claude CLI not on PATH -- cannot run headless"
  printf 'Unattended eMBS ping FAILED %s: claude CLI not on PATH (task env). In-session staleness nudge still active.\n' "$today" >> "$DIGEST"
  exit 1
fi
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 300"

# Window for the counts: since lastrun (or the configured lookback floor on a first run).
if [ "$last" = "(never)" ]; then
  lookback="$(hr_config '.embs.noticeLookbackDays' 120)"
  since_q="$(date -d "$lookback days ago" +%Y/%m/%d)"
else
  since_q="$(date -d "$last" +%Y/%m/%d)"
fi

# Counts are context for the ping, not a gate on it -- suppressing the ping on a zero
# prefix count would re-import rule 1's subject-drift failure into the delivery path.
p="?"; s="?"
counts="$($TO claude -p "Run two Gmail searches with mcp__claude_ai_Gmail__search_threads, view THREAD_VIEW_METADATA_ONLY: first query: subject:\"$PREFIX\" after:$since_q -- second query: {$FROMS} after:$since_q -- then reply with ONLY this exact format and nothing else: P=<thread count of first> S=<thread count of second>" \
  --model haiku --allowedTools mcp__claude_ai_Gmail__search_threads 2>>"$LOG")" || counts=""
parsed="$(printf '%s' "$counts" | grep -oP 'P=\d+ S=\d+' | head -1)"
if [ -n "$parsed" ]; then
  p="${parsed#P=}"; p="${p%% *}"
  s="${parsed##*S=}"
else
  log "count call unparseable, pinging anyway: $(printf '%s' "$counts" | head -c 200)"
fi

msg="eMBS Data Notice triage is overdue: last run $last, threshold ${check_days}d. Since $since_q: $p subject-prefix candidate(s), $s sender-sweep candidate(s) (sender count includes routine flash/summary mails). Open a Claude session and run the ama-embs-notices skill. [automated weekly ping -- fires only when no session has shown the in-session nudge for ${check_days}d]"

out="$($TO claude -p "Call mcp__claude_ai_Slack__slack_send_message with channel_id $TARGET and this exact message text: $msg -- then reply with ONLY the word DONE, or FAILED: and the error." \
  --model haiku --allowedTools mcp__claude_ai_Slack__slack_send_message 2>>"$LOG")" || out=""
case "$out" in
  *DONE*)
    printf '%s\n' "$today" > "$PINGED"
    printf 'Unattended ping %s: triage overdue (last run %s); %s/%s candidates since %s; Slack ping sent to the configured target.\n' "$today" "$last" "$p" "$s" "$since_q" >> "$DIGEST"
    log "pinged $TARGET: overdue since $last, counts $p/$s"
    ;;
  *)
    printf 'Unattended eMBS ping FAILED %s: Slack send did not confirm (%s). In-session staleness nudge still active.\n' "$today" "$(printf '%s' "$out" | head -c 120)" >> "$DIGEST"
    log "slack send failed: $(printf '%s' "$out" | head -c 200)"
    exit 1
    ;;
esac
