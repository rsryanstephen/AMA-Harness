#!/usr/bin/env bash
# The deterministic half of standup Step 3: which sessions did real work in the window,
# and what did they leave behind. Usage: standup-collect-sessions.sh <windowStartUTC>
#   windowStartUTC: ISO-8601, e.g. 2026-09-15T06:00:00Z
# Emits one JSON object per qualifying session:
#   {sid, topic, cwd, ticket, transcript, chatfile, away_summaries:[{ts,cwd,content}], unsummarizable}
# The judgement -- what the work WAS -- stays with the reader; this only collects.
#
# Six fixed steps (sid from sessions.txt -> transcript -> mtime prefilter -> confirm an
# in-window user/assistant entry -> away_summary entries -> .ticket file) were re-derived
# by hand every run, with three "confirmed live" corrections carried as prose the agent had
# to remember: mtime alone lies (metadata touches), a recap's timestamp is GENERATION time
# not work time, and compaction-recap blocks restate old work. The first two are code here;
# the third is the chat-log reader's (chat-log-reads), flagged in `chatfile`.
set -uo pipefail
WS="${1:?usage: standup-collect-sessions.sh <windowStartUTC>}"
ws_epoch="$(date -u -d "$WS" +%s 2>/dev/null)" || { echo "bad window start: $WS" >&2; exit 1; }
SESS="$HOME/.claude/sessions.txt"
REG="$HOME/.claude/.session-chatfiles"
[ -f "$SESS" ] || { echo "no $SESS" >&2; exit 1; }

# ONE find for every in-window transcript (mtime prefilter included), not one find per sid:
# the per-sid form walked all of projects/ ~hundreds of times and took 5 min (2026-10-23).
MAP="$(mktemp)"; trap 'rm -f "$MAP"' EXIT
find "$HOME/.claude/projects" -name '*.jsonl' -not -path '*/subagents/*' -newermt "@$ws_epoch" 2>/dev/null > "$MAP"

# Intersect sessions.txt's sids (its order) with the in-window transcripts in ONE awk pass, so
# the loop below only runs for sessions that qualify. A grep+head subshell per sid (272 of them)
# still cost ~140s of process spawns under Defender load (<YYYY-MM-DD: DM every run through this date, failures only after; blank = failures only>).
grep -oP -- 'claude -r \K\S+' "$SESS" | tr -d '\r' | awk '!seen[$0]++' | awk -F/ 'NR==FNR{n=$NF; sub(/\.jsonl$/,"",n); m[n]=$0; next} ($0 in m){print $0 "\t" m[$0]}' "$MAP" - | while IFS=$'\t' read -r sid tr; do
  [ -n "$sid" ] && [ -n "$tr" ] || continue
  # Confirm REAL in-window work: at least one user/assistant entry timestamped in-window.
  inwin="$(jq -r --arg w "$WS" 'select((.type=="user" or .type=="assistant") and (.timestamp // "") >= $w) | .timestamp' "$tr" 2>/dev/null | head -1)"
  [ -n "$inwin" ] || continue
  # Line shape: `<topic> cd <dir> && claude -r <sid>` -- the topic is everything before ` cd `.
  topic="$(grep -F -- "claude -r $sid" "$SESS" | head -1 | sed -E 's/ cd .*$//; s/^[[:space:]#-]*//' | cut -c1-80)"
  ticket="$(cat "$REG/$sid.ticket" 2>/dev/null | tr -d '\r\n')"
  chatfile="$(cat "$REG/$sid" 2>/dev/null | tr -d '\r\n')"
  cwd="$(jq -r 'select(.cwd != null) | .cwd' "$tr" 2>/dev/null | tail -1)"
  aways="$(jq -c --arg w "$WS" '[select(.type=="system" and .subtype=="away_summary" and (.timestamp // "") >= $w)
      | {ts: .timestamp, cwd: .cwd, content: ((.content // "") | sub(" \\(disable recaps in /config\\)$"; ""))}]' "$tr" 2>/dev/null \
      | jq -sc 'add // []')"
  unsum="false"
  [ "$(printf '%s' "$aways" | jq 'length')" = "0" ] && [ -z "$chatfile" ] && unsum="true"
  jq -nc --arg sid "$sid" --arg topic "$topic" --arg cwd "$cwd" --arg ticket "$ticket" \
         --arg tr "$tr" --arg cf "$chatfile" --argjson aways "$aways" --argjson u "$unsum" \
    '{sid:$sid, topic:$topic, cwd:$cwd, ticket:$ticket, transcript:$tr, chatfile:$cf, away_summaries:$aways, unsummarizable:$u}'
done
