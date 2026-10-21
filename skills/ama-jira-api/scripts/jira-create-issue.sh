#!/usr/bin/env bash
# Direct Jira REST write, replacing createJiraIssue. Reads its payload from the PER-CALL
# file named by JIRA_PAYLOAD_FILE -- required, no default (the shared
# .jira-write-payload.json was retired 2026-09-07, concurrent sessions clobbered it) --
# NEVER embedded as a command-line
# argument. This is the same reason ama-bitbucket-api/SKILL.md says to write PR
# comment text to a file first, not shell: quote/non-ASCII corruption. It's also what
# lets jira-ticket-fields-gate.sh / harness-ticket-gate.sh / jira-fixversion-confirm-
# gate.sh keep reading structured JSON (from the file) instead of having to parse it
# back out of command text, which is a much more fragile surface.
#
# Payload file shape: {"summary": "...", "assignee_account_id": "...",
# "description": "wiki markup, see commit-ticket/TICKET-TEMPLATE.md",
# "additional_fields": {"<epicLinkFieldId>": "PROJ-XXXXX", "fixVersions": [...], ...}}
# Usage: jira-create-issue.sh <project-key> <issuetype>
#
# This POSTs to /rest/api/2/issue, not v3 like the other scripts here -- v2 takes
# `description` as a plain wiki-markup string (h2./*bullets/#numbered), which the
# create/edit UI already renders that way (confirmed live against existing tickets:
# GET .../rest/api/2/issue/<key>?fields=description round-trips h2./#/*/{{}} as text, not
# ADF). v3 would need a hand-built ADF doc for description, same problem jira-add-
# comment.sh solves for comments -- not worth duplicating here since v2 just takes it raw.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

project="${1:?usage: jira-create-issue.sh <project-key> <issuetype>}"
issuetype="${2:?usage: jira-create-issue.sh <project-key> <issuetype>}"

PAYLOAD_FILE="${JIRA_PAYLOAD_FILE:?set JIRA_PAYLOAD_FILE=<per-call path> -- the shared default was retired 2026-09-07 (concurrent sessions clobbered it), see ama-jira-api SKILL.md}"
if [ ! -f "$PAYLOAD_FILE" ]; then
  echo "jira-create-issue.sh: $PAYLOAD_FILE not found -- write the payload there first (Write tool, never shell)" >&2
  exit 1
fi
if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

BODY_FILE="$(mktemp)"
jq -c --arg proj "$project" --arg type "$issuetype" '
  {
    fields: (
      {project: {key: $proj}, issuetype: {name: $type}, summary: .summary}
      + (if .description then {description: .description} else {} end)
      + (if .assignee_account_id then {assignee: {accountId: .assignee_account_id}} else {} end)
      + (.additional_fields // {})
    )
  }
' "$PAYLOAD_FILE" > "$BODY_FILE"

# -d @file, never -d "$var" -- a bash-variable-held body corrupts crossing the
# MSYS->Win32 boundary into curl.exe (confirmed live on jira-append-description.sh:
# identical JSON via -d @file got 204, the same content via -d "$body" 400'd with
# "error parsing JSON" -- reproducible, tied to specific byte content, not size alone).
resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X POST -H "Content-Type: application/json" -d "@$BODY_FILE" \
  "https://${HOST}/rest/api/2/issue")"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"

rm -f "$BODY_FILE"

if [ "$status" != "200" ] && [ "$status" != "201" ]; then
  printf 'jira-create-issue.sh: HTTP %s\n%s\n' "$status" "$respbody" >&2
  exit 1
fi

# Postcheck: the body builder once silently dropped .description -- create returned 201,
# ticket landed with an EMPTY description (4 tickets before it was caught). If the
# payload had one, re-GET and fail loud when it didn't stick; payload file kept.
new_key="$(printf '%s' "$respbody" | jq -r '.key // empty')"
if [ -n "$new_key" ] && jq -e '(.description // "") != ""' "$PAYLOAD_FILE" >/dev/null 2>&1; then
  got_desc="$(curl -s -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
    "https://${HOST}/rest/api/2/issue/${new_key}?fields=description" | jq -r '.fields.description // ""')"
  if [ -z "$got_desc" ]; then
    printf '%s' "$respbody" | jq -r '"\(.key)\t\(.self)"'
    printf 'jira-create-issue.sh: %s created but its description is EMPTY despite the payload having one -- repair with a v2 PUT (see SKILL.md); payload file kept.\n' "$new_key" >&2
    exit 1
  fi
fi

rm -f "$PAYLOAD_FILE"

# Backlog placement is automatic -- a ticket created here used to be invisible to the
# backlog page unless the caller separately remembered the writer (PROJ-15373 landed
# off-page that way). Never fails the create: the ticket already exists by this point.
# Removal on pickup is jira-transition-issue.sh's half.
ADD_TO_BACKLOG="$HOME/.claude/skills/commit-ticket-jira/scripts/backlog-add-ticket.sh"
if [ -n "$new_key" ] && [ "${BACKLOG_SKIP:-0}" != "1" ] && [ -f "$ADD_TO_BACKLOG" ]; then
  case "$issuetype" in
    Epic|epic) section="" ;;                        # epics are not backlog items
    Bug|bug) section="Bugs" ;;
    Story|story|"New Feature"|Improvement) section="Features" ;;
    *) section="Tech Debt" ;;
  esac
  # No standing-key exclusions here, deliberately: the two deliberately-off-page tickets
  # (Regressions bucket, harness test fixture) already exist, so a create can never produce
  # their keys. jira-transition-issue.sh's re-add DOES need the check -- those tickets get
  # transitioned. This path only ever adds the one key it just created; it reads nothing else.
  if [ -n "${BACKLOG_SECTION:-}" ]; then section="$BACKLOG_SECTION"; fi
  if [ -n "$section" ]; then
    if ! bash "$ADD_TO_BACKLOG" "$new_key" "$section" last >&2; then
      printf 'jira-create-issue.sh: %s created but NOT added to the backlog page -- retry with: bash %s %s "%s" last\n' \
        "$new_key" "$ADD_TO_BACKLOG" "$new_key" "$section" >&2
    fi
  fi
fi

printf '%s' "$respbody" | jq -r '"\(.key)\t\(.self)"'
