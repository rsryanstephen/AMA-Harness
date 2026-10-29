#!/usr/bin/env bash
# Create a Confluence page from an ADF body file (v2 POST). Prints "id<TAB>webui-url".
# Replaces MCP createConfluencePage (Atlassian MCP retired 2026-08-31, <harnessEpicKey>).
# Usage: confluence-create-page.sh <space-id> <title> <body.json> [parent-page-id]
set -euo pipefail
CONFIG="$HOME/.claude/harness-config.json"
EMAIL="$(jq -r '.user.email' "$CONFIG")"
HOST="$(jq -r '.atlassian.cloudId' "$CONFIG")"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
SPACE="${1:?usage: confluence-create-page.sh <space-id> <title> <body.json> [parent-id]}"
TITLE="${2:?usage: confluence-create-page.sh <space-id> <title> <body.json> [parent-id]}"
BODY="${3:?usage: confluence-create-page.sh <space-id> <title> <body.json> [parent-id]}"
PARENT="${4:-}"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
jq -e . "$BODY" >/dev/null || { echo "confluence-create-page.sh: $BODY is not valid JSON (ADF doc expected)" >&2; exit 1; }

python - "$SPACE" "$TITLE" "$BODY" "$PARENT" "$TMPD/post.json" <<'EOF'
import json, sys
space, title, body_path, parent, out = sys.argv[1:6]
body = open(body_path, encoding='utf-8').read()
json.loads(body)
doc = {"spaceId": space, "status": "current", "title": title,
       "body": {"representation": "atlas_doc_format", "value": body}}
if parent:
    doc["parentId"] = parent
json.dump(doc, open(out, 'w', encoding='utf-8'))
EOF

code="$(curl -sS -o "$TMPD/resp.json" -w '%{http_code}' -X POST -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -H "Content-Type: application/json" --data-binary "@$TMPD/post.json" \
  "https://${HOST}/wiki/api/v2/pages")"
[ "$code" = "200" ] || [ "$code" = "201" ] || { echo "CREATE FAILED (HTTP $code)"; head -c 400 "$TMPD/resp.json"; exit 1; }
# no backslash interpolation ("\(...)"): MSYS argv conversion can mangle it into "/(...)" (seen live)
jq -r --arg host "$HOST" '[.id, ("https://" + $host + "/wiki" + ._links.webui)] | @tsv' "$TMPD/resp.json"
