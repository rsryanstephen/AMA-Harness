#!/usr/bin/env bash
# PreToolUse hook (mcp__*__createJiraIssue), mechanical backstop for commit-ticket's
# ticket-description template -- every new ticket needs "acceptance criteria" + "how to
# test" + ("how to reproduce" for a Bug, or "requirements" for anything else). Prose
# rules alone don't hold (same lesson as jira-ticket-fields-gate.sh/skill-bloat-gate.sh):
# this harness had ZERO description guidance until this gate landed.
#
# Deliberately does NOT check issue type -- it isn't in the payload file, it's argv[2]
# of jira-create-issue.sh, and parsing it back out of command text is the fragile
# surface the comments on that gate already warn about. So "how to reproduce" and
# "requirements" are both accepted for every issue type.
#
# Deliberately dialect-agnostic on formatting -- this checks the required sections are
# PRESENT, not that they're phrased/marked-up a specific way. Matches an optional
# h2./h3./### prefix so it doesn't silently break if the wiki-markup heading style ever
# changes. Full template: commit-ticket/TICKET-TEMPLATE.md.
#
# Also covers ama-jira-api's jira-create-issue.sh (direct REST write) -- same payload
# file jira-ticket-fields-gate.sh reads, same command-text match, same reasoning.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- both arms below need either the MCP createJiraIssue
# tool name or a jira-create-issue.sh invocation, each leaving its literal substring
# in the raw payload. ~60ms/fork on this machine.
case "$payload" in *createJiraIssue*|*jira-create-issue*) ;; *) exit 0 ;; esac
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

description=""
case "$tool" in
  mcp__*__createJiraIssue)
    description="$(printf '%s' "$payload" | jq -r '.tool_input.description // empty')"
    ;;
  *)
    printf '%s' "$command" | grep -qP '(^|[;&|]\s*)(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*jira-create-issue\.sh|(^|[;&|]\s*)\.[/\\]\S*jira-create-issue\.sh' || exit 0
    PAYLOAD_FILE="$HOME/.claude/.jira-write-payload.json"
    [ -f "$PAYLOAD_FILE" ] || exit 0
    # description may be top-level or (older documented shape) nested under
    # additional_fields -- check both, top-level wins if somehow both are set.
    description="$(jq -r '.description // .additional_fields.description // empty' "$PAYLOAD_FILE" 2>/dev/null)"
    ;;
esac

if [ -z "$description" ]; then
  missing="description (empty or missing entirely)"
else
  missing=""
  printf '%s' "$description" | grep -qiP 'acceptance criteria' \
    || missing="${missing}acceptance criteria, "
  printf '%s' "$description" | grep -qiP 'how to test' \
    || missing="${missing}how to test, "
  printf '%s' "$description" | grep -qiP 'how to reproduce|requirements' \
    || missing="${missing}how to reproduce (Bug) / requirements (everything else), "
  missing="${missing%, }"
fi

[ -n "$missing" ] || exit 0

jq -cn --arg m "$missing" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Jira ticket creation problem (this harness'"'"'s own gate, not a Jira requirement): description missing required section(s): " + $m + ". See commit-ticket/TICKET-TEMPLATE.md for the template. Resolve and retry.")
  }
}'
