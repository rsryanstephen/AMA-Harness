#!/usr/bin/env bash
# Direct Jira REST write, replacing transitionJiraIssue. Get the transition ID first
# via jira-get-transitions.sh (never hardcode -- per-ticket, see commit-ticket-jira/SKILL.md).
# No payload file needed for a bare transition; if the target transition requires
# fields (see commit-ticket-jira's "missing required information" case), write them to the
# same fixed payload file jira-create-issue.sh/jira-edit-issue.sh use --
# {"fields": {...}} -- picked up here only if that file exists.
# Usage: jira-transition-issue.sh <ticket-key> <transition-id>
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

key="${1:?usage: jira-transition-issue.sh <ticket-key> <transition-id>}"
transition_id="${2:?usage: jira-transition-issue.sh <ticket-key> <transition-id>}"

if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

PAYLOAD_FILE="${JIRA_PAYLOAD_FILE:-}"   # optional: a bare transition needs no payload; set it (per-call path) only when fields are required
BODY_FILE="$(mktemp)"
if [ -n "$PAYLOAD_FILE" ] && [ -f "$PAYLOAD_FILE" ]; then
  jq -c --arg id "$transition_id" '{transition: {id: $id}, fields: (.fields // {})}' "$PAYLOAD_FILE" > "$BODY_FILE"
else
  jq -cn --arg id "$transition_id" '{transition: {id: $id}}' > "$BODY_FILE"
fi

# -d @file, never -d "$var" -- a bash-variable-held body corrupts crossing the
# MSYS->Win32 boundary into curl.exe (confirmed live on jira-append-description.sh:
# identical JSON via -d @file got 204, the same content via -d "$body" 400'd with
# "error parsing JSON" -- reproducible, tied to specific byte content, not size alone).
resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X POST -H "Content-Type: application/json" -d "@$BODY_FILE" \
  "https://${HOST}/rest/api/3/issue/${key}/transitions")"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"

rm -f "$BODY_FILE"

if [ "$status" != "204" ]; then
  printf 'jira-transition-issue.sh: HTTP %s for %s -> transition %s\n%s\n' "$status" "$key" "$transition_id" "$respbody" >&2
  exit 1
fi

# Payload consumed only on success -- a failed write keeps it for retry without rewrite.
[ -f "$PAYLOAD_FILE" ] && rm -f "$PAYLOAD_FILE"

# Backlog follows the status: the page lists work NOT being worked. Started or resolved ->
# off the page; back to To Do -> on it again. The other half is jira-create-issue.sh's add.
# statusCategory decides, EXCEPT that re-adding needs a name check too (see below --
# this project's categories lie). Never fails the transition, and
# never replaces backlog-prune-resolved.sh's periodic sweep -- most closures happen in
# another session or the Jira UI where no hook sees them (that script's header has the
# measurement).
if [ "${BACKLOG_SKIP:-0}" != "1" ]; then
  status_json="$(curl -s -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
    "https://${HOST}/rest/api/3/issue/${key}?fields=status")"
  category="$(printf '%s' "$status_json" | jq -r '.fields.status.statusCategory.key // empty')"
  status_name="$(printf '%s' "$status_json" | jq -r '.fields.status.name // empty')"
  # PROJ miscategorises: QA, Test Complete, Review, Blocked and "on hold" all report
  # statusCategory=new, so category alone re-added finished work to the page (PROJ-15254
  # bounced back on twice, 2026-09-10). Only genuinely-unstarted NAMES re-add; other "new" prunes.
  case "$status_name" in
    Open|"To Do") ;;
    *) [ "$category" = "new" ] && category="indeterminate" ;;
  esac
  ADD_TO_BACKLOG="$HOME/.claude/skills/commit-ticket-jira/scripts/backlog-add-ticket.sh"
  PRUNE_BACKLOG="$HOME/.claude/skills/commit-ticket-jira/scripts/backlog-prune-resolved.sh"
  case "$category" in
    indeterminate|done)
      [ -f "$PRUNE_BACKLOG" ] && { bash "$PRUNE_BACKLOG" "$key" >&2 || \
        printf 'jira-transition-issue.sh: %s is %s but still on the backlog page -- retry: bash %s %s\n' \
          "$key" "$category" "$PRUNE_BACKLOG" "$key" >&2; }
      ;;
    new)
      # same deliberately-off-page exceptions jira-create-issue.sh honours
      for standing in "$(hr_config '.atlassian.regressionsTicketKey' '')" \
                      "$(hr_config '.atlassian.harnessTestTicketKey' '')"; do
        [ -n "$standing" ] && [ "$key" = "$standing" ] && ADD_TO_BACKLOG=""
      done
      [ -n "$ADD_TO_BACKLOG" ] && [ -f "$ADD_TO_BACKLOG" ] && { bash "$ADD_TO_BACKLOG" "$key" >&2 || \
        printf 'jira-transition-issue.sh: %s is back to To Do but not on the backlog page -- retry: bash %s %s\n' \
          "$key" "$ADD_TO_BACKLOG" "$key" >&2; }
      ;;
  esac
fi

echo "OK: ${key} transitioned (id ${transition_id})"
