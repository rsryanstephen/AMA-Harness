#!/usr/bin/env bash
# Demote one Open ticket from the main AMA Backlog page to the Deferred child page,
# carrying its hand-written annotation with it. ADF only, both pages verified after write.
#
# Why this exists (see commit-ticket-jira/BACKLOG-PAGE.md):
#   * backlog-prune-resolved.sh only removes statusCategory = Done. A demotion moves an
#     entry that is still Open, so neither existing script covers it.
#   * The main page must not grow: a promotion onto it is paid for by a demotion off it.
#     Standing rule 2026-09-04 -- see the "Rebalancing" section of BACKLOG-PAGE.md.
#   * The entry's annotation ("This never re-occurred", "Is this still needed?") is the
#     justification for the demotion. backlog-demote.js moves the paragraph node verbatim
#     rather than rebuilding it, so those notes cannot be lost in transit.
#   * html writes are gate-denied on the main page (it holds a mediaSingle nested in a
#     listItem that the HTML->ADF converter drops). ADF only, mediaSingle count asserted.
#
# Usage: backlog-demote-ticket.sh <TICKET-KEY> [deferred-section] [--dry-run]
#   deferred-section  Low Priority (default) | Bugs | Tech Debt | Features
# Idempotent: exits 0 without writing if the key is already on the Deferred page.
set -euo pipefail

KEY=""; SECTION="Low Priority"; DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    *) if [ -z "$KEY" ]; then KEY="$arg"; else SECTION="$arg"; fi ;;
  esac
done
[ -n "$KEY" ] || { echo "usage: backlog-demote-ticket.sh <TICKET-KEY> [deferred-section] [--dry-run]" >&2; exit 64; }

CONFIG="$HOME/.claude/harness-config.json"
MAIN_PID="$(jq -r '.atlassian.backlogPageId' "$CONFIG")"
DEF_PID="$(jq -r '.atlassian.deferredBacklogPageId' "$CONFIG")"
EMAIL="$(jq -r '.user.email' "$CONFIG")"
HOST="$(jq -r '.atlassian.cloudId' "$CONFIG")"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
AUTH="${EMAIL}:${ATLASSIAN_API_TOKEN}"
MAIN_BASE="https://${HOST}/wiki/api/v2/pages/${MAIN_PID}"
DEF_BASE="https://${HOST}/wiki/api/v2/pages/${DEF_PID}"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
# node resolves a POSIX path like /tmp/... against the drive root and ENOENTs -- convert.
to_win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
WTMP="$(to_win "$TMPD")"
SCRIPTS="$(dirname "${BASH_SOURCE[0]}")"

# Card URLs only (browse/KEY): annotations may name other tickets -- see backlog-prune-resolved.sh.
count_keys() { { grep -o 'browse/PROJ-[0-9]\{4,6\}' "$1" || true; } | wc -l | tr -d ' '; }
count_media() { { grep -o 'mediaSingle' "$1" || true; } | wc -l | tr -d ' '; }

# --- 1. fresh read of both pages ---
curl -sS -u "$AUTH" "$MAIN_BASE?body-format=atlas_doc_format" > "$TMPD/main-pre.json"
curl -sS -u "$AUTH" "$DEF_BASE?body-format=atlas_doc_format" > "$TMPD/def-pre.json"
MAIN_VER="$(jq -r '.version.number' "$TMPD/main-pre.json")"
DEF_VER="$(jq -r '.version.number' "$TMPD/def-pre.json")"
MAIN_TITLE="$(jq -r '.title' "$TMPD/main-pre.json")"
DEF_TITLE="$(jq -r '.title' "$TMPD/def-pre.json")"
[ "$MAIN_VER" != "null" ] && [ "$DEF_VER" != "null" ] || { echo "could not read both pages" >&2; exit 1; }
jq -r '.body.atlas_doc_format.value' "$TMPD/main-pre.json" > "$TMPD/main-body.json"
jq -r '.body.atlas_doc_format.value' "$TMPD/def-pre.json" > "$TMPD/def-body.json"

if grep -q "browse/$KEY" "$TMPD/def-body.json"; then
  echo "already on the Deferred page: $KEY -- nothing to do"
  exit 0
fi
grep -q "browse/$KEY" "$TMPD/main-body.json" || { echo "not on the main page: $KEY -- nothing to demote" >&2; exit 1; }

MAIN_KEYS_BEFORE="$(count_keys "$TMPD/main-body.json")"
DEF_KEYS_BEFORE="$(count_keys "$TMPD/def-body.json")"
MAIN_MEDIA_BEFORE="$(count_media "$TMPD/main-body.json")"

# --- 2. splice both bodies (node: locates by text, moves the node verbatim) ---
KEY="$KEY" SECTION="$SECTION" node "$SCRIPTS/backlog-demote.js" \
  "$WTMP/main-body.json" "$WTMP/def-body.json" \
  "$WTMP/main-new.json" "$WTMP/def-new.json"

MAIN_KEYS_AFTER="$(count_keys "$TMPD/main-new.json")"
DEF_KEYS_AFTER="$(count_keys "$TMPD/def-new.json")"
MAIN_MEDIA_AFTER="$(count_media "$TMPD/main-new.json")"
[ "$MAIN_MEDIA_AFTER" = "$MAIN_MEDIA_BEFORE" ] || { echo "ABORT: main mediaSingle $MAIN_MEDIA_BEFORE -> $MAIN_MEDIA_AFTER"; exit 1; }
[ "$MAIN_KEYS_AFTER" = "$((MAIN_KEYS_BEFORE - 1))" ] || { echo "ABORT: main keys $MAIN_KEYS_BEFORE -> $MAIN_KEYS_AFTER (want -1)"; exit 1; }
[ "$DEF_KEYS_AFTER" = "$((DEF_KEYS_BEFORE + 1))" ] || { echo "ABORT: deferred keys $DEF_KEYS_BEFORE -> $DEF_KEYS_AFTER (want +1)"; exit 1; }
grep -q "browse/$KEY" "$TMPD/main-new.json" && { echo "ABORT: $KEY still on the main body after removal"; exit 1; }
grep -q "browse/$KEY" "$TMPD/def-new.json" || { echo "ABORT: $KEY absent from the deferred body after insert"; exit 1; }

if [ "$DRY" = 1 ]; then
  echo "DRY RUN ok: $KEY main $MAIN_KEYS_BEFORE -> $MAIN_KEYS_AFTER (v$MAIN_VER), deferred $DEF_KEYS_BEFORE -> $DEF_KEYS_AFTER (v$DEF_VER), mediaSingle $MAIN_MEDIA_AFTER -- nothing written"
  exit 0
fi

# --- 3. write. Deferred FIRST: if the second write fails the key is on both pages, which
# the pickup path dedupes harmlessly. Main-first would drop the entry off both. ---
put_page() { # <base> <id> <title> <next-version> <body-file> <message>
  node -e '
const fs=require("fs");
const [,id,title,version,bodyPath,outPath,msg]=process.argv;
const body=fs.readFileSync(bodyPath,"utf8"); JSON.parse(body);
fs.writeFileSync(outPath,JSON.stringify({id,status:"current",title,
  version:{number:Number(version),message:msg},
  body:{representation:"atlas_doc_format",value:body}}));
' "$2" "$3" "$4" "$5" "$WTMP/put.json" "$6"
  local code
  code="$(curl -sS -o "$TMPD/resp.json" -w '%{http_code}' -X PUT -u "$AUTH" \
    -H "Content-Type: application/json" --data-binary "@$TMPD/put.json" "$1")"
  [ "$code" = "200" ] || { echo "WRITE FAILED on $2 (HTTP $code)"; head -c 400 "$TMPD/resp.json"; return 1; }
}

put_page "$DEF_BASE" "$DEF_PID" "$DEF_TITLE" "$((DEF_VER + 1))" "$WTMP/def-new.json" \
  "Demote $KEY from the main backlog to $SECTION"
put_page "$MAIN_BASE" "$MAIN_PID" "$MAIN_TITLE" "$((MAIN_VER + 1))" "$WTMP/main-new.json" \
  "Demote $KEY to the Deferred page ($SECTION)"

# --- 4. verify from fresh reads; a silent 200 is not proof ---
curl -sS -u "$AUTH" "$MAIN_BASE?body-format=atlas_doc_format" | jq -r '.body.atlas_doc_format.value' > "$TMPD/main-post.json"
curl -sS -u "$AUTH" "$DEF_BASE?body-format=atlas_doc_format" | jq -r '.body.atlas_doc_format.value' > "$TMPD/def-post.json"
grep -q "browse/$KEY" "$TMPD/main-post.json" && { echo "VERIFY FAILED: $KEY still on the main page"; exit 1; }
grep -q "browse/$KEY" "$TMPD/def-post.json" || { echo "VERIFY FAILED: $KEY absent from the Deferred page"; exit 1; }
POST_MEDIA="$(count_media "$TMPD/main-post.json")"
[ "$POST_MEDIA" = "$MAIN_MEDIA_BEFORE" ] || { echo "VERIFY FAILED: main mediaSingle now $POST_MEDIA (was $MAIN_MEDIA_BEFORE) -- image lost, see ama-confluence-api restore recipe"; exit 1; }
[ "$(count_keys "$TMPD/main-post.json")" = "$((MAIN_KEYS_BEFORE - 1))" ] || { echo "VERIFY FAILED: main key count"; exit 1; }
[ "$(count_keys "$TMPD/def-post.json")" = "$((DEF_KEYS_BEFORE + 1))" ] || { echo "VERIFY FAILED: deferred key count"; exit 1; }

echo "demoted $KEY -> Deferred/$SECTION; main v$MAIN_VER -> $((MAIN_VER + 1)) ($MAIN_KEYS_BEFORE -> $MAIN_KEYS_AFTER keys), deferred v$DEF_VER -> $((DEF_VER + 1)) ($DEF_KEYS_BEFORE -> $DEF_KEYS_AFTER keys), mediaSingle=$POST_MEDIA"
