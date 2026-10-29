#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Nudges Claude to prune resolved
# tickets off the AMA Backlog pages once the last sweep is older than
# .backlogStale.checkDays.
#
# This is the scheduler. Per CLAUDE.md's mechanical-triggers rule the sweep needs a hook
# behind it, not a skill-description match -- nobody self-recognises "the backlog might
# have gone stale".
#
# Why a periodic sweep and not a transition trigger: measured 2026-09-04, of 5 stale
# entries only 1 came from a transition this harness performed. The rest were closed in
# another concurrent session or straight in the Jira UI, neither of which a PostToolUse
# hook on jira-transition-issue.sh can observe. So the detection is scheduled here and
# the WRITE stays in the agent-invoked script, which has the abort-and-verify guards.
#
# Pure bash, no network, two tiny state-file reads -- on-prompt.sh runs on EVERY prompt
# and is fork-cost/30s-timeout sensitive. No Jira or Confluence call belongs here; the
# script the nudge names does that work, once, when the agent runs it.
#
# Sets $backlog_stale_notice (empty if nothing to say). Throttled once per calendar day.
backlog_stale_notice=""
. "$HOME/.claude/hooks/lib-claude-paths.sh"
LASTRUN_FILE="$(hstate notices .backlog-stale-lastrun)"
NUDGED_FILE="$(hstate notices .backlog-stale-nudged)"
today="$(date +%F)"

check_days=7
if [ -f "$HOME/.claude/harness-config.json" ]; then
  v="$(jq -r '.backlogStale.checkDays // empty' < "$HOME/.claude/harness-config.json" 2>/dev/null | sed 's/\r$//')"
  case "$v" in ''|*[!0-9]*) ;; *) check_days="$v" ;; esac
fi

due=0
if [ ! -s "$LASTRUN_FILE" ]; then
  due=1
else
  last="$(tr -d ' \r\n' < "$LASTRUN_FILE")"
  cutoff="$(date -d "$check_days days ago" +%F 2>/dev/null || true)"
  # last < cutoff => overdue. String compare is safe on YYYY-MM-DD. Both guarded: an
  # unguarded `date` failure in a sourced hook kills on-prompt.sh before its final emit
  # and silently loses the whole turn's injected context.
  [ -n "$last" ] && [ -n "$cutoff" ] && [ "$last" \< "$cutoff" ] && due=1
fi

if [ "$due" = "1" ]; then
  last_nudge="$(cat "$NUDGED_FILE" 2>/dev/null || true)"
  if [ "$last_nudge" != "$today" ]; then
    backlog_stale_notice="the AMA Backlog pages have not been swept for resolved tickets in over $check_days days -- run \`bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-prune-resolved.sh\` (add --dry-run first if you want to see the list), then \`bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-epics-sync.sh\` (Epics index + dormant-epic children). Standing rule from the user: there should be no Done tickets on the backlog anywhere. Stale entries make every pickup pass fetch and re-status work that is already finished."
    printf '%s\n' "$today" > "$NUDGED_FILE"
  fi
fi
