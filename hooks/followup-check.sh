#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Same pattern as
# embs-coverage-check.sh: on-disk state + pure bash, no network -- on-prompt.sh runs on
# EVERY prompt and is fork-cost/30s-timeout sensitive.
#
# Ledger for multi-week Slack-reply escalation chains (e.g. "remind at +1wk, escalate at
# +2wk, act at +4wk"). CronCreate can't carry this: it's session-only and auto-expires
# after 7 days. This file is the durable state instead; the ama-followups skill does the
# actual work when a row comes due, this hook only decides WHEN to nudge.
#
# Row format (tab-separated), one per line in ~/.claude/.pending-followups:
#   id \t due-date(YYYY-MM-DD) \t stage \t slack-user-id \t jira-key \t description
#
# Sets $followup_notice (empty if nothing due). Throttled to once per calendar day via
# ~/.claude/.followups-nudged, same as the eMBS nudge.
followup_notice=""
LEDGER="$HOME/.claude/.pending-followups"
NUDGED_FILE="$HOME/.claude/.followups-nudged"
today="$(date +%F)"

if [ -s "$LEDGER" ]; then
  due_lines=""
  while IFS=$'\t' read -r id due stage slack_user jira_key desc; do
    [ -n "$id" ] || continue
    # due <= today (no `<=` string op in `[ ]` -- negate `>`)
    if ! [ "$due" \> "$today" ]; then
      due_lines="$due_lines$id (stage $stage, due $due): $desc"$'\n'
    fi
  done < "$LEDGER"

  if [ -n "$due_lines" ]; then
    last_nudge="$(cat "$NUDGED_FILE" 2>/dev/null || true)"
    if [ "$last_nudge" != "$today" ]; then
      followup_notice="Follow-up ledger has due item(s) -- run the ama-followups skill now:
$due_lines"
      printf '%s\n' "$today" > "$NUDGED_FILE"
    fi
  fi
fi
