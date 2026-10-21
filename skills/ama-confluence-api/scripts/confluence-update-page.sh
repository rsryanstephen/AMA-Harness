#!/usr/bin/env bash
# Whole-body update of a Confluence page from an ADF body file (v2 PUT, version+1, fresh-read verify).
# Replaces MCP updateConfluencePage (Atlassian MCP retired 2026-08-31, <harnessEpicKey>).
# Body via FILE, never argv (same corruption rule as every write script -- see ama-jira-api SKILL).
# NOTE: this jq build has no --rawfile, so the PUT payload is built with python.
# Usage: confluence-update-page.sh <page-id> <body-file> [version-message] [atlas_doc_format|storage]
# storage = XHTML (the meeting-notes splice format); atlas_doc_format (default) = ADF JSON.
set -euo pipefail
CONFIG="$HOME/.claude/harness-config.json"
EMAIL="$(jq -r '.user.email' "$CONFIG")"
HOST="$(jq -r '.atlassian.cloudId' "$CONFIG")"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
PID="${1:?usage: confluence-update-page.sh <page-id> <body.json> [message]}"
BODY="${2:?usage: confluence-update-page.sh <page-id> <body.json> [message]}"
MSG="${3:-updated via harness}"
FMT="${4:-atlas_doc_format}"
AUTH="${EMAIL}:${ATLASSIAN_API_TOKEN}"
BASE="https://${HOST}/wiki/api/v2/pages/${PID}"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
if [ "$FMT" = "atlas_doc_format" ]; then
  jq -e . "$BODY" >/dev/null || { echo "confluence-update-page.sh: $BODY is not valid JSON (ADF doc expected)" >&2; exit 1; }
fi

curl -sS --connect-timeout 15 --max-time 120 -u "$AUTH" "$BASE" > "$TMPD/pre.json"
VER="$(jq -r '.version.number' "$TMPD/pre.json")"
TITLE="$(jq -r '.title' "$TMPD/pre.json")"
[ "$VER" != "null" ] || { echo "confluence-update-page.sh: could not read page $PID" >&2; head -c 300 "$TMPD/pre.json" >&2; exit 1; }

python - "$PID" "$TITLE" "$((VER + 1))" "$MSG" "$BODY" "$FMT" "$TMPD/put.json" <<'EOF'
import json, sys
pid, title, ver, msg, body_path, fmt, out = sys.argv[1:8]
body = open(body_path, encoding='utf-8').read()
if fmt == 'atlas_doc_format':
    json.loads(body)
json.dump({"id": pid, "status": "current", "title": title,
           "version": {"number": int(ver), "message": msg},
           "body": {"representation": fmt, "value": body}},
          open(out, 'w', encoding='utf-8'))
EOF

code="$(curl -sS --connect-timeout 15 --max-time 120 -o "$TMPD/resp.json" -w '%{http_code}' -X PUT -u "$AUTH" \
  -H "Content-Type: application/json" --data-binary "@$TMPD/put.json" "$BASE")"
[ "$code" = "200" ] || { echo "WRITE FAILED (HTTP $code)"; head -c 400 "$TMPD/resp.json"; exit 1; }

# verify from a fresh read -- a 200 alone is not proof
curl -sS --connect-timeout 15 --max-time 120 -u "$AUTH" "$BASE" > "$TMPD/post.json"
POST_VER="$(jq -r '.version.number' "$TMPD/post.json")"
[ "$POST_VER" = "$((VER + 1))" ] || { echo "VERIFY FAILED: version $VER -> $POST_VER (wanted $((VER + 1)))"; exit 1; }
echo "OK: page $PID version $VER -> $POST_VER"
