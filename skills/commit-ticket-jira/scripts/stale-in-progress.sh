#!/usr/bin/env bash
# Lists the user's own tickets parked in a Claude-owned status (In Progress / Review / QA)
# with no Jira activity for N days (default 3) -- work finished or deferred whose ticket
# was never moved on. Read-only; the agent decides per ticket.
#
# Why: 2026-10-27, ten RDS make-private tickets sat In Progress 6-7 days after the work
# was done and verified. Infra-only work has no deploy event to move a ticket, the Prod
# close was deferred to a "US-hours check", and a usage-limit cut-off dropped the deferral.
# Nothing on any code path could see it; only a scheduled read of Jira can.
#
# The nudge lands in WHICHEVER session the user types in first, which may know nothing of
# these tickets (user decision 2026-10-27): tickets a live session has claimed are listed
# apart and left to it; the rest are acted on only where live state proves the outcome,
# otherwise listed for the user. Waiting work goes to Blocked / On Hold (not in the JQL),
# so it stops coming back -- a comment would only buy 3 days.
#
# Scheduled by hooks/stale-in-progress-check.sh (daily nudge from on-prompt.sh). Running
# this stamps today's date so the nudge stays quiet until tomorrow.
#
# Epics are excluded (status follows their children). A ticket checked and found correctly
# parked -- QA awaiting the release cut, another session's slow work -- is --ack'ed and hidden
# 14 days: re-listing it daily is noise, and On Hold would drop a QA ticket from release tagging.
#
# Usage: stale-in-progress.sh [days]
#        stale-in-progress.sh --ack KEY...
set -uo pipefail
. "$HOME/.claude/hooks/lib-claude-paths.sh"
ACKF="$(hstate tickets stale-in-progress-acks)"   # KEY<TAB>hidden-until (YYYY-MM-DD)
if [ "${1:-}" = "--ack" ]; then
  shift; [ $# -gt 0 ] || { echo "usage: stale-in-progress.sh --ack KEY..." >&2; exit 2; }
  until="$(date -d '+14 days' +%F)"
  printf "%s\t$until\n" "$@" >> "$ACKF"; echo "hidden until $until: $*"; exit 0
fi
days="${1:-3}"
case "$days" in ''|*[!0-9]*) echo "usage: stale-in-progress.sh [days]" >&2; exit 2 ;; esac

J="$HOME/.claude/skills/ama-jira-api/scripts"
cfg="$HOME/.claude/harness-config.json"
skip="<harnessEpicKey>"
r="$(jq -r '.atlassian.regressionsTicketKey // empty' < "$cfg" 2>/dev/null | tr -d '\r')"
[ -n "$r" ] && skip="$skip,$r"
proj="$(jq -r '.atlassian.jiraProjectKey // "PROJ"' < "$cfg" 2>/dev/null | tr -d '\r')"

# Live-session claims -- same store as backlog-candidates.sh, same liveness rule as
# lib-session-liveness.sh (transcript written in the last 600s), but ONE find for all sids:
# session_is_live per claim file cost ~1s each (63 files -> 69s). Fails open.
# The .ticket claim holds ONE key per session, and many sessions never write it; a session
# working ten tickets protected at most one. So also scan each live transcript (whole file,
# read once) for two signals only (tested 2026-10-27 against 5 live sessions):
#  - a key the USER typed: a line with a promptId and string content. Tool output is an
#    array (a printed ticket list, this sweep's own, claims nothing); compaction summaries
#    and injected CLAUDE.md/AGENTS.md text are excluded -- through those every session
#    "claimed" the same keys the harness docs happen to name.
#  - a Jira write or session-ticket call with the key as its argument. The script name
#    alone is not enough: skill text quoting the scripts claimed keys too.
# The session running the sweep is excluded. ONE grep over all live transcripts + ONE awk:
# a per-session pipeline (~7 forks each) took 43s wall on ~1s CPU -- process start is slow
# on this box during scan spells (AGENTS.md "Hook fork budget").
declare -A CLAIMED_BY=() LIVE=()
STATED="$HOME/.claude/.session-chatfiles"
self="${CLAUDE_CODE_SESSION_ID:-}"
live_files=()
while IFS= read -r t; do
  s="${t##*/}"; s="${s%.jsonl}"
  [ "$s" = "$self" ] && continue
  LIVE["$s"]=1; live_files+=("$t")
done < <(find "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}" -name '*.jsonl' -not -path '*/subagents/*' -newermt "-600 seconds" 2>/dev/null)
if [ "${#live_files[@]}" -gt 0 ]; then
  while read -r s ckey; do
    [ -n "$ckey" ] || continue
    case ",${CLAIMED_BY[$ckey]:-}," in *",${s:0:8},"*) continue ;; esac
    CLAIMED_BY["$ckey"]="${CLAIMED_BY[$ckey]:+${CLAIMED_BY[$ckey]},}${s:0:8}"
  done < <(grep -aHE '"promptId"|jira-|set-session-ticket' "${live_files[@]}" 2>/dev/null | awk -v proj="$proj" '
    BEGIN {
      key = proj "-[0-9]+"
      noise = "isCompactSummary|\"content\":\"This session is being continued|\"type\":\"instructions\"|<system-reminder>"
      wr = "(jira-(transition-issue|add-comment|edit-issue|edit-description|append-description|create-issue|append-worklog)[.]sh|set-session-ticket[.]sh[^\\\\]{0,300})[\"\047 ]+" key
    }
    {
      i = index($0, ".jsonl:"); f = substr($0, 1, i - 1); l = substr($0, i + 7)
      n = split(f, a, "/"); s = a[n]
      if (l ~ /"promptId"/ && index(l, "\"role\":\"user\",\"content\":\"") && l !~ noise) {
        t = l; while (match(t, key)) { print s, substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH) }
      }
      t = l
      while (match(t, wr)) { m = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
        if (match(m, key "$")) print s, substr(m, RSTART, RLENGTH) }
    }')
fi
for tf in "$STATED"/*.ticket; do
  [ -f "$tf" ] || continue
  csid="${tf##*/}"; csid="${csid%.ticket}"
  [ -n "${LIVE[$csid]:-}" ] || continue
  ckey=""; IFS= read -r ckey < "$tf" 2>/dev/null || true
  ckey="${ckey%$'\r'}"
  [ -n "$ckey" ] || continue
  case ",${CLAIMED_BY[$ckey]:-}," in *",${csid:0:8},"*) continue ;; esac
  CLAIMED_BY["$ckey"]="${CLAIMED_BY[$ckey]:+${CLAIMED_BY[$ckey]},}${csid:0:8}"
done

jql="project = $proj AND assignee = currentUser() AND status in (\"In Progress\", Review, QA) AND issuetype != Epic AND updated <= -${days}d AND key not in ($skip) ORDER BY updated ASC"
out="$(bash "$J/jira-search.sh" "$jql" "status,updated,summary" 100)" || { echo "stale-in-progress: Jira search failed" >&2; exit 1; }
date +%F > "$(hstate notices .stale-in-progress-lastrun)"

if [ -z "$out" ]; then
  echo "No own tickets idle ${days}+ days in In Progress / Review / QA."
  exit 0
fi
declare -A ACKED=(); today="$(date +%F)"; nack=0
if [ -f "$ACKF" ]; then
  while IFS=$'\t' read -r ak au; do [[ "$au" < "$today" ]] || ACKED["$ak"]=1; done < "$ACKF"
fi
free=""; claimed=""
while IFS=$'\t' read -r k st up sm; do
  [ -n "$k" ] || continue
  [ -n "${ACKED[$k]:-}" ] && { nack=$((nack + 1)); continue; }
  line="$(printf '  %s\t%s\t%s\t%s' "$k" "$st" "${up:0:10}" "$sm")"
  if [ -n "${CLAIMED_BY[$k]:-}" ]; then claimed+="$line	<-- live session ${CLAIMED_BY[$k]}"$'\n'
  else free+="$line"$'\n'; fi
done <<< "$(printf '%s\n' "$out" | tr -d '\r')"

[ "$nack" -gt 0 ] && echo "($nack checked earlier and hidden by --ack until it expires.)"
[ -n "$claimed" ] && printf 'Claimed by a live session -- leave to that session, do not touch:\n%s' "$claimed"
[ -z "$free" ] && exit 0
printf 'Own tickets idle %s+ days (key, status, last update, summary):\n%s' "$days" "$free"
cat <<'EOF'
Per ticket: act ONLY where live state proves the outcome without this ticket's history
(infra verifiably done -> Done; code verifiably in Production -> transition table). Anything
else -> do not transition and do not comment: list it for the user with what you found.
Correctly parked (QA = on develop awaiting the release cut; another session's slow work) ->
stale-in-progress.sh --ack KEY... (hidden 14 days). NEVER move a QA ticket to Blocked / On
Hold: the release cut tags tickets by status QA. Other genuinely waiting work -> the user
moves it to Blocked / On Hold (drops off this list).
EOF
