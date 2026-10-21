#!/usr/bin/env bash
# jira_status <key> -- prints the ticket's CURRENT Jira status name, or nothing on any failure
# (no token, no config, curl error, 3s timeout). Read-only GET. Callers fail OPEN on empty.
# Shared by ready-to-test-regression-reminder.sh and ticket-in-progress-reminder.sh -- both
# nudged on tickets whose status made the nudge wrong (Open/Blocked/Done comments read as
# "testing steps"; a ticket recorded AFTER closing told to go In Progress), 2026-09-04/07.
# HR_CONFIG_FILE is the same test seam lib-harness-repos.sh uses; the suite shims `curl` on PATH.
jira_status() {
  local key="$1" cfg="${HR_CONFIG_FILE:-$HOME/.claude/harness-config.json}" host email
  [ -n "${ATLASSIAN_API_TOKEN:-}" ] || return 1
  host="$(jq -r '.atlassian.cloudId // empty' < "$cfg" 2>/dev/null)"
  email="$(jq -r '.user.email // empty' < "$cfg" 2>/dev/null)"
  [ -n "$host" ] && [ -n "$email" ] || return 1
  curl -s --max-time 3 -u "${email}:${ATLASSIAN_API_TOKEN}" \
    "https://${host}/rest/api/3/issue/${key}?fields=status" 2>/dev/null \
    | jq -r '.fields.status.name // empty' 2>/dev/null
}

# jira_fixversions <key> -- prints one "<name>\t<released>" line per Fix Version currently on the
# ticket, or nothing on any failure / none set (same fail-open contract as jira_status). Read-only GET.
# Used by jira-fixversion-confirm-gate.sh's released-version check. CRLF-stripped (jq 1.5rc1).
jira_fixversions() {
  local key="$1" cfg="${HR_CONFIG_FILE:-$HOME/.claude/harness-config.json}" host email
  [ -n "${ATLASSIAN_API_TOKEN:-}" ] || return 1
  host="$(jq -r '.atlassian.cloudId // empty' < "$cfg" 2>/dev/null)"
  email="$(jq -r '.user.email // empty' < "$cfg" 2>/dev/null)"
  [ -n "$host" ] && [ -n "$email" ] || return 1
  curl -s --max-time 3 -u "${email}:${ATLASSIAN_API_TOKEN}" \
    "https://${host}/rest/api/3/issue/${key}?fields=fixVersions" 2>/dev/null \
    | jq -r '.fields.fixVersions[]? | "\(.name)\t\(.released)"' 2>/dev/null | tr -d '\r'
}
