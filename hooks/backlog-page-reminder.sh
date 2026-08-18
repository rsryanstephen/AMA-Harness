#!/usr/bin/env bash
# PostToolUse hook (mcp__*__createJiraIssue, Bash). Nudges Claude to add a new Open
# ticket to the AMA Backlog Confluence page -- per user instruction, every ticket Claude
# creates must land there (page stays priority-ordered). Same "can only nudge, not
# verify" shape as git-push-ticket-reminder.sh -- no live Jira/Confluence read here.
#
# Cannot read the created ticket's key from the write payload: jira-create-issue.sh
# deletes ~/.claude/.jira-write-payload.json on success (unlike the PreToolUse gates,
# which run before that delete). Nudge generically instead -- Claude already knows the
# key it just created, same turn.
#
# NOTE: this nudge is a no-op MOST of the time, by design, not a bug. Scope is Open-only
# (commit-ticket's "New ticket left at Open" section) and commit-ticket moves a
# request-time ticket to In Progress the moment Claude starts working it -- so most
# creates get "skip, already being worked" as the correct answer. Don't "fix" this into
# firing less; the backlog is supposed to be mostly incidental findings.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- both arms below need either the MCP createJiraIssue
# tool name or a jira-create-issue.sh invocation, each leaving its literal substring
# in the raw payload. ~60ms/fork on this machine.
case "$payload" in *createJiraIssue*|*jira-create-issue*) ;; *) exit 0 ;; esac
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"

case "$tool" in
  mcp__*__createJiraIssue)
    ;;
  Bash)
    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
    printf '%s' "$command" | grep -qP '(^|[;&|]\s*)(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*jira-create-issue\.sh|(^|[;&|]\s*)\.[/\\]\S*jira-create-issue\.sh' || exit 0
    ;;
  *)
    exit 0
    ;;
esac

jq -cn '{decision:"block", reason:"Ticket just created. If it is staying Open (not worked this session) -- per commit-ticket, add it to the AMA Backlog Confluence page now: propose section + slot, confirm in one line, then write (see commit-ticket/BACKLOG-PAGE.md). If work starts immediately this session (Open -> In Progress), skip -- backlog is future work only."}'
