#!/usr/bin/env bash
# Append one ticket to a section of the AMA Backlog Confluence page. ADF only, verified
# after the write. This exists so backlog placement is AUTOMATIC -- no propose-and-wait.
#
# Why the shape is what it is (see commit-ticket-jira/BACKLOG-PAGE.md for the full story):
#   * ADF, never html/markdown. An html write silently drops the page's one embedded image
#     (a mediaSingle nested in a listItem) -- confirmed live, and gate-enforced by
#     confluence-media-gate.sh. This script asserts the mediaSingle count is unchanged and
#     aborts before writing if it is not.
#   * Sections are top-level listItems whose own paragraph is the section name, each
#     holding a nested bulletList of tickets -- NOT headings, and the page is several
#     sibling bulletLists. The section is located by its text, never by a fixed index.
#   * Confluence has no partial-patch API, so the whole body is written back. It is
#     re-read immediately beforehand for the current version, so a concurrent human edit
#     is not clobbered.
#   * The new inlineCard omits localId -- Confluence assigns its own; reusing one corrupts.
#
# Usage: backlog-add-ticket.sh <TICKET-KEY> [section] [position]
#   section   Bugs (default) | Tech Debt | Features -- matched by prefix, case-insensitive
#   position  last (default) | first | before:<KEY> (just above that entry, same section)
# Idempotent: exits 0 without writing if the key is already anywhere on the page.
set -euo pipefail

KEY="${1:?usage: backlog-add-ticket.sh <TICKET-KEY> [section] [position]}"
SECTION="${2:-Bugs}"
POSITION="${3:-last}"

CONFIG="$HOME/.claude/harness-config.json"
# BACKLOG_PAGE_ID: another page with the same section anatomy (backlog-epics-sync.sh lists a
# dormant epic's children on the Deferred page).
PID="${BACKLOG_PAGE_ID:-$(jq -r '.atlassian.backlogPageId' "$CONFIG" | tr -d '\r')}"
EMAIL="$(jq -r '.user.email' "$CONFIG")"
HOST="$(jq -r '.atlassian.cloudId' "$CONFIG")"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
BASE="https://${HOST}/wiki/api/v2/pages/${PID}"
AUTH="${EMAIL}:${ATLASSIAN_API_TOKEN}"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# node resolves a POSIX path like /c/Users/... or /tmp/... against the drive root
# (C:\c\Users\..., C:\tmp\...) and ENOENTs. Every path handed to node must be converted.
to_win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
WTMP="$(to_win "$TMPD")"

# --- 1. fresh read ---
curl -sS -u "$AUTH" "$BASE?body-format=atlas_doc_format" > "$TMPD/pre.json"
VER="$(jq -r '.version.number' "$TMPD/pre.json")"
TITLE="$(jq -r '.title' "$TMPD/pre.json")"
jq -r '.body.atlas_doc_format.value' "$TMPD/pre.json" > "$TMPD/body.json"

# Anchored: a bare substring made PROJ-1580 read as present whenever PROJ-15801 was.
if grep -qE "browse/$KEY([\"?]|$)" "$TMPD/body.json"; then
  echo "already present: $KEY -- nothing to do"
  exit 0
fi

MEDIA_BEFORE="$({ grep -o 'mediaSingle' "$TMPD/body.json" || true; } | wc -l | tr -d ' ')"
KEYS_BEFORE="$({ grep -o 'browse/PROJ-[0-9]\{4,6\}' "$TMPD/body.json" || true; } | wc -l | tr -d ' ')"

# --- 2. splice (node: locates the section by text, appends/prepends, reports counts) ---
KEY="$KEY" SECTION="$SECTION" POSITION="$POSITION" HOSTNAME_CFG="$HOST" \
  node "$(dirname "${BASH_SOURCE[0]}")/backlog-splice.js" \
  "$WTMP/body.json" "$WTMP/new-body.json"

MEDIA_AFTER="$({ grep -o 'mediaSingle' "$TMPD/new-body.json" || true; } | wc -l | tr -d ' ')"
KEYS_AFTER="$({ grep -o 'browse/PROJ-[0-9]\{4,6\}' "$TMPD/new-body.json" || true; } | wc -l | tr -d ' ')"
[ "$MEDIA_AFTER" = "$MEDIA_BEFORE" ] || { echo "ABORT: mediaSingle $MEDIA_BEFORE -> $MEDIA_AFTER"; exit 1; }
[ "$KEYS_AFTER" = "$((KEYS_BEFORE + 1))" ] || { echo "ABORT: ticket keys $KEYS_BEFORE -> $KEYS_AFTER (want +1)"; exit 1; }

# --- 3. write whole body back ---
# NOTE the argv offset: with `node -e`, process.argv is [execPath, ...userArgs] -- there is
# NO script-path element, so user args start at index 1, not 2. Destructuring with the
# familiar [,,a,b] (right for `node file.js`) silently shifts every argument by one.
node -e '
const fs=require("fs");
const [,id,title,version,bodyPath,outPath,msg]=process.argv;
const body=fs.readFileSync(bodyPath,"utf8"); JSON.parse(body);
fs.writeFileSync(outPath,JSON.stringify({id,status:"current",title,
  version:{number:Number(version),message:msg},
  body:{representation:"atlas_doc_format",value:body}}));
' "$PID" "$TITLE" "$((VER + 1))" "$WTMP/new-body.json" "$WTMP/put.json" "Add $KEY to $SECTION backlog"

code="$(curl -sS -o "$TMPD/resp.json" -w '%{http_code}' -X PUT -u "$AUTH" \
  -H "Content-Type: application/json" --data-binary "@$TMPD/put.json" "$BASE")"
[ "$code" = "200" ] || { echo "WRITE FAILED (HTTP $code)"; head -c 400 "$TMPD/resp.json"; exit 1; }

# --- 4. verify from a fresh read; a silent 200 is not proof ---
curl -sS -u "$AUTH" "$BASE?body-format=atlas_doc_format" > "$TMPD/post.json"
jq -r '.body.atlas_doc_format.value' "$TMPD/post.json" > "$TMPD/post-body.json"
POST_MEDIA="$({ grep -o 'mediaSingle' "$TMPD/post-body.json" || true; } | wc -l | tr -d ' ')"
POST_KEYS="$({ grep -o 'browse/PROJ-[0-9]\{4,6\}' "$TMPD/post-body.json" || true; } | wc -l | tr -d ' ')"
grep -qE "browse/$KEY([\"?]|$)" "$TMPD/post-body.json" || { echo "VERIFY FAILED: $KEY absent after write"; exit 1; }
[ "$POST_MEDIA" = "$MEDIA_BEFORE" ] || { echo "VERIFY FAILED: mediaSingle now $POST_MEDIA (was $MEDIA_BEFORE) -- image lost, see ama-confluence-api restore recipe"; exit 1; }
[ "$POST_KEYS" = "$((KEYS_BEFORE + 1))" ] || { echo "VERIFY FAILED: ticket keys now $POST_KEYS"; exit 1; }

echo "added $KEY to $SECTION ($POSITION); version $VER -> $(jq -r '.version.number' "$TMPD/post.json"); mediaSingle=$POST_MEDIA; ticketKeys=$POST_KEYS"
