#!/usr/bin/env bash
# PostToolUse (Bash|PowerShell). Nudges when a jira-search.sh JQL filters on status/sprint
# but names no assignee.
#
# AGENTS.md: column/status queries default to `assignee = currentUser()`, dropped only when
# everyone's work was explicitly asked for. This is a silent-failure shape -- the query
# without the clause returns MORE rows and looks perfectly successful, then a standup or a
# release sweep quietly includes other people's tickets. No hook enforced it (2026-09-15
# audit). Warn-only: cannot deny, the "everyone's" case is legitimate and undetectable.
set -u
payload="$(cat)"
case "$payload" in *jira-search*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0
. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || exit 0
region="$(printf '%s' "$command" | command_without_heredoc_bodies)"
printf '%s' "$region" | grep -qE '(^|[;&|[:space:]])(bash[[:space:]]+)?[^[:space:]]*jira-search\.sh[[:space:]]' || exit 0
# The JQL is the first argument. status/sprint-shaped, with no assignee at all?
printf '%s' "$region" | grep -qiE '(status|sprint)[[:space:]]*(=|!=|in|not in|was|changed)' || exit 0
printf '%s' "$region" | grep -qiE 'assignee|reporter|creator|worklogAuthor' && exit 0
# fixVersion-scoped and key-scoped queries are about a release or a ticket, not a column.
printf '%s' "$region" | grep -qiE 'fixVersion[[:space:]]*(=|in)|key[[:space:]]*(=|in)' && exit 0

jq -cn '{decision:"block", reason:"jira-search.sh ran a status/sprint-shaped JQL with NO assignee clause. AGENTS.md default for column/status queries is `assignee = currentUser()` -- drop it only when everyone'"'"'s work was explicitly asked for. A query without it returns MORE rows and looks fine, so confirm the result was meant to include other people'"'"'s tickets before it feeds a standup or a release sweep."}'
exit 0
