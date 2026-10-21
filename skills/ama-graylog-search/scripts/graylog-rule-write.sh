#!/usr/bin/env bash
# The ONLY sanctioned way to write a Graylog pipeline rule. <harnessEpicKey> -- built
# because a suppression rule (63034ec5883d0a4395b3f37f, "Filter out Test Automation on
# AMA") went stale (pinned a report GUID that the API tests now mint fresh per run) and
# nothing in this harness could safely fix it. See PIPELINE-RULES.md for the mechanics
# this script exists to protect against: API route != UI route, X-Requested-By-or-400,
# stage refs are BY TITLE so a rename silently detaches a rule from its pipeline.
#
# Usage:
#   graylog-rule-write.sh update <rule-id>
#   graylog-rule-write.sh create
#
# Payload comes from a FIXED FILE, never a command-line arg or inline var -- same
# reasoning as jira-edit-issue.sh: this repo has a confirmed live failure of a
# bash-variable-held multi-line JSON body corrupting crossing the MSYS->Win32 boundary
# into curl.exe. Shape: {"title": "...", "description": "...", "source": "..."}
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
BASE_URL="$(hr_config_required '.graylog.host')" || exit 1

mode="${1:?usage: graylog-rule-write.sh update <rule-id> | create}"
rule_id="${2:-}"
case "$mode" in
  update) [ -n "$rule_id" ] || { echo "usage: graylog-rule-write.sh update <rule-id>" >&2; exit 1; } ;;
  create) : ;;
  *) echo "usage: graylog-rule-write.sh update <rule-id> | create" >&2; exit 1 ;;
esac

if [ -z "${GRAYLOG_PAT:-}" ]; then
  echo "GRAYLOG_PAT not set" >&2
  exit 1
fi

PAYLOAD_FILE="$(hstate tickets .graylog-rule-payload.json)"
if [ ! -f "$PAYLOAD_FILE" ]; then
  echo "graylog-rule-write.sh: $PAYLOAD_FILE not found -- write {title,description,source} there first (Write tool, never shell)" >&2
  exit 1
fi

AUTH=(-u "${GRAYLOG_PAT}:token")
JSONHDR=(-H "Content-Type: application/json" -H "Accept: application/json" -H "X-Requested-By: claude-harness")

# --- Step 1: back up the CURRENT rule before touching anything (update only -- a
# create has nothing to back up). Revert is one `update` call with this file as payload.
if [ "$mode" = "update" ]; then
  BACKUP_DIR="$(hstate tickets .graylog-rule-backups)"
  mkdir -p "$BACKUP_DIR"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_FILE="$BACKUP_DIR/${rule_id}-${ts}.json"
  cur="$(curl -sS -m 30 "${AUTH[@]}" -H "Accept: application/json" \
    "${BASE_URL}/api/system/pipelines/rule/${rule_id}")" || { echo "backup GET failed" >&2; exit 1; }
  printf '%s' "$cur" | jq '{title,description,source}' > "$BACKUP_FILE" 2>/dev/null
  [ -s "$BACKUP_FILE" ] || { echo "graylog-rule-write.sh: backup write failed, aborting before any write" >&2; exit 1; }
  echo "backup: $BACKUP_FILE"
fi

# --- Step 2: parse-validate the NEW source against the live grammar. This endpoint
# persists nothing -- it's a pure syntax/type check, so a broken rule can never reach
# the live pipeline through this script.
SRC_ONLY="$(mktemp)"
jq -c '{source: .source}' "$PAYLOAD_FILE" > "$SRC_ONLY"
parse_resp="$(curl -sS -m 30 "${AUTH[@]}" "${JSONHDR[@]}" -X POST \
  "${BASE_URL}/api/system/pipelines/rule/parse" -d "@$SRC_ONLY")"
rm -f "$SRC_ONLY"
errs="$(printf '%s' "$parse_resp" | jq -r '.errors // empty' 2>/dev/null)"
if [ -n "$errs" ] && [ "$errs" != "null" ]; then
  printf 'graylog-rule-write.sh: parse-validate rejected the new source, nothing written:\n%s\n' "$parse_resp" >&2
  exit 1
fi
want_title="$(jq -r '.title' "$PAYLOAD_FILE")"
parsed_title="$(printf '%s' "$parse_resp" | jq -r '.title // empty' 2>/dev/null)"
if [ "$mode" = "update" ] && [ "$parsed_title" != "$want_title" ]; then
  echo "graylog-rule-write.sh: title mismatch after parse ('$parsed_title' != '$want_title') -- refusing (stage refs are BY TITLE, a rename silently detaches this rule)" >&2
  exit 1
fi

# --- Step 3: the real write. -d @file, never -d "$var" (see header).
BODY_FILE="$(mktemp)"
jq -c '{title, description, source}' "$PAYLOAD_FILE" > "$BODY_FILE"

if [ "$mode" = "update" ]; then
  resp="$(curl -sS -w '\n%{http_code}' "${AUTH[@]}" "${JSONHDR[@]}" \
    -X PUT -d "@$BODY_FILE" "${BASE_URL}/api/system/pipelines/rule/${rule_id}")"
else
  resp="$(curl -sS -w '\n%{http_code}' "${AUTH[@]}" "${JSONHDR[@]}" \
    -X POST -d "@$BODY_FILE" "${BASE_URL}/api/system/pipelines/rule")"
fi
rm -f "$BODY_FILE"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"

if [ "$status" != "200" ]; then
  printf 'graylog-rule-write.sh: HTTP %s writing rule\n%s\n' "$status" "$respbody" >&2
  exit 1
fi

new_id="$(printf '%s' "$respbody" | jq -r '.id // empty')"
[ -n "$rule_id" ] || rule_id="$new_id"

# --- Step 4: read back and diff against what was sent -- report drift, never assume.
verify="$(curl -sS -m 30 "${AUTH[@]}" -H "Accept: application/json" \
  "${BASE_URL}/api/system/pipelines/rule/${rule_id}")"
sent_source="$(jq -r '.source' "$PAYLOAD_FILE")"
got_source="$(printf '%s' "$verify" | jq -r '.source // empty')"
if [ "$sent_source" != "$got_source" ]; then
  echo "graylog-rule-write.sh: WARNING -- source read back after write does not match what was sent. Manual check needed." >&2
  echo "$verify"
  exit 1
fi

rm -f "$PAYLOAD_FILE"
echo "OK: rule ${rule_id} (${want_title}) written and verified."
if [ "$mode" = "create" ]; then
  echo "NOTE: creating a rule does NOT attach it to any pipeline -- run graylog-pipeline-attach-rule.sh '${want_title}' next, or it will never fire."
fi
