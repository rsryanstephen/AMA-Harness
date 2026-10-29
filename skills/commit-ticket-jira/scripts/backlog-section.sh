#!/usr/bin/env bash
# Print one section of the AMA Backlog page in page order -- what a priority-fit placement
# is judged against (user rule 2026-10-22: a ticket Claude raises goes where its priority
# fits, not blindly last). Page order IS the ranking; Jira `priority` is shown but is mostly
# an unused default on this page, so judge by summary + the hand-written note.
#
# Usage: backlog-section.sh [section]     no section -> list the section names
# Out:   rank <TAB> key <TAB> status <TAB> type <TAB> priority <TAB> summary <TAB> note
# Then place with: backlog-move-first.sh <NEW> --before <KEY>  (or BACKLOG_POSITION=before:<KEY> at create)
set -euo pipefail
SECTION="${1:-}"
CONFIG="$HOME/.claude/harness-config.json"
PID="$(jq -r '.atlassian.backlogPageId' "$CONFIG" | tr -d '\r')"
EMAIL="$(jq -r '.user.email' "$CONFIG" | tr -d '\r')"
HOST="$(jq -r '.atlassian.cloudId' "$CONFIG" | tr -d '\r')"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
to_win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
curl -sS -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" "https://${HOST}/wiki/api/v2/pages/${PID}?body-format=atlas_doc_format" \
  | jq -r '.body.atlas_doc_format.value' > "$TMPD/body.json"
SECTION="$SECTION" node "$(to_win "$(dirname "${BASH_SOURCE[0]}")/backlog-section.js")" "$(to_win "$TMPD/body.json")" | tr -d '\r' > "$TMPD/rows"
[ -n "$SECTION" ] && [ -s "$TMPD/rows" ] || { cat "$TMPD/rows"; exit 0; }
bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh" \
  "key in ($(cut -f2 "$TMPD/rows" | paste -sd,))" "summary,status,issuetype,priority" 200 | tr -d '\r' > "$TMPD/jira"
# jira-search row: key summary status issuetype priority
awk -F'\t' 'NR==FNR { s[$1]=$2; st[$1]=$3; t[$1]=$4; p[$1]=$5; next }
  { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, st[$2], t[$2], p[$2], s[$2], $3 }' "$TMPD/jira" "$TMPD/rows"
