#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Daily scheduler for
# skills/commit-ticket-jira/scripts/stale-in-progress.sh: own tickets left In Progress /
# Review / QA after the work finished (2026-10-27: ten RDS tickets, a week, until the user
# asked). Same shape as backlog-stale-check.sh -- pure bash, no Jira call here (on-prompt
# is fork/timeout sensitive); the script does the read and stamps the lastrun file.
#
# Sets $stale_in_progress_notice (empty if nothing to say). Once per calendar day: quiet
# once the script has run today, or once today's nudge was given.
stale_in_progress_notice=""
. "$HOME/.claude/hooks/lib-claude-paths.sh"
_sip_last="$(cat "$(hstate notices .stale-in-progress-lastrun)" 2>/dev/null | tr -d ' \r\n')"
_sip_nudged_file="$(hstate notices .stale-in-progress-nudged)"
_sip_today="$(date +%F)"
if [ "$_sip_last" != "$_sip_today" ] && [ "$(cat "$_sip_nudged_file" 2>/dev/null)" != "$_sip_today" ]; then
  stale_in_progress_notice="daily stale-ticket check owed -- run \`bash ~/.claude/skills/commit-ticket-jira/scripts/stale-in-progress.sh\` and follow its per-ticket rule: skip tickets a live session has claimed, transition only what live state proves, list everything else for the user (user rule 2026-10-27: tickets move on with the work, never left behind)."
  printf '%s\n' "$_sip_today" > "$_sip_nudged_file"
fi
