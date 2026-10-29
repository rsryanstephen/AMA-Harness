#!/usr/bin/env bash
# PostToolUse hook (mcp__*__createJiraIssue, Bash). Nudges Claude to add a new Open
# ticket to the AMA Backlog Confluence page -- per user instruction, every ticket Claude
# creates must land there (page stays priority-ordered). Same "can only nudge, not
# verify" shape as git-push-ticket-reminder.sh -- no live Jira/Confluence read here.
#
# Cannot read the created ticket's key from the write payload: jira-create-issue.sh
# deletes ~/.claude/harness-state/tickets/.jira-write-payload.json on success (unlike the PreToolUse gates,
# which run before that delete). Nudge generically instead -- Claude already knows the
# key it just created, same turn.
#
# NOTE: this nudge is a no-op MOST of the time, by design, not a bug. Scope is Open-only
# (commit-ticket-jira's "New ticket left at Open" section) and commit-ticket moves a
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
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' | tr -d '\r')"

case "$tool" in
  mcp__*__createJiraIssue)
    ;;
  Bash)
    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
    printf '%s' "$command" | grep -qP '(^|[;&|]\s*)([A-Za-z_]\w*=\S*\s+)*(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*jira-create-issue\.sh|(^|[;&|]\s*)\.[/\\]\S*jira-create-issue\.sh' || exit 0
    ;;
  *)
    exit 0
    ;;
esac

# The env-prefix group matters: the documented call is `JIRA_PAYLOAD_FILE=<f> bash .../jira-create-issue.sh`
# (required since 2026-09-07), and without it this hook never fired at all (found 2026-10-22).
# Silent when the create already carried a judged slot (BACKLOG_POSITION=) or opted out,
# or its own output says it is an epic child that never went on the page (fired on all 9
# epic-child creates in session 3924ecbb, 2026-10-28).
case "$payload" in *BACKLOG_POSITION=*|*BACKLOG_SKIP=1*|*'not added to the backlog page'*) exit 0 ;; esac
jq -cn '{decision:"block", reason:"Ticket just created. jira-create-issue.sh already put it on the AMA Backlog page -- but with no BACKLOG_POSITION it went LAST, and the page is priority-ordered (user rule 2026-10-22: a ticket Claude raises goes where its priority fits). Unless it is an epic child (the create output then says the epic is in the Epics index -- nothing to do) or work starts on it this session: run bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-section.sh <its section>, compare its impact with the neighbours (summaries + hand-written notes; Jira priority is mostly an unused default there), then bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-move-first.sh <KEY> --before <KEY2> -- leave it last only if it ranks lowest. No user approval needed; say where it went in one line. Next time pass BACKLOG_POSITION=before:<KEY> to the create (see commit-ticket-jira/BACKLOG-PAGE.md Placement)."}'
