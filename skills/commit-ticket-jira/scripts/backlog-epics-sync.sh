#!/usr/bin/env bash
# Keep the "Epics" index at the top of the AMA Backlog page in step with Jira (user rules
# 2026-10-22). A ticket inside a LISTED epic stays off the page -- the epic carries it, and
# backlog-candidates.sh offers its children under it, in index order, ahead of the sections.
#
#   ACTIVE epic  = Open / To Do, has an Open / To Do child, and some child was created or
#                  moved status in the last 365 days -> one entry in the index. NOT `updated`:
#                  listing a ticket on a Confluence page adds a Jira "mentioned in" link and
#                  bumps it, so listing a dormant epic's children made it look active (2026-10-22).
#   DORMANT epic = Open / To Do with unresolved children but no child activity in a year,
#                  and not listed anywhere on the page -> not indexed; instead each of its
#                  Open / To Do / Blocked / on hold children is listed by itself, on the
#                  DEFERRED page (old work; the main page does not grow), section by type.
# Never indexed: the harness epic (harness work gets no sub-tickets) and a started or
# resolved epic (the prune sweep removes started work from the page) -- their children are
# listed by themselves like any ticket.
#
# DUPLICATES: a child of an indexed epic is listed by itself too ONLY when its Jira priority is
# Show-stopper or Critical -- inside an epic its priority would get lost. Any other indexed-epic
# child found on either page is removed (user rule 2026-10-22). --keep K1,K2 spares keys for one
# run (a pending decision); raise a ticket's Jira priority to keep it for good.
#
# Usage: backlog-epics-sync.sh [--dry-run] [--keep K1,K2]  full sync (weekly, with the prune sweep)
#        backlog-epics-sync.sh --ensure <EPIC-KEY>    create-time: index this epic if missing.
#   --ensure exit 0 = the epic is listed (index or elsewhere) -> keep the child OFF the page;
#            exit 3 = epic not indexable (not Open/To Do, or the harness epic) -> list the child.
# Same guards as backlog-add-ticket.sh: ADF only, mediaSingle count unchanged, key delta
# equals added - removed, verified from a fresh read.
set -euo pipefail
DRY=""; ENSURE=""; KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in --dry-run) DRY=1 ;; --ensure) ENSURE="${2:?--ensure needs an epic key}"; shift ;; --keep) KEEP="${2:?--keep needs keys}"; shift ;; esac
  shift
done
CONFIG="$HOME/.claude/harness-config.json"
cfg() { jq -r "$1 // empty" "$CONFIG" | tr -d '\r'; }
PID="$(cfg .atlassian.backlogPageId)"; DEF_PID="$(cfg .atlassian.deferredBacklogPageId)"
EMAIL="$(cfg .user.email)"; HOST="$(cfg .atlassian.cloudId)"
HARNESS="$(cfg .atlassian.harnessEpicKey)"; EPF="$(cfg .atlassian.epicLinkFieldId)"; EPF="${EPF:-<epicLinkFieldId>}"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
BASE="https://${HOST}/wiki/api/v2/pages/${PID}"; AUTH="${EMAIL}:${ATLASSIAN_API_TOKEN}"
HERE="$(dirname "${BASH_SOURCE[0]}")"
SEARCH="$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh"
ADD="$HERE/backlog-add-ticket.sh"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
# node resolves a POSIX path against the drive root and ENOENTs -- convert every one.
to_win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
cnt() { { grep -o "$1" "$2" || true; } | wc -l | tr -d ' '; }
section_for() { case "$1" in Bug) echo Bugs ;; Story|"New Feature"|Improvement) echo Features ;; *) echo "Tech Debt" ;; esac; }

curl -sS -u "$AUTH" "$BASE?body-format=atlas_doc_format" > "$TMPD/pre.json"
VER="$(jq -r '.version.number' "$TMPD/pre.json" | tr -d '\r')"; TITLE="$(jq -r '.title' "$TMPD/pre.json" | tr -d '\r')"
jq -r '.body.atlas_doc_format.value' "$TMPD/pre.json" > "$TMPD/body.json"
CUR="$(SECTION=Epics node "$(to_win "$HERE/backlog-section.js")" "$(to_win "$TMPD/body.json")" 2>/dev/null | cut -f2 | tr -d '\r' | paste -sd, || true)"

if [ -n "$ENSURE" ]; then
  [ "$ENSURE" = "$HARNESS" ] && { echo "harness epic is never indexed"; exit 3; }
  case ",$CUR," in *",$ENSURE,"*) echo "epic index already lists $ENSURE"; exit 0 ;; esac
  st="$(bash "$SEARCH" "key = $ENSURE" "status" 1 | cut -f2 | tr -d '\r')"
  case "$st" in Open|"To Do") ;; *) echo "epic $ENSURE is '${st:-unreadable}' -- not indexed, list the child by itself"; exit 3 ;; esac
  DESIRED="${CUR:+$CUR,}$ENSURE"
else
  bash "$SEARCH" 'project = PROJ AND issuetype = Epic AND status in (Open, "To Do") ORDER BY created DESC' "summary" 200 \
    | cut -f1 | tr -d '\r' | { grep -v -x "${HARNESS:-none}" || true; } > "$TMPD/epics"
  [ -s "$TMPD/epics" ] || { echo "no open epics returned -- refusing to empty the index" >&2; exit 1; }
  EL="$(paste -sd, "$TMPD/epics")"
  kids() { bash "$SEARCH" "project = PROJ AND issuetype != Epic AND $1 AND (parent in ($EL) OR \"Epic Link\" in ($EL))" "parent,$EPF" 1000 \
    | cut -f2- | { grep -o 'PROJ-[0-9]\+' || true; } | sort -u; }
  kids 'status in (Open, "To Do")' > "$TMPD/open"
  kids '(created >= -365d OR statusCategoryChangedDate >= -365d)' > "$TMPD/recent"
  grep -x -F -f "$TMPD/recent" "$TMPD/open" > "$TMPD/active" || true
  # the page's existing order first, then new epics newest-first
  { printf '%s\n' "$CUR" | tr ',' '\n'; cat "$TMPD/epics"; } | awk 'NF && !s[$0]++' \
    | { grep -x -F -f "$TMPD/active" || true; } > "$TMPD/want"
  DESIRED="$(paste -sd, "$TMPD/want")"
fi

RES="$(DESIRED="$DESIRED" HOSTNAME_CFG="$HOST" node "$(to_win "$HERE/backlog-epics.js")" "$(to_win "$TMPD/body.json")" "$(to_win "$TMPD/new.json")" | tr -d '\r')"
echo "$RES"
if [ -n "$ENSURE" ] && printf '%s' "$RES" | jq -e --arg k "$ENSURE" '.elsewhere | index($k)' >/dev/null; then
  echo "$ENSURE is already listed elsewhere on the page"; exit 0
fi
ADDED="$(printf '%s' "$RES" | jq '.added | length')"; REMOVED="$(printf '%s' "$RES" | jq '.removed | length')"
CREATED="$(printf '%s' "$RES" | jq -r '.created')"
if [ "$CREATED" = "true" ] || [ "$ADDED$REMOVED" != "00" ]; then
  M0="$(cnt mediaSingle "$TMPD/body.json")"; K0="$(cnt 'browse/PROJ-[0-9]\{4,6\}' "$TMPD/body.json")"
  M1="$(cnt mediaSingle "$TMPD/new.json")"; K1="$(cnt 'browse/PROJ-[0-9]\{4,6\}' "$TMPD/new.json")"
  [ "$M1" = "$M0" ] || { echo "ABORT: mediaSingle $M0 -> $M1"; exit 1; }
  [ "$K1" = "$((K0 + ADDED - REMOVED))" ] || { echo "ABORT: keys $K0 -> $K1 (want +$ADDED -$REMOVED)"; exit 1; }
  if [ -n "$DRY" ]; then echo "dry run -- index not written"; else
    # `node -e` argv has no script-path element: user args start at index 1.
    node -e '
const fs=require("fs"); const [,id,title,version,bodyPath,outPath]=process.argv;
const body=fs.readFileSync(bodyPath,"utf8"); JSON.parse(body);
fs.writeFileSync(outPath,JSON.stringify({id,status:"current",title,version:{number:Number(version),message:"Sync Epics index"},body:{representation:"atlas_doc_format",value:body}}));
' "$PID" "$TITLE" "$((VER + 1))" "$(to_win "$TMPD/new.json")" "$(to_win "$TMPD/put.json")"
    code="$(curl -sS -o "$TMPD/resp.json" -w '%{http_code}' -X PUT -u "$AUTH" -H "Content-Type: application/json" --data-binary "@$TMPD/put.json" "$BASE")"
    [ "$code" = "200" ] || { echo "WRITE FAILED (HTTP $code)"; head -c 400 "$TMPD/resp.json"; exit 1; }
    curl -sS -u "$AUTH" "$BASE?body-format=atlas_doc_format" | jq -r '.body.atlas_doc_format.value' > "$TMPD/post.json"
    [ "$(cnt mediaSingle "$TMPD/post.json")" = "$M0" ] || { echo "VERIFY FAILED: mediaSingle changed -- see ama-confluence-api restore recipe"; exit 1; }
    [ "$(cnt 'browse/PROJ-[0-9]\{4,6\}' "$TMPD/post.json")" = "$K1" ] || { echo "VERIFY FAILED: key count"; exit 1; }
    echo "epic index written; version $VER -> $((VER + 1))"
  fi
else
  echo "epic index already in step"
fi
if [ -n "$ENSURE" ]; then
  [ "$ADDED" != "0" ] && echo "EPIC PLACEMENT OWED -- $ENSURE was appended LAST in the Epics index, which is pickup order. Re-slot it by priority: backlog-section.sh Epics, then backlog-move-first.sh $ENSURE --before <EPIC>"
  exit 0
fi

# Duplicates: children of indexed epics listed by themselves, unless Show-stopper / Critical.
if [ -s "$TMPD/want" ]; then
  WL="$(paste -sd, "$TMPD/want")"
  bash "$SEARCH" "project = PROJ AND issuetype != Epic AND priority not in (\"Show-stopper\", Critical) AND (parent in ($WL) OR \"Epic Link\" in ($WL))" "priority" 1000 \
    | cut -f1 | tr -d '\r' | sort -u > "$TMPD/lowkids"
  bash "$HERE/backlog-candidates.sh" --all 2>/dev/null | cut -f2 | tr -d '\r' > "$TMPD/onpage0" || true
  printf '%s\n' "$KEEP" | tr ',' '\n' | awk NF > "$TMPD/keep"
  { grep -x -F -f "$TMPD/lowkids" "$TMPD/onpage0" || true; } | { grep -v -x -F -f "$TMPD/keep" || true; } | awk '!s[$0]++' > "$TMPD/dups"
  echo "indexed-epic children listed by themselves without high priority: $(wc -l < "$TMPD/dups" | tr -d ' ')"
  if [ -s "$TMPD/dups" ]; then
    if [ -n "$DRY" ]; then paste -sd' ' "$TMPD/dups"; echo "dry run -- duplicates not removed"
    else bash "$HERE/backlog-prune-resolved.sh" $(paste -sd' ' "$TMPD/dups") || { echo "duplicate removal FAILED" >&2; exit 1; }
    fi
  fi
  # The other half (2026-10-27): a child raised to Show-stopper/Critical AFTER create is never
  # listed -- create-time is the only adder. Report, don't auto-add: the slot is a judgement.
  bash "$SEARCH" "project = PROJ AND issuetype != Epic AND status in (Open, \"To Do\") AND priority in (\"Show-stopper\", Critical) AND (parent in ($WL) OR \"Epic Link\" in ($WL))" "priority" 1000 \
    | cut -f1 | tr -d '\r' | sort -u | { grep -v -x -F -f "$TMPD/onpage0" || true; } > "$TMPD/hinot"
  if [ -s "$TMPD/hinot" ]; then
    echo "HIGH-PRIORITY EPIC CHILDREN NOT LISTED ($(wc -l < "$TMPD/hinot" | tr -d ' ')): $(paste -sd' ' "$TMPD/hinot")"
    echo "  list each near its section top (backlog-add-ticket.sh KEY <section> before:<KEY>), or lower its Jira priority if it isn't urgent"
  fi
fi

# Dormant epics not listed anywhere: their unresolved, unstarted children go on the Deferred page.
bash "$HERE/backlog-candidates.sh" --all 2>/dev/null | cut -f2 | tr -d '\r' > "$TMPD/onpage" || true
[ -s "$TMPD/onpage" ] || { echo "could not read the backlog pages -- dormant-epic children skipped" >&2; exit 1; }
# "listed elsewhere" = on a page outside the index (the old index is still on the page in a dry run)
printf '%s
' "$CUR" | tr ',' '
' | awk NF > "$TMPD/cur"
{ grep -v -x -F -f "$TMPD/cur" "$TMPD/onpage" || true; } > "$TMPD/listed"
{ grep -v -x -F -f "$TMPD/want" "$TMPD/epics" || true; } | { grep -v -x -F -f "$TMPD/listed" || true; } > "$TMPD/dormant"
[ -s "$TMPD/dormant" ] || { echo "no dormant epics"; exit 0; }
DL="$(paste -sd, "$TMPD/dormant")"
bash "$SEARCH" "project = PROJ AND issuetype != Epic AND status in (Open, \"To Do\", Blocked, \"on hold\") AND (parent in ($DL) OR \"Epic Link\" in ($DL)) ORDER BY created DESC" "issuetype" 1000 \
  | tr -d '\r' | { grep -v -F -f <(sed 's/$/\t/' "$TMPD/onpage") || true; } > "$TMPD/list"
echo "dormant epics: $(wc -l < "$TMPD/dormant" | tr -d ' '); their children to list on Deferred: $(wc -l < "$TMPD/list" | tr -d ' ')"
[ -s "$TMPD/list" ] || exit 0
[ -n "$DRY" ] && { cut -f1 "$TMPD/list" | paste -sd' '; echo "dry run -- children not listed"; exit 0; }
[ -n "$DEF_PID" ] || { echo "atlassian.deferredBacklogPageId not set -- children not listed" >&2; exit 1; }
fail=0
while IFS=$'\t' read -r key itype; do
  BACKLOG_PAGE_ID="$DEF_PID" bash "$ADD" "$key" "$(section_for "$itype")" last >/dev/null || { echo "FAILED to list $key" >&2; fail=1; }
done < "$TMPD/list"
echo "listed $(wc -l < "$TMPD/list" | tr -d ' ') dormant-epic children on the Deferred page"
exit "$fail"
