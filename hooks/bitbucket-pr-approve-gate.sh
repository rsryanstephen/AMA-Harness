#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell, dispatched). Denies Claude APPROVING a Bitbucket pull request
# (POST .../pullrequests/<id>/approve) -- company software development policy (amended
# 2026-10-16): AI agents may NOT approve PRs; they MAY merge them. Claude reviews, comments and
# advises (ama-pr-review); the human approves. No hatch -- policy, not a judgment call.
# Allowed: unapprove (-X DELETE / -Method Delete), /merge, /request-changes, comments, GETs.
# Also scans scripts the command runs (lib-scan-script-refs.sh). Fails open on bad payloads.
set -u
IFS= read -r -d '' payload || true
case "$payload" in *approve*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0

. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
region="$(command_scan_region "$command")"
. "$HOME/.claude/hooks/lib-scan-script-refs.sh" 2>/dev/null && region="$region
$(scan_referenced_scripts "$command")"
flat="$(printf '%s' "$region" | tr '\n' ' ')"

# Endpoint with a literal or variable id ($ID, ${id}, 42).
printf '%s' "$flat" | grep -qE 'pullrequests/[^/[:space:]]+/approve([^-[:alnum:]_]|$)' || exit 0
# ...and an HTTP client actually calling it -- the path in prose (a commit message) is not a call.
printf '%s' "$flat" | grep -qiE '(^|[^[:alnum:]_-])(curl|wget|bb_post|Invoke-RestMethod|Invoke-WebRequest|irm|iwr)([^[:alnum:]_-]|$)' || exit 0
# Unapprove = DELETE on the same endpoint -- allowed.
printf '%s' "$flat" | grep -qiE '(-X|--request)[[:space:]]*DELETE|-Method[[:space:]]+Delete' && exit 0

jq -cn --arg r "Bitbucket PR approval blocked: company policy (amended 2026-10-16) -- AI agents may not approve pull requests; they may merge them. Review the PR (ama-pr-review), post inline comments on real issues, and ADVISE the user in this session with your verdict and the PR link; the user approves it themselves. Merging an already human-approved PR stays allowed." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
