#!/usr/bin/env bash
# Biweekly unattended sweep: every ticket the QA reporter (config backlogQaSweep.reporterName,
# default <uiTesterName>) CREATED since the last good run and that is still Open -> AMA Backlog page.
# Scheduled-task target (AMA-Harness-Backlog-QA-Sweep, every 2 weeks, InteractiveToken).
# No LLM leg for the work itself (JQL -> backlog-add-ticket.sh per key); the ONLY `claude -p`
# is a haiku Slack send.
#
# Usage: backlog-qa-sweep.sh        env seams: BACKLOG_QA_SWEEP_DRY_RUN=1 (print, write nothing,
#                                   no Slack, no stamp), BACKLOG_QA_SWEEP_SINCE="YYYY-MM-DD[ HH:MM]"
#
# Rules (user decisions 2026-10-19):
#   * Window = since the stamp (run START time of the last run that added everything), else 14d.
#     A failed run writes no stamp -> the next window widens, nothing is lost.
#   * Past-Open tickets are never added: status filter is backlog-statuses.sh, the SAME list
#     backlog-prune-resolved.sh deletes by, so sweep and prune cannot fight.
#   * A key already on EITHER page (main or Deferred) is skipped -- Deferred was a deliberate call.
#   * Slack DM: every run while today <= backlogQaSweep.slackEveryRunUntil (trial week), else
#     only on FAILED. Digest line (notices/backlog-qa-sweep.txt, relayed by on-prompt.sh) when
#     something was added or failed.
set -uo pipefail

harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
cd "${harness:-$HOME}" 2>/dev/null || true   # Task Scheduler starts in System32

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
. "$HOME/.claude/hooks/lib-unattended-ready.sh"
S="$HOME/.claude/skills/commit-ticket-jira/scripts"
. "$S/backlog-statuses.sh"

DRY="${BACKLOG_QA_SWEEP_DRY_RUN:-0}"
LOG="$(hstate logs backlog-qa-sweep.log)"
STAMP="$(hstate harness .backlog-qa-sweep-lastrun)"
DIGEST="$(hstate notices backlog-qa-sweep.txt)"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; [ "$DRY" = "1" ] && printf '%s\n' "$*"; return 0; }

today="$(date +%F)"
started="$(date '+%F %H:%M')"
NAME="$(hr_config '.backlogQaSweep.reporterName' '<uiTesterName>' | tr -d '\r')"
RID="$(hr_config '.backlogQaSweep.reporterAccountId' '' | tr -d '\r')"
TARGET="$(hr_config '.backlogQaSweep.reportTarget' '' | tr -d '\r')"
UNTIL="$(hr_config '.backlogQaSweep.slackEveryRunUntil' '' | tr -d '\r')"

wait_until_online log || log "proceeding without confirmed network"

fail=0; failmsg=""
bad() { fail=1; failmsg="${failmsg:+$failmsg; }$*"; log "FAIL: $*"; }

# --- reporter: accountId from config, else resolve the name (exactly one active human) ---
if [ -z "$RID" ]; then
  EMAIL="$(hr_config '.user.email' '' | tr -d '\r')"; HOST="$(hr_config '.atlassian.cloudId' '' | tr -d '\r')"
  matches="$(curl -sS -u "$EMAIL:${ATLASSIAN_API_TOKEN:-}" "https://$HOST/rest/api/3/user/search?query=$NAME" 2>>"$LOG" \
    | jq -r '.[]? | select(.active and .accountType=="atlassian") | .accountId' 2>/dev/null)"
  if [ "$(printf '%s\n' "$matches" | grep -c .)" = "1" ]; then RID="$matches"
  else bad "could not resolve QA reporter '$NAME' to exactly one Jira user (set backlogQaSweep.reporterAccountId)"; fi
fi

added=(); deferred=0; present=0; found=0
if [ "$fail" = "0" ]; then
  # --- window ---
  since="${BACKLOG_QA_SWEEP_SINCE:-}"
  if [ -z "$since" ] && [ -s "$STAMP" ]; then since="$(head -n1 "$STAMP" | tr -d '\r')"; fi
  [ -n "$since" ] || since="$(date -d '14 days ago' '+%F %H:%M')"
  log "reporter=$NAME ($RID) since=$since dry=$DRY"

  # --- candidates: created in window, still Open ---
  rows="$(bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh" \
    "project = PROJ AND reporter = $RID AND created >= \"$since\" AND status NOT IN ($BACKLOG_STARTED_STATUSES) ORDER BY created ASC" \
    "issuetype,summary" 200 2>>"$LOG")" || bad "jira search failed"
fi

if [ "$fail" = "0" ] && [ -n "$rows" ]; then
  # --- already on either backlog page (main or Deferred) ---
  onpages="$(bash "$S/backlog-candidates.sh" --all 2>>"$LOG" | awk -F'\t' '{print $2"\t"$3}')" \
    || bad "backlog-candidates.sh failed (cannot dedupe)"
  if [ "$fail" = "0" ]; then
    while IFS=$'\t' read -r key itype summary; do
      [ -n "$key" ] || continue
      found=$((found+1))
      page="$(printf '%s\n' "$onpages" | awk -F'\t' -v k="$key" '$1==k {print $2; exit}')"
      if [ "$page" = "deferred" ]; then deferred=$((deferred+1)); log "skip $key (on Deferred page)"; continue; fi
      if [ -n "$page" ]; then present=$((present+1)); log "skip $key (already on main page)"; continue; fi
      # Same mapping as ama-jira-api/scripts/jira-create-issue.sh.
      case "$itype" in
        Epic|epic) log "skip $key (Epic)"; continue ;;
        Bug|bug) section="Bugs" ;;
        Story|story|"New Feature"|Improvement) section="Features" ;;
        *) section="Tech Debt" ;;
      esac
      if [ "$DRY" = "1" ]; then log "WOULD add $key to $section: $summary"; added+=("$key ($section)"); continue; fi
      if out="$(bash "$S/backlog-add-ticket.sh" "$key" "$section" last 2>&1)"; then
        log "$out"; added+=("$key ($section)")
      else
        bad "add $key: $(printf '%s' "$out" | tail -n1 | head -c 200)"
      fi
    done <<< "$rows"
  fi
fi

# --- report ---
if [ "$fail" = "1" ]; then
  summary="FAILED: $failmsg"
elif [ "${#added[@]}" -gt 0 ]; then
  summary="added ${#added[@]}: $(printf '%s, ' "${added[@]}" | sed 's/, $//')"
else
  summary="0 new"
fi
[ "$deferred" -gt 0 ] && summary="$summary; $deferred left on Deferred"
log "result: $summary (candidates $found, already-on-main $present)"
[ "$DRY" = "1" ] && exit "$fail"

[ "$fail" = "0" ] && printf '%s\n' "$started" > "$STAMP"
if [ "$fail" = "1" ] || [ "${#added[@]}" -gt 0 ]; then
  printf 'QA backlog sweep %s (%s): %s\n' "$today" "$NAME" "$summary" >> "$DIGEST"
fi

# Slack: every run during the trial week, afterwards failures only.
if [ "$fail" = "1" ] || { [ -n "$UNTIL" ] && ! [ "$today" \> "$UNTIL" ]; }; then
  if [ -z "$TARGET" ]; then log "no backlogQaSweep.reportTarget -- Slack skipped"; exit "$fail"; fi
  command -v claude >/dev/null 2>&1 || { log "claude CLI not on PATH -- Slack skipped"; printf 'QA backlog sweep %s: Slack send skipped, claude not on PATH.\n' "$today" >> "$DIGEST"; exit "$fail"; }
  TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 120"
  msg="$(hr_self_mention "$TARGET")QA backlog sweep ($NAME): $summary"
  out="$($TO claude -p "Call mcp__claude_ai_Slack__slack_send_message with channel_id $TARGET and this exact message text: $msg -- then reply with ONLY the word DONE, or FAILED: and the error." \
    --model haiku --allowedTools mcp__claude_ai_Slack__slack_send_message 2>>"$LOG")" || out=""
  case "$out" in *"spend limit"*|*"usage limit"*|*"rate limit"*) printf '%s %s\n' "$(date '+%F %T')" "$(basename "$0")" >> "$(hstate notices unattended-blocked.txt)"; log "BLOCKED by a spend/usage limit -- Slack not sent";; esac
  case "$out" in
    *DONE*) log "slack sent to $TARGET" ;;
    *) printf 'QA backlog sweep %s: Slack send did not confirm (%s).\n' "$today" "$(printf '%s' "$out" | head -c 300)" >> "$DIGEST"
       log "slack send failed: $(printf '%s' "$out" | head -c 4000)" ;;
  esac
fi
exit "$fail"
