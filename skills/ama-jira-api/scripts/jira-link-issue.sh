#!/usr/bin/env bash
# Direct Jira REST write: link two issues (POST /rest/api/3/issueLink). Added for the
# REGRESSIONS.md rule "causing ticket released -> NEW Bug linked to it" -- until 2026-10-20
# nothing in the harness could create the link, so the rule was prose only.
# Usage: jira-link-issue.sh <inward-key> <outward-key> [link-type]
#   link-type defaults to "Relates" (Jira's built-in "relates to"). Other common names on this
#   instance: "Blocks", "Cloners", "Duplicate" -- GET /rest/api/3/issueLinkType to list.
# No payload file: every input is a short key/name, nothing free-form (the file rule in
# jira-create-issue.sh's header exists for prose).
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

inward="${1:?usage: jira-link-issue.sh <inward-key> <outward-key> [link-type]}"
outward="${2:?usage: jira-link-issue.sh <inward-key> <outward-key> [link-type]}"
type="${3:-Relates}"

if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

BODY_FILE="$(mktemp)"
jq -cn --arg t "$type" --arg i "$inward" --arg o "$outward" \
  '{type:{name:$t}, inwardIssue:{key:$i}, outwardIssue:{key:$o}}' > "$BODY_FILE"

# -d @file, never -d "$var" (MSYS->Win32 corruption, see jira-add-comment.sh).
resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X POST -H "Content-Type: application/json" -d "@$BODY_FILE" \
  "https://${HOST}/rest/api/3/issueLink")"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"
rm -f "$BODY_FILE"

if [ "$status" != "201" ]; then
  printf 'jira-link-issue.sh: HTTP %s linking %s -> %s (%s)\n%s\n' "$status" "$inward" "$outward" "$type" "$respbody" >&2
  exit 1
fi
echo "OK: ${inward} ${type} ${outward}"
