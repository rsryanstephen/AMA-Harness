#!/usr/bin/env bash
# "Pick up the next feedback task" without two sessions taking the same one (user rule
# 2026-10-21). Lists the feedback epic's NOT-STARTED tickets (Open / To Do -- anything past
# that was picked up or is done), newest feedback first, and marks those another LIVE
# session holds. --claim <sid> atomically takes the first free one and prints its key.
#
#   feedback-next.sh                 -> list, first free row marked NEXT
#   feedback-next.sh --claim <sid>   -> claim it: prints "CLAIMED <KEY>" (exit 0), "AUDIT <ref>
#                                       <msgid> <received>" (exit 0, an unchecked mail -- skill
#                                       "Pick up"), or "NONE" (exit 3)
#   feedback-next.sh --release <KEY> -> drop a claim (work abandoned)
#
# Claims: two sources, either one excludes a ticket --
#   1. harness-state/feedback/claims/<KEY> (mkdir = atomic; holds the sid). This is what stops
#      two sessions told "pick up the next feedback task" in the same minute racing: the
#      set-session-ticket file below is written later, after the pick.
#   2. a live session's .session-chatfiles/<sid>.ticket naming the key (same store
#      backlog-candidates.sh reads) -- covers a ticket picked up by hand.
# A claim whose session is no longer live (lib-session-liveness.sh) is ignored and reclaimable.
# NONE -> no ticketed feedback left; mail that arrived after today's 08:00 run is not ticketed
# yet: run the monitor with FEEDBACK_NOTICES_FORCE=1, then call this again (skill "Pick up").
# Seams (tests): FEEDBACK_NEXT_ROWS=<file of key\tsummary\tstatus\tcreated rows> replaces Jira;
# FEEDBACK_NEXT_NOW=<epoch> fixes "now" for the age cutoff; CLAUDE_STATE_DIR moves the ledger.
set -uo pipefail
. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
. "$HOME/.claude/hooks/lib-session-liveness.sh" 2>/dev/null || session_is_live() { return 0; }

MODE=list; ARG=""
case "${1:-}" in
  --claim) MODE=claim; ARG="${2:?--claim <sid>}" ;;
  --release) MODE=release; ARG="${2:?--release <KEY>}" ;;
  "") ;;
  *) echo "usage: feedback-next.sh [--claim <sid>|--release <KEY>]" >&2; exit 2 ;;
esac
CLAIMS="$(dirname "$(hstate feedback claims/.keep)")"
if [ "$MODE" = release ]; then rm -rf "${CLAIMS:?}/$ARG"; echo "released $ARG"; exit 0; fi

EPIC="$(hr_config_required '.feedbackNotices.epicKey')" || exit 1
if [ -n "${FEEDBACK_NEXT_ROWS:-}" ]; then rows="$(cat "$FEEDBACK_NEXT_ROWS")"; else
rows="$(bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh" \
  "project = PROJ AND \"Epic Link\" = $EPIC AND status in (Open, \"To Do\") AND assignee = currentUser() ORDER BY created DESC" \
  "summary,status,created" 50)" || { echo "Jira search failed" >&2; exit 4; }
fi
rows="$(printf '%s\n' "$rows" | tr -d '\r')"

# UNCHECKED mail comes first (user rule 2026-10-21: nothing slips through). A ledger row still
# `pre-existing` was never checked for a reply or a ticket -- 17 of the 28 seeded at install had
# neither, and Jira alone never shows them. Rows older than .unansweredMaxAgeDays (365) are
# ignored. Claimed as REF-<ref>; the claimer checks, records the outcome (`set`), and its own
# row drops out of this list.
MAXAGE="$(hr_config '.feedbackNotices.unansweredMaxAgeDays' 365)"
NOW="${FEEDBACK_NEXT_NOW:-$(date +%s)}"
cutoff="$(date -u -d "@$(( NOW - MAXAGE * 86400 ))" +%F)"
audits="$(bash "$(dirname "$0")/feedback-notices-record.sh" list 2>/dev/null | tr -d '\r' \
  | awk -F'\t' -v c="$cutoff" '$4=="pre-existing" && $2>=c {print "REF-" $3 "\t" $2 "\t" $1}' | sort -t$'\t' -k2,2r)"

# Liveness costs a transcript lookup per sid, so collect sids per CANDIDATE key first and
# test only those (a pass over all 68 ticket files took minutes).
declare -A CAND=() SIDS=() HELD=()
while IFS=$'\t' read -r key _; do [ -n "$key" ] && CAND["$key"]=1; done <<< "$audits"
while IFS=$'\t' read -r key _; do [ -n "$key" ] && CAND["$key"]=1; done <<< "$rows"
for d in "$CLAIMS"/*/; do
  [ -d "$d" ] || continue
  k="$(basename "$d")"; [ -n "${CAND[$k]:-}" ] || continue
  s=""; IFS= read -r s < "$d/sid" 2>/dev/null || true; [ -n "$s" ] && SIDS["$k"]="${SIDS[$k]:-} $s"
done
for tf in "$HOME/.claude/.session-chatfiles"/*.ticket; do
  [ -f "$tf" ] || continue
  k=""; IFS= read -r k < "$tf" 2>/dev/null || true
  [ -n "$k" ] && [ -n "${CAND[$k]:-}" ] || continue
  s="${tf##*/}"; SIDS["$k"]="${SIDS[$k]:-} ${s%.ticket}"
done
for k in "${!SIDS[@]}"; do
  for s in ${SIDS[$k]}; do session_is_live "$s" && { HELD["$k"]="${s:0:8}"; break; }; done
done

next=""
# take <key>: atomic claim; 0 = ours. mkdir fails if another session got here first (between
# the scan and now); its claim holds unless its owner is dead.
take() {
  if ! mkdir "$CLAIMS/$1" 2>/dev/null; then
    s=""; IFS= read -r s < "$CLAIMS/$1/sid" 2>/dev/null || true
    if [ -n "$s" ] && [ "$s" != "$ARG" ] && session_is_live "$s"; then return 1; fi
  fi
  printf '%s\n' "$ARG" > "$CLAIMS/$1/sid"
}
while IFS=$'\t' read -r key received msgid; do
  [ -n "$key" ] || continue
  if [ -n "${HELD[$key]:-}" ]; then
    [ "$MODE" = list ] && printf '%s\tunchecked\t%s\tmsg %s\t<-- CLAIMED by live session %s\n' "$key" "$received" "$msgid" "${HELD[$key]}"
    continue
  fi
  if [ "$MODE" = claim ]; then
    take "$key" || continue
    echo "AUDIT ${key#REF-}	$msgid	$received"; exit 0
  fi
  mark=""; [ -z "$next" ] && { next="$key"; mark="	<-- NEXT"; }
  printf '%s\tunchecked\t%s\tmsg %s: answered or ticketed?%s\n' "$key" "$received" "$msgid" "$mark"
done <<< "$audits"
while IFS=$'\t' read -r key summary status created; do
  [ -n "$key" ] || continue
  if [ -n "${HELD[$key]:-}" ]; then
    [ "$MODE" = list ] && printf '%s\t%s\t%s\t%s\t<-- CLAIMED by live session %s\n' "$key" "$status" "${created:0:10}" "$summary" "${HELD[$key]}"
    continue
  fi
  if [ "$MODE" = claim ]; then
    take "$key" || continue
    echo "CLAIMED $key	$summary"; exit 0
  fi
  mark=""; [ -z "$next" ] && { next="$key"; mark="	<-- NEXT"; }
  printf '%s\t%s\t%s\t%s%s\n' "$key" "$status" "${created:0:10}" "$summary" "$mark"
done <<< "$rows"
[ "$MODE" = claim ] && { echo NONE; exit 3; }
[ -n "$next" ] || echo "NONE free -- see header: force a monitor run for unticketed mail, then re-run"
exit 0
