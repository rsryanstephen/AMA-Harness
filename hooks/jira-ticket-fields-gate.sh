#!/usr/bin/env bash
# PreToolUse hook (mcp__*__createJiraIssue), mechanical backstop for commit-ticket's
# "never leave unassigned" rule. Confirmed real, twice: PROJ-15132 missed Epic
# Link, then 17 more harness tickets missed BOTH assignee and Epic Link -- invisible on
# the user's real board. Prose rules alone didn't prevent a repeat, same lesson as
# bare-cd-gate.sh/skill-bloat-gate.sh.
#
# Epic Link is deliberately NOT checked here anymore -- it used to be mandatory on
# every new ticket, which forced an artificial epic onto ordinary bugs with no natural
# fit (confirmed real: a plain "On Prod" bug got a placeholder epic set then stripped
# via editJiraIssue just to satisfy this gate, ending up exactly unlinked anyway, and
# the denial got mislabeled to the user as "Jira requiring" it, when it was this hook).
# Harness tickets don't exist anymore either (see harness-ticket-gate.sh + commit-
# ticket's "Harness work" section) so the original epic-link problem this gate existed
# to prevent (orphaned harness tickets) can't recur. Epic Link is optional/contextual
# for regular AMA_APP tickets per commit-ticket's own guidance.
# Also covers ama-jira-api's jira-create-issue.sh (direct REST write, same rule must
# hold there too) -- reads its payload from the SAME fixed file the script itself
# reads (~/.claude/.jira-write-payload.json), never parses JSON out of command text
# (same quote-blind trap deploy-verify-confirm-gate.sh's comments document).
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- both arms below need either the MCP createJiraIssue
# tool name or a jira-create-issue.sh invocation, each leaving its literal substring
# in the raw payload. ~60ms/fork on this machine.
case "$payload" in *createJiraIssue*|*jira-create-issue*) ;; *) exit 0 ;; esac
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

assignee=""
case "$tool" in
  mcp__*__createJiraIssue)
    assignee="$(printf '%s' "$payload" | jq -r '.tool_input.assignee_account_id // empty')"
    ;;
  *)
    printf '%s' "$command" | grep -qP '(^|[;&|]\s*)(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*jira-create-issue\.sh|(^|[;&|]\s*)\.[/\\]\S*jira-create-issue\.sh' || exit 0
    PAYLOAD_FILE="$HOME/.claude/.jira-write-payload.json"
    [ -f "$PAYLOAD_FILE" ] || exit 0
    assignee="$(jq -r '.assignee_account_id // empty' "$PAYLOAD_FILE" 2>/dev/null)"
    ;;
esac

user_account_id="$(jq -r '.user.jiraAccountId // empty' "$HOME/.claude/harness-config.json" 2>/dev/null)"

missing=""
if [ -z "$assignee" ]; then
  missing="assignee_account_id"
elif [ -n "$user_account_id" ] && [ "$assignee" != "$user_account_id" ]; then
  # Confirmed real gap: a non-empty assignee_account_id was passing this gate even when
  # it wasn't the user's own ID (typo'd/stale/hallucinated GUID) -- the gate only checked
  # "something's there," not "it's actually Your Name." commit-ticket's default is always the
  # user unless the user explicitly asked for someone else this session.
  missing="assignee_account_id (set to '$assignee', not the user's own '$user_account_id')"
fi

[ -n "$missing" ] || exit 0

jq -cn --arg m "$missing" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Jira ticket creation problem (this harness'"'"'s own gate, not a Jira requirement): " + $m + ". Per commit-ticket: default assignee is always the user'"'"'s own accountId unless they explicitly asked for someone else this session. Resolve and retry.")
  }
}'
