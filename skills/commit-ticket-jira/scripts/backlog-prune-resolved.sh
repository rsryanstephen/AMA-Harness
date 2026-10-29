#!/usr/bin/env bash
# Remove started-or-resolved tickets from the AMA Backlog Confluence pages -- the DELETE half of
# backlog-add-ticket.sh. Runs over BOTH pages (main + Deferred), because a stale entry on
# either one costs every pickup pass a fetch and a status round-trip.
#
# Usage:
#   backlog-prune-resolved.sh                  sweep: find every key past Open/To Do
#                                              on either page and remove it
#   backlog-prune-resolved.sh KEY [KEY...]     remove exactly these keys, no Jira lookup
#   backlog-prune-resolved.sh --dry-run [...]  report what would go, write nothing
#
# Why the shape is what it is (backlog-add-ticket.sh's header has the rest of the story;
# everything there about ADF-not-html, section anatomy and whole-body-replace applies):
#   * The sweep, not a transition trigger, is the mechanism that works. Measured
#     2026-09-04: of 5 stale entries, only 1 came from a transition this harness made --
#     the rest were closed in another session or in the Jira UI, where no PostToolUse hook
#     can see them. hooks/backlog-stale-check.sh schedules this; the WRITE stays here,
#     agent-invoked, because it is a whole-body replace on a hand-curated page carrying an
#     embedded mediaSingle and the guards below need somewhere to abort to.
#   * Key matching is anchored -- `browse/(KEY)([^0-9]|$)`, the card URL, not annotation text. A bare substring match makes
#     PROJ-153 delete PROJ-1530's entry too. backlog-add-ticket.sh's plain
#     `grep -q "$KEY"` is safe for a presence test but NOT for deletion.
#   * The post-write check is a set difference, not a count. A count-only assert passes
#     when one key vanishes and another is silently swapped in, which is the failure mode
#     that actually matters on a curated page.
#   * jq here rather than node (backlog-splice.js's route): this only needs a generic
#     bottom-up walk, and it dodges the POSIX->Windows path conversion node needs.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/backlog-statuses.sh"   # BACKLOG_STARTED_STATUSES, shared with backlog-qa-sweep.sh

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; shift; fi

CONFIG="$HOME/.claude/harness-config.json"
EMAIL="$(jq -r '.user.email' "$CONFIG")"
HOST="$(jq -r '.atlassian.cloudId' "$CONFIG")"
MAIN_PID="$(jq -r '.atlassian.backlogPageId' "$CONFIG")"
DEF_PID="$(jq -r '.atlassian.deferredBacklogPageId // empty' "$CONFIG")"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
AUTH="${EMAIL}:${ATLASSIAN_API_TOKEN}"

PAGES="$MAIN_PID"
[ -n "$DEF_PID" ] && PAGES="$PAGES $DEF_PID"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# node resolves a POSIX path like /tmp/... against the drive root (C:\tmp\...) and
# ENOENTs. Every path handed to node must be converted -- same note as backlog-add-ticket.sh.
to_win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

fetch_body() {  # <page-id> <out-file>
  curl -sS -u "$AUTH" "https://${HOST}/wiki/api/v2/pages/$1?body-format=atlas_doc_format" > "$TMPD/page.json"
  jq -r '.body.atlas_doc_format.value' "$TMPD/page.json" > "$2"
}

# Card URLs only (`browse/KEY`), never bare keys: an entry's annotation may NAME another
# ticket ("split from 15520"), and a bare match deleted/counted that entry too (2026-10-12).
keys_in() { { grep -o 'browse/PROJ-[0-9]\{4,6\}' "$1" || true; } | sed 's#^browse/##' | sort -u; }

# --- work out which keys to remove -------------------------------------------------
if [ "$#" -gt 0 ]; then
  printf '%s\n' "$@" | sort -u > "$TMPD/targets"
else
  : > "$TMPD/allkeys"
  for pid in $PAGES; do
    fetch_body "$pid" "$TMPD/body-$pid.json"
    keys_in "$TMPD/body-$pid.json" >> "$TMPD/allkeys"
  done
  sort -u "$TMPD/allkeys" -o "$TMPD/allkeys"
  echo "scanning $(wc -l < "$TMPD/allkeys") ticket(s) across $(echo "$PAGES" | wc -w) page(s)..."

  # Chunked so the JQL `in (...)` clause stays a sane length.
  #
  # Anything STARTED or finished goes -- the moment a ticket is picked up it must stop being
  # offered, or two sessions start the same work. Selecting on statusCategory=Done was too
  # narrow twice over: PROJ miscategorises Test Complete / QA / Review as `new`, and
  # In Progress / Ready to Test are `indeterminate`, so none of them ever swept and all sat
  # on the page as pickup candidates. Status NAMES, not the category, for the same reason
  # jira-transition-issue.sh uses them.
  #
  # Blocked and "on hold" deliberately STAY (user call 2026-09-10): nobody is working them,
  # so they cause no double-pickup, and dropping them hides parked-but-live work -- the
  # sweep would otherwise have taken PROJ-15335, a TLS cert expiring 2026-10-12.
  # [[ama-backlog-page]] already says to NAME a not-Open entry rather than drop it.
  : > "$TMPD/targets"
  split -l 100 "$TMPD/allkeys" "$TMPD/chunk_"
  for f in "$TMPD"/chunk_*; do
    bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh" \
      "key in ($(paste -sd, "$f")) AND status IN ($BACKLOG_STARTED_STATUSES)" \
      "status" 200 | cut -f1 >> "$TMPD/targets"
  done
  sort -u "$TMPD/targets" -o "$TMPD/targets"
fi

if [ ! -s "$TMPD/targets" ]; then
  echo "nothing to prune -- no started or finished ticket is on the backlog pages"
  exit 0
fi
echo "started or resolved, due for removal: $(paste -sd' ' "$TMPD/targets")"

PAT="$(paste -sd'|' "$TMPD/targets")"

# --- per page: splice, guard, write, verify ----------------------------------------
for pid in $PAGES; do
  PRE="$TMPD/pre-$pid.json"
  curl -sS -u "$AUTH" "https://${HOST}/wiki/api/v2/pages/$pid?body-format=atlas_doc_format" > "$TMPD/meta-$pid.json"
  VER="$(jq -r '.version.number' "$TMPD/meta-$pid.json")"
  TITLE="$(jq -r '.title' "$TMPD/meta-$pid.json")"
  jq -r '.body.atlas_doc_format.value' "$TMPD/meta-$pid.json" > "$PRE"

  keys_in "$PRE" > "$TMPD/pre-keys-$pid"
  HITS="$(comm -12 "$TMPD/pre-keys-$pid" "$TMPD/targets" | wc -l | tr -d ' ')"
  if [ "$HITS" = "0" ]; then
    echo "page $pid: none of the target keys are here -- skipping"
    continue
  fi

  NEW="$TMPD/new-$pid.json"
  jq --arg pat "$PAT" '
    def w(f):
      . as $in
      | if type=="object" then reduce keys_unsorted[] as $k ({}; .[$k]=($in[$k]|w(f)))|f
        elif type=="array" then map(w(f))|f
        else f end;
    w(
      if type=="array" then
        map(select(
          (type!="object") or (.type!="listItem")
          or ((tostring|test("browse/(" + $pat + ")([^0-9]|$)"))|not)
        ))
      else . end
    )
  ' "$PRE" | jq -c . > "$NEW"

  MEDIA_BEFORE="$({ grep -o 'mediaSingle' "$PRE" || true; } | wc -l | tr -d ' ')"
  MEDIA_AFTER="$({ grep -o 'mediaSingle' "$NEW" || true; } | wc -l | tr -d ' ')"
  [ "$MEDIA_AFTER" = "$MEDIA_BEFORE" ] || { echo "ABORT page $pid: mediaSingle $MEDIA_BEFORE -> $MEDIA_AFTER"; exit 1; }

  keys_in "$NEW" > "$TMPD/new-keys-$pid"
  # Set difference, both directions: exactly the intended keys gone, nothing else gone,
  # nothing appeared.
  LOST="$(comm -23 "$TMPD/pre-keys-$pid" "$TMPD/new-keys-$pid" | sort)"
  WANT="$(comm -12 "$TMPD/pre-keys-$pid" "$TMPD/targets" | sort)"
  [ "$LOST" = "$WANT" ] || { echo "ABORT page $pid: removed [$(echo "$LOST" | paste -sd' ')] but wanted [$(echo "$WANT" | paste -sd' ')]"; exit 1; }
  [ -z "$(comm -13 "$TMPD/pre-keys-$pid" "$TMPD/new-keys-$pid")" ] || { echo "ABORT page $pid: keys appeared out of nowhere"; exit 1; }

  if [ "$DRY_RUN" = "1" ]; then
    echo "page $pid (dry run): would remove $(echo "$WANT" | paste -sd' ')"
    continue
  fi

  MSG="Remove started/resolved ticket(s) from the backlog: $(echo "$WANT" | paste -sd' ')"
  # node, not `jq --rawfile`: git-bash ships jq 1.5 here, which has no --rawfile, and the
  # body is ~95KB on the Deferred page -- far too big to pass through argv. Same envelope
  # builder as backlog-add-ticket.sh, including its argv-offset warning: under `node -e`
  # process.argv has NO script-path element, so user args start at index 1.
  node -e '
    const fs=require("fs");
    const [,id,title,version,bodyPath,outPath,msg]=process.argv;
    const body=fs.readFileSync(bodyPath,"utf8"); JSON.parse(body);
    fs.writeFileSync(outPath,JSON.stringify({id,status:"current",title,
      version:{number:Number(version),message:msg},
      body:{representation:"atlas_doc_format",value:body}}));
  ' "$pid" "$TITLE" "$((VER + 1))" "$(to_win "$NEW")" "$(to_win "$TMPD/put-$pid.json")" "$MSG"

  code="$(curl -sS -o "$TMPD/resp-$pid.json" -w '%{http_code}' -X PUT -u "$AUTH" \
    -H "Content-Type: application/json" --data-binary "@$TMPD/put-$pid.json" \
    "https://${HOST}/wiki/api/v2/pages/$pid")"
  [ "$code" = "200" ] || { echo "WRITE FAILED page $pid (HTTP $code)"; head -c 400 "$TMPD/resp-$pid.json"; exit 1; }

  # Verify from a fresh read -- a silent 200 is not proof.
  POST="$TMPD/post-$pid.json"
  fetch_body "$pid" "$POST"
  keys_in "$POST" > "$TMPD/post-keys-$pid"
  [ -z "$(comm -12 "$TMPD/post-keys-$pid" "$TMPD/targets")" ] || { echo "VERIFY FAILED page $pid: a target key is still present"; exit 1; }
  POST_MEDIA="$({ grep -o 'mediaSingle' "$POST" || true; } | wc -l | tr -d ' ')"
  [ "$POST_MEDIA" = "$MEDIA_BEFORE" ] || { echo "VERIFY FAILED page $pid: mediaSingle now $POST_MEDIA (was $MEDIA_BEFORE) -- image lost, see ama-confluence-api's restore recipe"; exit 1; }

  echo "page $pid: removed $(echo "$WANT" | paste -sd' '); version $VER -> $((VER + 1)); mediaSingle=$POST_MEDIA; ticketKeys=$(wc -l < "$TMPD/post-keys-$pid" | tr -d ' ')"
done

if [ "$DRY_RUN" = "0" ]; then
  . "$HOME/.claude/hooks/lib-claude-paths.sh"
  date +%F > "$(hstate notices .backlog-stale-lastrun)"
fi
