#!/usr/bin/env bash
# Read-only pickup list for the AMA Backlog pages: every key on the main page then the
# Deferred page, in DOCUMENT ORDER (= priority order), each with its status resolved LIVE.
#
# Usage:
#   backlog-candidates.sh            offerable (Open) candidates, priority order
#   backlog-candidates.sh --all      every key on both pages, with status
#   backlog-candidates.sh --limit N  cap the offerable list (default 10; 0 = no cap)
#
# Why this exists (<harnessEpicKey>, 2026-09-21): a pickup pass used to fetch the pages,
# resolve statuses once, and then keep offering candidates from that ONE snapshot for the
# rest of the session. Confirmed to misfire live: PROJ-14953 read `Open` at the start
# of a session, was Canceled in the Jira UI at 19:02 while the session ran, and was then
# offered to the user as the next candidate anyway. A snapshot ages the moment it is taken
# -- another session or the Jira UI can move anything, and no PostToolUse hook sees that.
# So the fix is structural, not a reminder: every presentation of candidates re-runs this,
# and this always asks Jira. [[ama-backlog-page]] step 5 is the rule that points here.
#
# Shape notes:
#   * Document order, NOT sort -u. backlog-prune-resolved.sh sorts because a delete set has
#     no order; here the order IS the priority and losing it loses the whole point.
#   * Dedupe keeps the FIRST occurrence, so a key on both pages ranks at its main-page spot.
#   * The `Previous requests for new features` sub-list is excised -- it is a nested list
#     INSIDE the Features list, not a trailing section, so the whole enclosing listItem goes
#     and everything after it stays. Cutting from its heading to end-of-page once dropped 92
#     of 95 keys.
#   * Status chunking at 100 keys is not cosmetic: jira-search.sh silently caps a response
#     at 100 however large a maxResults you pass, so an unchunked call over ~120 keys drops
#     the tail with no error (same reason backlog-prune-resolved.sh chunks).
#   * An Epic row is a container: its Open children print indented as rank.N (created ASC),
#     not-Open children summarised by status. The epic itself is never the pick.
#   * Only `Open` is offerable. Anything else is REPORTED, never silently dropped --
#     `Blocked`/`on hold` are parked-but-live, and a Done/Closed/Canceled entry on the page
#     is stale and wants backlog-prune-resolved.sh.
set -euo pipefail

SHOW_ALL=0
LIMIT=10
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) SHOW_ALL=1; shift ;;
    --limit) LIMIT="${2:?--limit needs a number}"; shift 2 ;;
    *) echo "usage: backlog-candidates.sh [--all] [--limit N]" >&2; exit 2 ;;
  esac
done

CONFIG="$HOME/.claude/harness-config.json"
EMAIL="$(jq -r '.user.email' "$CONFIG")"
HOST="$(jq -r '.atlassian.cloudId' "$CONFIG")"
MAIN_PID="$(jq -r '.atlassian.backlogPageId' "$CONFIG")"
DEF_PID="$(jq -r '.atlassian.deferredBacklogPageId // empty' "$CONFIG")"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
AUTH="${EMAIL}:${ATLASSIAN_API_TOKEN}"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Walk the ADF in order, emitting inlineCard urls and text; drop the listItem whose own
# first block is the "Previous requests" heading, sub-list and all.
ORDERED_JQ='
def marker: "Previous requests for new features";
def emit:
  if type == "array" then .[] | emit
  elif type == "object" then
    if .type == "listItem"
       and ([.content[0]? | .. | objects | select(.type=="text") | .text] | join("") | test(marker))
    then empty
    elif .type == "inlineCard" then (.attrs.url // empty)
    elif .type == "text" then (.text // empty)
    else (.content? // empty) | emit
    end
  else empty end;
emit'

: > "$TMPD/ordered"
for_page() {  # <page-id> <label>
  curl -sS -u "$AUTH" "https://${HOST}/wiki/api/v2/pages/$1?body-format=atlas_doc_format" > "$TMPD/page-$1.json"
  jq -r '.body.atlas_doc_format.value' "$TMPD/page-$1.json" \
    | jq -r "$ORDERED_JQ" \
    | { grep -o 'PROJ-[0-9]\{4,6\}' || true; } \
    | sed "s|\$|\t$2|" >> "$TMPD/ordered"
}
for_page "$MAIN_PID" main
[ -n "$DEF_PID" ] && for_page "$DEF_PID" deferred

# First occurrence wins, order preserved.
awk -F'\t' '!seen[$1]++' "$TMPD/ordered" > "$TMPD/keys"
TOTAL="$(wc -l < "$TMPD/keys" | tr -d ' ')"
[ "$TOTAL" -gt 0 ] || { echo "no ticket keys found on the backlog pages" >&2; exit 1; }

cut -f1 "$TMPD/keys" > "$TMPD/keylist"
: > "$TMPD/status"
split -l 100 "$TMPD/keylist" "$TMPD/chunk_"
for f in "$TMPD"/chunk_*; do
  bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh" \
    "key in ($(paste -sd, "$f"))" "summary,status,created,reporter,issuetype" 100 >> "$TMPD/status"
done

RESOLVED="$(cut -f1 "$TMPD/status" | wc -l | tr -d ' ')"
if [ "$RESOLVED" != "$TOTAL" ]; then
  echo "WARNING: $TOTAL key(s) on the pages, $RESOLVED resolved by Jira -- treat the list as incomplete" >&2
fi

# rank <TAB> key <TAB> page <TAB> status <TAB> created <TAB> reporter <TAB> summary <TAB> issuetype
awk -F'\t' '
  NR==FNR { page[$1]=$2; rank[$1]=FNR; next }
  { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", rank[$1], $1, page[$1], $3, $4, $5, $2, $6 }
' "$TMPD/keys" "$TMPD/status" | sort -n > "$TMPD/rows"

if [ "$SHOW_ALL" = "1" ]; then
  cat "$TMPD/rows"
  exit 0
fi

# An Epic on the page is a CONTAINER, not a task: its workable candidates are its Open
# children. Print them indented under the epic row (rank.N, oldest first -- an epic's
# children carry no page order, so age is the only defensible tiebreak), and report the
# not-Open children by status so nothing is silently dropped. PROJ-14775 sat at rank 3
# with an empty description and 9 Open children; a pickup pass skipped it as "not a task".
epic_children() {  # <rank> <epic-key>
  local rows n=0
  rows="$(bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh" \
    "(parent = $2 OR \"Epic Link\" = $2) ORDER BY created ASC" "summary,status,created,reporter" 200)"
  [ -n "$rows" ] || { printf '  %s.-\t(epic has no children)\n' "$1"; return 0; }
  while IFS=$'\t' read -r key summary status created reporter; do
    [ "$status" = "Open" ] || continue
    n=$((n+1))
    printf '  %s.%s\t%s\tchild\t%s\t%s\t%s\t%s%s\n' "$1" "$n" "$key" "$status" "$created" "$reporter" "$summary" "$(claim_note "$key")"
  done <<< "$rows"
  local other
  other="$(printf '%s\n' "$rows" | awk -F'\t' '$3!="Open" { c[$3]++ } END { for (s in c) printf "%s %s, ", c[s], s }' | sed 's/, $//')"
  [ -n "$other" ] && printf '  %s.-\t(children not offerable: %s)\n' "$1" "$other"
  return 0
}

# A key another LIVE session is already working is NOT offerable, and Jira status cannot
# tell you that: a session records its pick the moment it makes it, but only transitions
# the ticket to In Progress once it has something to show. <harnessEpicKey>, 2026-09-22:
# two sessions both picked PROJ-15318 from an identical Open list minutes apart, both
# investigated it to the same conclusion, and both commented on it -- the peer's "stop,
# I have this" message arrived after the work was already posted. The claim store is the
# one signal that exists at pick time, so read it here rather than relying on a message
# racing the work. Liveness-gated, so a dead session's leftover claim never parks a row
# (nothing in this harness cleans .session-chatfiles/ up). Fails open in every direction:
# no store, no lib, unreadable file -> no annotation, same list as before.
declare -A CLAIMED_BY=()
CLAIM_LIB="$HOME/.claude/hooks/lib-session-liveness.sh"
STATED="$HOME/.claude/.session-chatfiles"
if [ -f "$CLAIM_LIB" ] && [ -d "$STATED" ]; then
  # shellcheck source=/dev/null
  . "$CLAIM_LIB" 2>/dev/null || true
  if command -v session_is_live >/dev/null 2>&1; then
    for tf in "$STATED"/*.ticket; do
      [ -f "$tf" ] || continue
      csid="${tf##*/}"; csid="${csid%.ticket}"
      ckey=""
      IFS= read -r ckey < "$tf" 2>/dev/null || true
      [ -n "$ckey" ] || continue
      session_is_live "$csid" || continue
      CLAIMED_BY["$ckey"]="${CLAIMED_BY[$ckey]:+${CLAIMED_BY[$ckey]},}${csid:0:8}"
    done
  fi
fi
claim_note() {  # <key> -- prints the trailing marker, empty when unclaimed
  [ -n "${CLAIMED_BY[$1]:-}" ] && printf '\t<-- CLAIMED by live session %s' "${CLAIMED_BY[$1]}"
  return 0
}

echo "== offerable (status Open), priority order -- resolved live $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "   (an Epic row is a container -- pick from its indented rank.N children, not the epic itself)"
echo "   (a row marked CLAIMED is being worked by another live session -- skip it, do not ask)"
echo "   (record your own pick IMMEDIATELY, before any investigation:"
echo "    bash ~/.claude/hooks/set-session-ticket.sh \"\$PWD\" \"<this session's chat filename>\" <KEY>)"
awk -F'\t' -v lim="$LIMIT" '$4=="Open" { n++; if (lim==0 || n<=lim) print }' "$TMPD/rows" \
  | while IFS=$'\t' read -r rank key page status created reporter summary itype; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' "$rank" "$key" "$page" "$status" "$created" "$reporter" "$summary" "$(claim_note "$key")"
      # if/fi, not `&&`: as the loop's last statement a non-Epic final row would return 1,
      # the pipeline would exit 1 and set -e killed the script before the not-Open block.
      if [ "$itype" = "Epic" ]; then epic_children "$rank" "$key"; fi
    done

echo
echo "== on the pages but NOT offerable"
awk -F'\t' '$4!="Open" { c[$4]++ } END { for (s in c) printf "%s\t%s\n", c[s], s }' "$TMPD/rows" | sort -rn

STALE="$(awk -F'\t' '$4=="Done"||$4=="Closed"||$4=="Canceled" { printf "%s ", $2 }' "$TMPD/rows")"
if [ -n "$STALE" ]; then
  echo
  echo "STALE (finished, should not be on the backlog -- run backlog-prune-resolved.sh): $STALE"
fi

# A To Do ticket the TESTER sent back is not a plain To Do (2026-09-21: PROJ-14875 came
# back Ready to Test -> To Do with a FAILED step in <uiTesterName>'s table and was read as untested,
# even reported as QA-passed). Only the changelog knows; one JQL, fail-open to no annotation.
BOUNCED="$(bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh" \
  'status CHANGED FROM "Ready to Test" TO "To Do" AFTER -30d AND status = "To Do" AND assignee = currentUser()' \
  "summary" 50 2>/dev/null | cut -f1 | tr '\n' ' ')"
if [ -n "$BOUNCED" ]; then
  echo
  echo "BOUNCED by the tester (Ready to Test -> To Do in the last 30 days -- read the LAST comment / test table for the failure before touching it; it is NOT untested work): $BOUNCED"
fi
