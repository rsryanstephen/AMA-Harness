#!/usr/bin/env bash
# Read a Confluence page: prints "id<TAB>version<TAB>title", writes the ADF body JSON to <out-file>.
# Replaces MCP getConfluencePage (Atlassian MCP retired 2026-08-31, <harnessEpicKey>).
# Usage: confluence-get-page.sh <page-id> <out-body-file> [atlas_doc_format|storage]
# storage = the XHTML the meeting-notes splice works on; atlas_doc_format (default) = ADF JSON.
set -euo pipefail
CONFIG="$HOME/.claude/harness-config.json"
EMAIL="$(jq -r '.user.email' "$CONFIG")"
HOST="$(jq -r '.atlassian.cloudId' "$CONFIG")"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
PID="${1:?usage: confluence-get-page.sh <page-id> <out-body-file> [format]}"
OUT="${2:?usage: confluence-get-page.sh <page-id> <out-body-file> [format]}"
FMT="${3:-atlas_doc_format}"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
curl -sS --connect-timeout 15 --max-time 120 -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  "https://${HOST}/wiki/api/v2/pages/${PID}?body-format=${FMT}" > "$TMP"
jq -e '.id' "$TMP" >/dev/null || { echo "confluence-get-page.sh: unexpected response:" >&2; head -c 300 "$TMP" >&2; exit 1; }
jq -r --arg f "$FMT" '.body[$f].value' "$TMP" > "$OUT"
jq -r '"\(.id)\t\(.version.number)\t\(.title)"' "$TMP"
