#!/usr/bin/env bash
# run.sh -- copy one AMA user's reports, cohorts, cohort reports and custom bands to another user.
# Usage: run.sh <qa|staging|production> <from-username> <from-sub> <to-username> <to-sub> [--dry-run] [--resume] [--batch N]
# Order: bands -> cohorts (API as the temp test user, then re-own) -> cohort reports -> saved
# reports -> verify. Each step records what it created in ONE manifest,
#   $CLAUDE_STATE_DIR/logs/user-data-copy/copy-<env>-<from>-<to>.json
# and skips what the manifest already has, so a failed run is re-run with --resume. A manifest
# that already exists without --resume/--dry-run refuses to start (idempotency guard).
# Temp user = .users.<env>.tier3500 in ~/.claude/.ama-ui-credentials.json (its token performs
# the cohort POSTs). Writes need the gate hatches in Claude Code's own environment:
# AMA_ALLOW_PG_WRITE=1 + AMA_ALLOW_MONGO_WRITE=1 (qa/staging) or the *_PROD_* pair (production).
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
ENV="${1:?usage: run.sh <env> <from-username> <from-sub> <to-username> <to-sub> [--dry-run] [--resume] [--batch N]}"
FROM="${2:?}"; FROM_SUB="${3:?}"; TO="${4:?}"; TO_SUB="${5:?}"; shift 5
DRY=""; RESUME=""; BATCH=5; TEMP_OVERRIDE=""; SHARES=""
while [ $# -gt 0 ]; do case "$1" in --dry-run) DRY="--dry-run" ;; --resume) RESUME=1 ;; --batch) BATCH="$2"; shift ;; --temp-user) TEMP_OVERRIDE="$2"; shift ;; --include-received-shares) SHARES=1 ;; esac; shift; done
case "$ENV" in qa|staging|production) ;; *) echo "bad env" >&2; exit 1 ;; esac
[[ "$FROM_SUB" =~ ^[0-9a-fA-F-]{36}$ && "$TO_SUB" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "subs must be uuids" >&2; exit 1; }
[ "$FROM" != "$TO" ] || { echo "from and to are the same user" >&2; exit 1; }

STATE="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}"
DIR="$STATE/logs/user-data-copy"; mkdir -p "$DIR"
M="$DIR/copy-$ENV-$FROM-$TO.json"
# Temp user: performs the cohort POSTs, then hands each copy to the target. Default is the
# tier3500 test user; a rehearsal whose SOURCE is that user passes --temp-user <other test user>
# (the tier1800 one works: Roles.DynamicCohorts = "Tier3500,Admin,UserManagement" and every
# harness test user carries UserManagement).
TEMP="${TEMP_OVERRIDE:-$(jr --arg e "$ENV" '.users[$e].tier3500' "$HOME/.claude/.ama-ui-credentials.json")}"
[ -n "$TEMP" ] && [ "$TEMP" != "null" ] || { echo "no tier3500 test user for $ENV in credentials file" >&2; exit 1; }
[ "$TEMP" != "$TO" ] && [ "$TEMP" != "$FROM" ] || { echo "temp user $TEMP cannot be the source or the target -- pass --temp-user <another test user>" >&2; exit 1; }

if [ -f "$M" ] && [ -z "$RESUME" ] && [ -z "$DRY" ]; then
  echo "run.sh: $M already exists -- a copy $FROM -> $TO on $ENV was started before. Use --resume to continue it, or rollback.sh to undo it." >&2; exit 1
fi
# this box's jq is 1.5 (no now/todate) -- stamp from bash
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -n "$DRY" ]; then M="$DIR/dryrun-$ENV-$FROM-$TO.json"; rm -f "$M"; fi
if [ ! -f "$M" ]; then
  jq -n --arg e "$ENV" --arg f "$FROM" --arg fs "${FROM_SUB,,}" --arg t "$TO" --arg ts "${TO_SUB,,}" --arg tmp "$TEMP" --arg now "$NOW" \
    '{env:$e, from:{username:$f,sub:$fs}, to:{username:$t,sub:$ts}, tempUser:$tmp, startedAt:$now, bands:[], cohorts:[], cohortReports:[], reports:[], folders:[]}' > "$M"
  if [ -z "$DRY" ]; then
    echo "run.sh: fingerprinting the source before any write (source-hash.sh)" >&2
    h="$(bash "$HERE/source-hash.sh" "$ENV" "$FROM" "$FROM_SUB" 2>/dev/null)" && jq --arg h "$h" '.sourceHash=$h' "$M" > "$M.tmp" && mv "$M.tmp" "$M"
  fi
fi
echo "run.sh: $ENV  $FROM ($FROM_SUB) -> $TO ($TO_SUB)  temp=$TEMP  manifest=$M ${DRY:+[DRY RUN]}" >&2

step() { echo; echo "##### $1" >&2; shift; "$@" || { echo "run.sh: step failed -- fix and re-run with --resume" >&2; exit 1; }; }
step "1/4 bands"          bash "$HERE/copy-bands.sh" "$M" $DRY
step "2/4 cohorts"        bash "$HERE/copy-cohorts.sh" "$M" $DRY --batch "$BATCH"
step "3/4 cohort reports" bash "$HERE/copy-cohort-reports.sh" "$M" $DRY
step "4/4 saved reports"  bash "$HERE/copy-reports.sh" "$M" $DRY
# opt-in: re-grant the shares the source RECEIVED (client's decision -- see copy-received-shares.sh)
[ -n "$SHARES" ] && step "5 received shares" bash "$HERE/copy-received-shares.sh" "$M" $DRY
if [ -z "$DRY" ]; then
  jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.finishedAt = $now' "$M" > "$M.tmp" && mv "$M.tmp" "$M"
  step "verify (database)"  bash "$HERE/verify.sh" "$M"
  step "verify (as users)"  bash "$HERE/verify-as-target.sh" "$M"
fi
echo; echo "run.sh: done. manifest: $M" >&2
jq -c '{bands:(.bands|length), cohorts:(.cohorts|length), cohortsCompleted:([.cohorts[]|select(.flipped==true)]|length), cohortReports:(.cohortReports|length), skippedCohortReports:((.skippedCohortReports//[])|length), reports:(.reports|length), folders:(.folders|length)}' "$M"
