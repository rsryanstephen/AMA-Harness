#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell): deny creating a hotfix branch whose Jira version is
# already CLAIMED by a different fix.
#
# Why this exists. ama-hotfix Step 1 says the next hotfix number is max-across-Jira-and-
# branches PLUS ONE. The failure mode isn't misreading that rule, it's the version list
# looking like an invitation: confirmed live 2026-08-18, `hotfix/129.0.1` already existed
# AND was already listed in ~/.claude/harness-state/tickets/.confirmed-jira-versions, which reads as a green
# light. It was reserved for PROJ-15311's selenium-crawler fix. An exporterplus
# branch was cut against it and pushed before the user caught it.
#
# `harness-state/tickets/.confirmed-jira-versions` records that a version EXISTS (so the fixVersion-tagging gate
# will allow it) -- it says nothing about who owns it. Those are different questions and
# nothing was asking the second one.
#
# A version is CLAIMED if it has a description or any ticket tagged to it. Unclaimed
# versions are freshly created and empty, which is exactly what the user hands over when
# asked to create one.
#
# Gates branch CREATION (`git checkout -b hotfix/...` / `git switch -c`), the first
# irreversible-ish step and the cheapest point to be wrong at. Not the push: by then the
# branch name is already on a remote.
#
# Fails OPEN on anything it can't establish -- no token, no network, unparseable response.
# A hotfix is by definition urgent; this must never be the reason one cannot be cut.
set -u

IFS= read -r -d '' payload || true
case "$payload" in *hotfix/*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
[ -n "$command" ] || exit 0

# Only a branch-creating checkout/switch. A plain `git checkout hotfix/x` onto an existing
# branch is fine -- that branch already exists, the decision was made earlier.
version="$(printf '%s' "$command" \
  | grep -oP '(?:checkout\s+-b|switch\s+-c)\s+"?\Khotfix/[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$version" ] || exit 0

CONFIG="$HOME/.claude/harness-config.json"
[ -f "$CONFIG" ] || exit 0
email="$(jq -r '.user.email // empty' "$CONFIG" 2>/dev/null | tr -d '\r')"
project="$(jq -r '.atlassian.jiraProjectKey // "PROJ"' "$CONFIG" 2>/dev/null | tr -d '\r')"
host="$(jq -r '.atlassian.cloudId // "yourorg.atlassian.net"' "$CONFIG" 2>/dev/null | tr -d '\r')"
[ -n "$email" ] || exit 0
[ -n "${ATLASSIAN_API_TOKEN:-}" ] || exit 0

versions="$(curl -sS --max-time 8 -u "$email:$ATLASSIAN_API_TOKEN" \
  "https://$host/rest/api/3/project/$project/versions" 2>/dev/null)"
[ -n "$versions" ] || exit 0
printf '%s' "$versions" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 0

# Version not created yet -> a different problem (Step 1 tells the agent to ask the user
# to create it), and not this gate's business.
printf '%s' "$versions" | jq -e --arg v "$version" 'any(.[]; .name == $v)' >/dev/null 2>&1 || exit 0

desc="$(printf '%s' "$versions" | jq -r --arg v "$version" \
  '.[] | select(.name == $v) | .description // ""' 2>/dev/null)"

jql="$(printf 'fixVersion = "%s"' "$version")"
tickets="$(curl -sS --max-time 8 -u "$email:$ATLASSIAN_API_TOKEN" \
  --get --data-urlencode "jql=$jql" --data-urlencode "fields=key" --data-urlencode "maxResults=5" \
  "https://$host/rest/api/3/search/jql" 2>/dev/null)"
keys="$(printf '%s' "$tickets" | jq -r '[.issues[]?.key] | join(", ")' 2>/dev/null)"

# Own-version escape hatch. ama-hotfix Step 2 tells the agent to CREATE the version itself
# and to give it a description (Octopus shows it as the release Description) -- so by the
# time it branches, the version it legitimately owns looks exactly like someone else's
# reservation. Following the skill deadlocked against this gate (confirmed live 2026-08-19,
# hotfix/129.0.4, the feedback .NET 10 regression).
#
# Ownership signal: every ticket tagged to the version is THIS session's resolved ticket
# (set-session-ticket.sh, ~/.claude/.session-chatfiles/<sid>.ticket) -- a claim only this
# session could have made. A description ALONE still counts as claimed: an untagged version
# is indistinguishable from another repo's reservation.
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' | tr -d '\r')"
session_ticket=""
[ -n "$sid" ] && [ -f "$HOME/.claude/.session-chatfiles/$sid.ticket" ] \
  && IFS= read -r session_ticket < "$HOME/.claude/.session-chatfiles/$sid.ticket" 2>/dev/null
session_ticket="$(printf '%s' "$session_ticket" | tr -d '\r')"

# The JQL search above is EVENTUALLY CONSISTENT -- immediately after tagging a ticket's
# fixVersions, `fixVersion = "..."` still returns nothing while a direct issue read already
# shows the tag. Relying on the search alone re-created the very deadlock this hatch exists
# to remove (confirmed live 2026-08-19, hotfix/129.0.6). So ask the session's own ticket
# directly -- index-independent, and a claim only this session could have made.
own_by_issue=false
if [ -n "$session_ticket" ]; then
  issue="$(curl -sS --max-time 8 -u "$email:$ATLASSIAN_API_TOKEN" \
    "https://$host/rest/api/3/issue/$session_ticket?fields=fixVersions" 2>/dev/null)"
  if printf '%s' "$issue" | jq -e --arg v "$version" \
      'any(.fields.fixVersions[]?; .name == $v)' >/dev/null 2>&1; then
    own_by_issue=true
  fi
fi

if [ "$own_by_issue" = true ] && [ -z "$keys" ]; then
  # Version carries our own ticket's tag and the index shows no OTHER owner yet.
  exit 0
fi

if [ -n "$session_ticket" ] && [ -n "$keys" ]; then
  if printf '%s' "$tickets" | jq -e --arg t "$session_ticket" \
      '[.issues[]?.key] | length > 0 and all(. == $t)' >/dev/null 2>&1; then
    exit 0
  fi
fi

claimed=false
[ -n "$desc" ] && claimed=true
[ -n "$keys" ] && claimed=true
[ "$claimed" = true ] || exit 0

jq -cn --arg v "$version" --arg d "$desc" --arg k "$keys" --arg st "$session_ticket" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: (
      "Jira version " + $v + " is already CLAIMED by a different fix -- do not branch against it.\n"
      + (if $k != "" then "  tickets already tagged: " + $k + "\n" else "" end)
      + (if $d != "" then "  description: " + ($d[0:220]) + "\n" else "" end)
      + (if $st != "" then "  this session'"'"'s ticket: " + $st + "\n" else "" end)
      + "\nIf you created this version for THIS fix, tag your own ticket to it (fixVersions) BEFORE branching -- this gate allows a version whose only tagged ticket is this session'"'"'s resolved ticket. If the tagged ticket IS this fix but the session-ticket record above is a stale earlier ticket, update it (bash ~/.claude/hooks/set-session-ticket.sh <cwd> <chatfile> <TICKET>) and retry. Otherwise: an existing hotfix version means RESERVED, not available, and the reservation is usually for a different repo -- a repo-branch check will not reveal it. Presence in ~/.claude/harness-state/tickets/.confirmed-jira-versions only proves the version EXISTS (so the fixVersion-tagging gate allows it); it says nothing about ownership.\n\nPer ama-hotfix Step 1: take max-across-Jira-and-branches PLUS ONE and CREATE that next version YOURSELF via jira-version.sh create + confirm-jira-version.sh (ama-hotfix Step 2 has the exact calls -- never ask the user to click it together in Jira), then branch. Verify the new one is unclaimed first -- an unclaimed version has no description and no tickets."
    )
  }
}'
