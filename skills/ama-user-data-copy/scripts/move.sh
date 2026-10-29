#!/usr/bin/env bash
# move.sh -- OWNER SWITCH: hand everything one AMA user owns to another account IN PLACE. No new
# ids, no cohort regeneration (MappingId and the Redshift rows are untouched); the source ends up
# with nothing. Reversible: move-rollback.sh restores the exact pre-move rows from the snapshot.
# Usage: move.sh <qa|staging|production> <from> <from-sub> <to> <to-sub> [--dry-run] [--include-received-shares]
# Stores: UserReport.OwnedBy (+ owner strings inside Report/Query/TemplateFields), UserSavedReport
# (UserUid + folder remapped into the target's tree, customs merged), DynamicColumn.UserName,
# cohort.user, cohortreport.user -- deleted rows/docs included (the account moves whole).
# Not moved: client-loan-data reports (another company's loan data; listed), export history,
# notifications. Received shares (rows/sharedWith naming the source) only with the flag.
# Manifest: $CLAUDE_STATE_DIR/logs/user-data-copy/move-<env>-<from>-<to>.json; snapshots beside it
# in move-<env>-<from>-<to>.snap/{before-src,before-tgt,after-src,after-tgt}. Verify = udc.py
# move-compare (item by item) + verify-as-target.sh (as both users) -- run-ui-check.sh separately.
# Writes need AMA_ALLOW_PG_WRITE=1 + AMA_ALLOW_MONGO_WRITE=1 (qa/staging) or the *_PROD_* pair.
set -uo pipefail
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
ENV="${1:?usage: move.sh <env> <from> <from-sub> <to> <to-sub> [--dry-run] [--include-received-shares]}"
FROM="${2:?}"; FROM_SUB="${3:?}"; TO="${4:?}"; TO_SUB="${5:?}"; shift 5
DRY=""; SHARES=""
while [ $# -gt 0 ]; do case "$1" in --dry-run) DRY=1 ;; --include-received-shares) SHARES="--include-received-shares" ;; esac; shift; done
case "$ENV" in qa|staging|production) ;; *) echo "bad env" >&2; exit 1 ;; esac
[[ "$FROM_SUB" =~ ^[0-9a-fA-F-]{36}$ && "$TO_SUB" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "subs must be uuids" >&2; exit 1; }
[ "$FROM" != "$TO" ] || { echo "from and to are the same user" >&2; exit 1; }
PG="$HOME/.claude/skills/ama-postgres-access/scripts/pg-connect.sh"
DOCDB="$HOME/.claude/skills/ama-mongo-access/scripts/docdb-query.sh"
STATE="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}"; DIR="$STATE/logs/user-data-copy"; mkdir -p "$DIR"
BASE="move-$ENV-$FROM-$TO"; [ -n "$DRY" ] && BASE="dryrun-$BASE"
M="$DIR/$BASE.json"; SNAP="$DIR/$BASE.snap"
if [ -f "$M" ] && [ -z "$DRY" ]; then echo "move.sh: $M exists -- a move $FROM -> $TO on $ENV was started before; move-rollback.sh undoes it" >&2; exit 1; fi
[ -n "$DRY" ] && rm -rf "$M" "$SNAP"
umask 077; mkdir -p "$SNAP"
madd() { local t="$M.tmp"; jq "$@" "$M" > "$t" && mv "$t" "$M"; }
NOW() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "move.sh: $ENV  $FROM ($FROM_SUB) -> $TO ($TO_SUB) ${DRY:+[DRY RUN]} ${SHARES:+[+received shares]}" >&2
echo "##### snapshots (before)" >&2
bash "$HERE/move-snapshot.sh" "$ENV" "$FROM" "$FROM_SUB" "$SNAP/before-src" || exit 1
bash "$HERE/move-snapshot.sh" "$ENV" "$TO" "$TO_SUB" "$SNAP/before-tgt" || exit 1

echo "##### pre-checks" >&2
# a cohort still generating would be ReplaceOne'd back by the progress handler -> never move mid-flight
inflight="$(jq -c 'select(.isDeleted!=true) | select((.progress.status // 0) != 2 and (.progress.status // 0) != 3) | .name' "$SNAP/before-src/cohort.jsonl" | tr -d '\r')"
[ -z "$inflight" ] || { echo "move.sh: source cohorts still generating -- wait for them: $inflight" >&2; exit 1; }
# same-named live cohorts under one owner make GET /cohort?name= 500 (SingleOrDefault)
jq -r 'select(.isDeleted!=true) | .name | ascii_downcase' "$SNAP/before-src/cohort.jsonl" | tr -d '\r' | sort > "$SNAP/src.names"
jq -r 'select(.isDeleted!=true) | .name | ascii_downcase' "$SNAP/before-tgt/cohort.jsonl" | tr -d '\r' | sort > "$SNAP/tgt.names"
if comm -12 "$SNAP/src.names" "$SNAP/tgt.names" | grep -q .; then
  echo "move.sh: target already owns live cohorts with these names (rename one side first):" >&2; comm -12 "$SNAP/src.names" "$SNAP/tgt.names" >&2; exit 1
fi
echo "pre-checks ok: no cohort in flight, no cohort name clash" >&2

jq -n --arg e "$ENV" --arg f "$FROM" --arg fs "${FROM_SUB,,}" --arg t "$TO" --arg ts "${TO_SUB,,}" --arg now "$(NOW)" \
  '{env:$e, mode:"move", from:{username:$f,sub:$fs}, to:{username:$t,sub:$ts}, startedAt:$now, applied:{}}' > "$M"
if [ -z "$DRY" ]; then
  h="$(bash "$HERE/source-hash.sh" "$ENV" "$FROM" "$FROM_SUB" 2>/dev/null)" && madd --arg h "$h" '.sourceHash=$h'
  h="$(bash "$HERE/source-hash.sh" "$ENV" "$TO" "$TO_SUB" 2>/dev/null)" && madd --arg h "$h" '.targetHashBefore=$h'
fi

echo "##### plan" >&2
python "$HERE/udc.py" move-sql --src "$SNAP/before-src" --tgt "$SNAP/before-tgt" --manifest "$M" \
  --from-user "$FROM" --from-sub "$FROM_SUB" --to-user "$TO" --to-sub "$TO_SUB" --out "$DIR/$BASE.plan" $SHARES >&2 || exit 1
python "$HERE/udc.py" mongo-move-js "$SNAP/before-src" cohort "$FROM" "$TO" $SHARES > "$DIR/$BASE.plan.cohort.js" || exit 1
python "$HERE/udc.py" mongo-move-js "$SNAP/before-src" cohortreport "$FROM" "$TO" $SHARES > "$DIR/$BASE.plan.cohortreport.js" || exit 1
echo "plan written: $DIR/$BASE.plan.{reports,export}.sql, $DIR/$BASE.plan.{cohort,cohortreport}.js" >&2
if [ -n "$DRY" ]; then echo "move.sh: DRY RUN -- nothing applied. manifest: $M" >&2; exit 0; fi

apply_pg() { # $1 db  $2 sql  $3 key
  local out="$SNAP/apply-$3.out"
  bash "$PG" "$ENV" "$1" -f "$2" > "$out" 2>&1 || { cat "$out" >&2; echo "move.sh: $3 APPLY FAILED (transaction rolled back)" >&2; return 1; }
  grep -qiE 'ERROR|ROLLBACK' "$out" && { cat "$out" >&2; echo "move.sh: $3 APPLY FAILED" >&2; return 1; }
  madd --arg k "$3" --arg now "$(NOW)" '.applied[$k]=$now'; echo "  $3: applied" >&2
}
apply_mongo() { # $1 collection -- runs the plan JS chunk by chunk (udc.py mongo-move-js splits on //CHUNK)
  bash "$HERE/mongo-apply.sh" "$ENV" "$DIR/$BASE.plan.$1.js" "$(grep -c . "$SNAP/before-src/$1.jsonl")" "$SNAP/apply-$1.out"; local rc=$?
  madd --arg k "$1" --arg now "$(NOW)" '.applied[$k]=$now'
  [ $rc -eq 0 ] || { echo "move.sh: $1 owner update incomplete -- see $SNAP/apply-$1.out; the step is idempotent: re-run it with mongo-apply.sh, then finish with move-finish.sh (or move-rollback.sh reverses what matched)" >&2; return 1; }
  madd --arg k "$1" --argjson n "$(grep -oE 'TOTAL matched [0-9]+' "$SNAP/apply-$1.out" | grep -oE '[0-9]+$')" '.mongo[$k]=$n'
}
echo "##### apply" >&2
apply_pg reports "$DIR/$BASE.plan.reports.sql" reports || exit 1
apply_pg export  "$DIR/$BASE.plan.export.sql"  export  || exit 1
apply_mongo cohort || exit 1
apply_mongo cohortreport || exit 1
madd --arg now "$(NOW)" '.finishedAt=$now'

echo "##### snapshots (after) + compare" >&2
bash "$HERE/move-snapshot.sh" "$ENV" "$FROM" "$FROM_SUB" "$SNAP/after-src" || exit 1
bash "$HERE/move-snapshot.sh" "$ENV" "$TO" "$TO_SUB" "$SNAP/after-tgt" || exit 1
python "$HERE/udc.py" move-compare --before-src "$SNAP/before-src" --before-tgt "$SNAP/before-tgt" --after-src "$SNAP/after-src" --after-tgt "$SNAP/after-tgt" --manifest "$M"; rc=$?
echo "##### verify (as users)" >&2
bash "$HERE/verify-as-target.sh" "$M" || rc=1
madd --arg now "$(NOW)" --argjson ok "$([ $rc -eq 0 ] && echo true || echo false)" '.verifiedAt=$now | .verifyOk=$ok'
echo "move.sh: done ($([ $rc -eq 0 ] && echo ALL PASS || echo FAILURES)). manifest: $M" >&2
exit $rc
