#!/usr/bin/env bash
# Move an existing ticket entry to the FIRST position of the list it sits in on the AMA
# Backlog Confluence page -- the "this is now the top priority" edit. backlog-add-ticket.sh
# exits 0 on an already-present key and backlog-demote-ticket.sh moves between PAGES, so
# re-prioritising inside a section had no script (PROJ-15801, 2026-10-14; the one-off
# splice used that day is promoted here). Same shape as backlog-add-ticket.sh: ADF only, the
# whole body re-read then written back, mediaSingle and ticket-key counts asserted before
# and after, verified from a fresh read.
#
# Usage: backlog-move-first.sh <TICKET-KEY> [--section "<name>"] [--dry-run]
# Matches the listItem whose OWN paragraph links the key, so a section line that merely
# mentions it is never moved. Exit 1 when the key is not a list entry on the page.
# --section moves the entry (node + annotation intact) to the top of ANOTHER section on the
# same page, matched by prefix, case-insensitive (e.g. "Low Priority Tech Debt"; add-ticket
# refuses a key already on the page, so re-sectioning had no path -- 2026-10-20).
set -euo pipefail

KEY="${1:?usage: backlog-move-first.sh <TICKET-KEY> [--section NAME] [--dry-run]}"; shift
DRY=""; SECTION=""
while [ $# -gt 0 ]; do
  case "$1" in --dry-run) DRY="--dry-run" ;; --section) SECTION="${2:?--section needs a name}"; shift ;; esac; shift
done

CONFIG="$HOME/.claude/harness-config.json"
PID="$(jq -r '.atlassian.backlogPageId' "$CONFIG" | tr -d '\r')"
EMAIL="$(jq -r '.user.email' "$CONFIG" | tr -d '\r')"
HOST="$(jq -r '.atlassian.cloudId' "$CONFIG" | tr -d '\r')"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
BASE="https://${HOST}/wiki/api/v2/pages/${PID}"
AUTH="${EMAIL}:${ATLASSIAN_API_TOKEN}"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
# node resolves a POSIX path (/c/Users/..., /tmp/...) against the drive root and ENOENTs.
to_win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
WTMP="$(to_win "$TMPD")"
cnt() { { grep -o "$1" "$2" || true; } | wc -l | tr -d ' '; }

# --- 1. fresh read ---
curl -sS -u "$AUTH" "$BASE?body-format=atlas_doc_format" > "$TMPD/pre.json"
VER="$(jq -r '.version.number' "$TMPD/pre.json" | tr -d '\r')"
TITLE="$(jq -r '.title' "$TMPD/pre.json" | tr -d '\r')"
jq -r '.body.atlas_doc_format.value' "$TMPD/pre.json" > "$TMPD/body.json"
MEDIA_BEFORE="$(cnt mediaSingle "$TMPD/body.json")"
KEYS_BEFORE="$(cnt 'browse/PROJ-[0-9]\{4,6\}' "$TMPD/body.json")"

# --- 2. move (node: the listItem whose OWN paragraph links the key goes to index 0 of its list) ---
# `node -e` argv has no script-path element: user args start at index 1.
KEY="$KEY" SECTION="$SECTION" node -e '
const fs = require("fs"); const [, inP, outP] = process.argv; const key = process.env.KEY; const section = process.env.SECTION;
const doc = JSON.parse(fs.readFileSync(inP, "utf8"));
const has = n => { const s = JSON.stringify(n); return s.includes("browse/" + key + "\"") || s.includes("browse/" + key + "?"); };
const text = n => (n.content || []).map(c => c.text || text(c)).join("");
let done = false;
const walk = n => {
  if (done || !n || !n.content) return;
  if (n.type === "bulletList" || n.type === "orderedList") {
    const i = n.content.findIndex(li => { const p = (li.content || []).find(c => c.type === "paragraph"); return p && has(p); });
    if (i >= 0) {
      const top = n.content.slice(0, 3).map(li => (JSON.stringify((li.content || []).find(c => c.type === "paragraph") || {}).match(/PROJ-\d+/) || ["?"])[0]);
      const [it] = n.content.splice(i, 1); done = true;
      if (!section) { n.content.unshift(it); console.log("moved " + key + " from index " + i + " to 0; previous top 3: " + top.join(", ")); return; }
      moved = it; return;
    }
  }
  n.content.forEach(walk);
};
let moved = null;
walk(doc);
if (!done) { console.error("not a list entry on the page: " + key); process.exit(1); }
if (section) {
  // Section = a listItem whose OWN paragraph text starts with the name, holding a nested bulletList.
  let target = null;
  const find = n => { if (target || !n || !n.content) return;
    if (n.type === "listItem") { const p = n.content.find(c => c.type === "paragraph");
      if (p && text(p).trim().toLowerCase().startsWith(section.toLowerCase())) { target = n.content.find(c => c.type === "bulletList"); if (target) return; } }
    n.content.forEach(find); };
  find(doc);
  if (!target) { console.error("no section starting with: " + section); process.exit(1); }
  target.content.unshift(moved);
  console.log("moved " + key + " to the top of section \"" + section + "\"");
}
fs.writeFileSync(outP, JSON.stringify(doc));
' "$WTMP/body.json" "$WTMP/new-body.json"

[ "$(cnt mediaSingle "$TMPD/new-body.json")" = "$MEDIA_BEFORE" ] || { echo "ABORT: mediaSingle count changed"; exit 1; }
[ "$(cnt 'browse/PROJ-[0-9]\{4,6\}' "$TMPD/new-body.json")" = "$KEYS_BEFORE" ] || { echo "ABORT: ticket key count changed"; exit 1; }
[ "$DRY" = "--dry-run" ] && { echo "dry-run ok (nothing written)"; exit 0; }

# --- 3. write whole body back ---
node -e '
const fs = require("fs");
const [, id, title, version, bodyPath, outPath, msg] = process.argv;
const body = fs.readFileSync(bodyPath, "utf8"); JSON.parse(body);
fs.writeFileSync(outPath, JSON.stringify({ id, status: "current", title, version: { number: Number(version), message: msg }, body: { representation: "atlas_doc_format", value: body } }));
' "$PID" "$TITLE" "$((VER + 1))" "$WTMP/new-body.json" "$WTMP/put.json" "Move $KEY to the top of its section"
code="$(curl -sS -o "$TMPD/resp.json" -w '%{http_code}' -X PUT -u "$AUTH" -H "Content-Type: application/json" --data-binary "@$TMPD/put.json" "$BASE")"
[ "$code" = "200" ] || { echo "WRITE FAILED (HTTP $code)"; head -c 400 "$TMPD/resp.json"; exit 1; }

# --- 4. verify from a fresh read; a silent 200 is not proof ---
curl -sS -u "$AUTH" "$BASE?body-format=atlas_doc_format" | jq -r '.body.atlas_doc_format.value' > "$TMPD/post-body.json"
[ "$(cnt mediaSingle "$TMPD/post-body.json")" = "$MEDIA_BEFORE" ] || { echo "VERIFY FAILED: mediaSingle changed -- image lost, see ama-confluence-api restore recipe"; exit 1; }
[ "$(cnt 'browse/PROJ-[0-9]\{4,6\}' "$TMPD/post-body.json")" = "$KEYS_BEFORE" ] || { echo "VERIFY FAILED: ticket key count changed"; exit 1; }
echo "moved $KEY to the top of ${SECTION:+section \"$SECTION\"}${SECTION:-its section}; version $VER -> $((VER + 1)); mediaSingle=$MEDIA_BEFORE; ticketKeys=$KEYS_BEFORE"
