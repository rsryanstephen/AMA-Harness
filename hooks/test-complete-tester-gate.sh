#!/usr/bin/env bash
# PreToolUse gate: a ticket the TESTER sent back is closed by the tester, not by Claude.
#
# Why (user instruction 2026-10-05). PROJ-15417 was tested by <uiTesterName>, who moved it from
# Ready to Test back to To Do with a failing report attached. A session investigated, found the
# failure was outside the ticket's scope, and moved the ticket straight to Test Complete itself.
# Your Name: "<uiTesterName> should be the one who puts it in Test Complete ... Claude shouldn't presume to
# put tickets into Test Complete that were sent back." The right move is Ready to Test plus a
# comment explaining the finding; the tester decides whether it is complete.
#
# Rule, as checked here: a transition whose destination is Test Complete is DENIED when the
# ticket's changelog shows a status change OUT of Ready to Test (or Test Complete) made by an
# account other than the user's own, into any status that is not terminal. That is what a
# tester's bounce looks like, whatever name the workflow gives it (Failed Test, To Do, Open).
# A ticket nobody has ever bounced is untouched -- the push-to-master = Test Complete row in
# commit-ticket-jira's transition table still applies to those.
#
# FAILS CLOSED, like ready-to-test-readiness-gate.sh and for the same reason: an unresolvable
# destination cannot be ruled out as Test Complete. The hatch is the Jira UI.
set -u

IFS= read -r -d '' payload || true
case "$payload" in
  *jira-transition-issue*) ;;
  *) exit 0 ;;
esac

deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0
# Invocation only, never a filename mentioned in a read -- same shape as the readiness gate.
printf '%s' "$command" | grep -qE '(^|[;&|(] *)([A-Z_]+=[^[:space:]]+ +)*(bash +|sh +|pwsh +|powershell(\.exe)? +)?"?[^" ]*jira-transition-issue\.sh"? +[A-Z]' || exit 0
args="$(printf '%s' "$command" \
  | sed -E 's/.*[^[:alnum:]_-]jira-transition-issue\.sh"?[[:space:]]+//; s/^jira-transition-issue\.sh"?[[:space:]]+//; s/[;&|].*$//')"
key="$(printf '%s' "$args" | awk '{gsub(/["\x27]/,"",$1); print $1}' | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+$')"
tid="$(printf '%s' "$args" | awk '{gsub(/["\x27]/,"",$2); print $2}' | grep -oE '^[0-9]+$')"
[ -n "$key" ] || deny "Test-Complete tester gate: could not read a ticket key out of this transition call. Re-issue it as 'jira-transition-issue.sh <KEY> <TRANSITION-ID>'."

cfg="${HR_CONFIG_FILE:-$HOME/.claude/harness-config.json}"
host="$(jq -r '.atlassian.cloudId // empty' < "$cfg" 2>/dev/null)"
email="$(jq -r '.user.email // empty' < "$cfg" 2>/dev/null)"
me="$(jq -r '.user.jiraAccountId // .atlassian.jiraAccountId // empty' < "$cfg" 2>/dev/null)"
hatch="The transition can still be done by hand in the Jira UI, which no hook intercepts."

[ -n "${ATLASSIAN_API_TOKEN:-}" ] || deny "Test-Complete tester gate: ATLASSIAN_API_TOKEN is not set, so it cannot tell whether ${key} was sent back by the tester. This gate fails CLOSED by design. ${hatch}"
[ -n "$host" ] && [ -n "$email" ] && [ -n "$me" ] || deny "Test-Complete tester gate: atlassian.cloudId / user.email / user.jiraAccountId missing from harness-config.json, so ${key}'s history cannot be checked. This gate fails CLOSED by design. ${hatch}"

# Test seams: the transitions list and the changelog can be handed in as files so check-gates
# never has to reach Jira (same role RTT_PENDING_FILE / HR_CONFIG_FILE play elsewhere).
_get() {
  case "$1" in
    */transitions) [ -n "${TCG_TRANSITIONS_FILE:-}" ] && { cat "$TCG_TRANSITIONS_FILE"; return; } ;;
    */changelog*)  [ -n "${TCG_CHANGELOG_FILE:-}" ]   && { cat "$TCG_CHANGELOG_FILE"; return; } ;;
  esac
  curl -s --max-time 10 -u "${email}:${ATLASSIAN_API_TOKEN}" "https://${host}$1" 2>/dev/null
}

trs="$(_get "/rest/api/3/issue/${key}/transitions")"
[ -n "$trs" ] || deny "Test-Complete tester gate: could not reach Jira to resolve where this transition takes ${key}. This gate fails CLOSED by design. ${hatch}"
target="$(printf '%s' "$trs" | jq -r --arg id "${tid:-}" '.transitions[]? | select(.id == $id) | .to.name // empty' 2>/dev/null)"
[ -n "$target" ] || deny "Test-Complete tester gate: transition id '${tid:-<none>}' is not one ${key} currently offers, so its destination cannot be resolved. Run jira-get-transitions.sh ${key} for the live ids. ${hatch}"
printf '%s' "$target" | grep -qiE '^test ?complete$' || exit 0

log="$(_get "/rest/api/3/issue/${key}/changelog?maxResults=100")"
[ -n "$log" ] || deny "Test-Complete tester gate: could not read ${key}'s changelog, so it cannot tell whether the tester sent it back. This gate fails CLOSED by design. ${hatch}"

# Bounces: status changes by someone else, out of Ready to Test / Test Complete, into a
# non-terminal status. Prints "<display name> <from> -> <to>" per bounce.
bounces="$(printf '%s' "$log" | jq -r --arg me "$me" '
  [.values[]? | select(.author.accountId != $me) as $h
    | $h.items[]? | select(.field == "status")
    | select((.fromString // "") | test("^(ready ?to ?test|test ?complete)$"; "i"))
    | select((.toString // "") | test("^(test ?complete|done|closed|deployed prod|cancell?ed)$"; "i") | not)
    | "\($h.author.displayName // $h.author.accountId): \(.fromString) -> \(.toString) (\($h.created[:10]))"]
  | .[]' 2>/dev/null)"
[ -n "$bounces" ] || exit 0

deny "${key} was sent back by the tester (${bounces//$'\n'/; }), so Test Complete is the tester's call, not Claude's (user instruction 2026-10-05, PROJ-15417). Post the finding as a comment and move the ticket to Ready to Test instead; the tester closes it. ${hatch}"
