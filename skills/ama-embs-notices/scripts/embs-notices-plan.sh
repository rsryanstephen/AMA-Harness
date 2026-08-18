#!/usr/bin/env bash
# Plans an eMBS Data Notice triage run. Emits the search window, the configured senders
# and subject prefix, and the already-triaged Gmail message ids. Claude (the skill) does
# the actual reading and judging via the Gmail MCP -- Gmail is MCP-only, no bash can read
# it, so this script only plans, exactly like embs-plan-reminders.sh does for the calendar.
#
# Window carries deliberate overlap: since = min(lastrun - overlapDays, today - lookbackDays)
# on a first run. Re-reads cost nothing because dedupe is on message id, and the overlap
# protects a run that died half way.
#
# Usage: embs-notices-plan.sh
# Output: one JSON object on stdout.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"

# Decides WHOSE mailbox and WHAT content gets read -- a silent default here is the bug,
# not a convenience (same reasoning as hr_config_required's own comment).
PREFIX="$(hr_config_required '.embs.noticeSubjectPrefix')" || exit 1
SENDERS_JSON="$(jq -c '.embs.noticeSenders // empty' < "$HR_CONFIG_FILE" 2>/dev/null | sed 's/\r$//')"
if [ -z "$SENDERS_JSON" ] || [ "$SENDERS_JSON" = "[]" ]; then
  printf '.embs.noticeSenders not configured -- run /harness-setup\n' >&2
  exit 1
fi

LOOKBACK="$(hr_config '.embs.noticeLookbackDays' 120)"
OVERLAP="$(hr_config '.embs.noticeOverlapDays' 3)"
MIN_TIER="$(hr_config '.embs.noticeSlackMinTier' 2)"
TARGET="$(hr_config '.embs.noticeReportTarget' '')"
# Emitted because both SKILL.md and AMA-SURFACE-MAP.md tell the caller to name this owner
# on every ETL-side finding -- without it here, a run has to go grep the config itself.
ETL_OWNER="$(hr_config '.ama.etlAssigneeName' '')"

SEEN="$HOME/.claude/.embs-notices-seen"
LASTRUN="$HOME/.claude/.embs-notices-lastrun"
touch "$SEEN"

# Gmail's after: takes YYYY/MM/DD. Compute both candidate floors, take the earlier.
floor_lookback="$(date -d "$LOOKBACK days ago" +%Y/%m/%d 2>/dev/null)" || floor_lookback=""
if [ -z "$floor_lookback" ]; then
  printf 'embs-notices-plan.sh: date arithmetic failed (need GNU date)\n' >&2
  exit 1
fi

since="$floor_lookback"
if [ -s "$LASTRUN" ]; then
  last="$(tr -d ' \r\n' < "$LASTRUN")"
  cand="$(date -d "$last -$OVERLAP days" +%Y/%m/%d 2>/dev/null || true)"
  # Later of (lastrun-overlap) and the lookback floor, so a long-idle run still bounded.
  if [ -n "$cand" ] && [ "$cand" \> "$floor_lookback" ]; then since="$cand"; fi
fi

# field 1 of the seen file is the Gmail message id.
# NB: `jq -R .` (raw-input, unslurped) silently emits nothing on this box's jq
# (jq-1.5rc1 under Git-Bash) -- exits 0, produces zero stdout. Slurping raw
# input in a single jq call (-Rs) and splitting ourselves avoids that path.
seen_ids="$(cut -f1 "$SEEN" | sed '/^$/d' | jq -Rsc 'split("\n") | map(select(length>0))' 2>/dev/null)"
[ -n "$seen_ids" ] || seen_ids='[]'

# Rows whose ticket column is `pending` (verdict blocked on an answer when recorded).
# Emitted every run so they get re-checked and settled, instead of relying on anyone
# remembering -- see embs-notices-record.sh's settle subcommand.
pending_ids="$(awk -F'\t' '$4=="pending"{print $1}' "$SEEN" | jq -Rsc 'split("\n") | map(select(length>0))' 2>/dev/null)"
[ -n "$pending_ids" ] || pending_ids='[]'

jq -nc \
  --arg since "$since" \
  --arg prefix "$PREFIX" \
  --arg target "$TARGET" \
  --arg etlOwner "$ETL_OWNER" \
  --argjson senders "$SENDERS_JSON" \
  --argjson seenIds "$seen_ids" \
  --argjson pendingIds "$pending_ids" \
  --argjson minTier "$MIN_TIER" \
  '{since:$since, subjectPrefix:$prefix, senders:$senders, seenIds:$seenIds,
    reportTarget:$target, slackMinTier:$minTier, etlOwner:$etlOwner,
    seenCount:($seenIds|length),
    pendingIds:$pendingIds, pendingCount:($pendingIds|length)}' \
  | sed 's/\r$//'
