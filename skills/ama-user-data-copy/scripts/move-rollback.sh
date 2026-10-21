#!/usr/bin/env bash
# move-rollback.sh -- undo an owner switch made by move.sh: restore every moved row/doc to the
# source from the before-src snapshot (exact pre-move JSON for UserReport, saved rows back to their
# old folders, target folder tree restored/deleted, bands and band shares back, Mongo user/sharedWith
# back), then prove both accounts equal their pre-move snapshots.
# Usage: move-rollback.sh <manifest.json> [--dry-run]
set -uo pipefail
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
M="${1:?usage: move-rollback.sh <manifest.json> [--dry-run]}"; DRY="${2:-}"
[ "$(jr .mode "$M")" = move ] || { echo "not a move manifest" >&2; exit 1; }
ENV="$(jr .env "$M")"; FROM="$(jr .from.username "$M")"; FROM_SUB="$(jr .from.sub "$M")"; TO="$(jr .to.username "$M")"; TO_SUB="$(jr .to.sub "$M")"
PG="$HOME/.claude/skills/ama-postgres-access/scripts/pg-connect.sh"
DOCDB="$HOME/.claude/skills/ama-mongo-access/scripts/docdb-query.sh"
DIR="$(dirname "$M")"; BASE="$(basename "$M" .json)"; SNAP="$DIR/$BASE.snap"
[ -d "$SNAP/before-src" ] || { echo "no before-src snapshot at $SNAP" >&2; exit 1; }
SHARES=""; [ "$(jr .includeReceivedShares "$M")" = true ] && SHARES="--include-received-shares"
umask 077
madd() { local t="$M.tmp"; jq "$@" "$M" > "$t" && mv "$t" "$M"; }
NOW() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fail=0

python "$HERE/udc.py" move-rollback-sql --before-src "$SNAP/before-src" --manifest "$M" --out "$DIR/$BASE.rollback" >&2 || exit 1
python "$HERE/udc.py" mongo-move-js "$SNAP/before-src" cohort "$FROM" "$TO" $SHARES --reverse > "$DIR/$BASE.rollback.cohort.js" || exit 1
python "$HERE/udc.py" mongo-move-js "$SNAP/before-src" cohortreport "$FROM" "$TO" $SHARES --reverse > "$DIR/$BASE.rollback.cohortreport.js" || exit 1
if [ "$DRY" = "--dry-run" ]; then echo "move-rollback: DRY RUN -- plans in $DIR/$BASE.rollback.*" >&2; exit 0; fi

for col in cohortreport cohort; do
  [ "$(jr --arg k "$col" '.applied[$k] // empty' "$M")" ] || { echo "  $col: never applied, skipping" >&2; continue; }
  # chunked, idempotent (matches _id AND current owner); a silent chunk leaves the store marked applied
  if bash "$HERE/mongo-apply.sh" "$ENV" "$DIR/$BASE.rollback.$col.js" "$(grep -c . "$SNAP/before-src/$col.jsonl")" "$SNAP/rollback-$col.out"; then
    madd --arg k "$col" 'del(.applied[$k])'
  else echo "  $col: NOT cleared -- see $SNAP/rollback-$col.out (re-run move-rollback.sh; the reverse is idempotent)" >&2; fail=1; fi
done
for key in export reports; do
  [ "$(jr --arg k "$key" '.applied[$k] // empty' "$M")" ] || { echo "  $key: never applied, skipping" >&2; continue; }
  out="$SNAP/rollback-$key.out"
  if bash "$PG" "$ENV" "$key" -f "$DIR/$BASE.rollback.$key.sql" > "$out" 2>&1 && ! grep -qiE 'ERROR|ROLLBACK' "$out"; then
    madd --arg k "$key" 'del(.applied[$k])'; echo "  $key: restored" >&2
  else cat "$out" >&2; echo "  $key: ROLLBACK FAILED (transaction rolled back, nothing changed)" >&2; fail=1; fi
done

echo "##### snapshots (after rollback) + compare" >&2
bash "$HERE/move-snapshot.sh" "$ENV" "$FROM" "$FROM_SUB" "$SNAP/after-rollback-src" || fail=1
bash "$HERE/move-snapshot.sh" "$ENV" "$TO" "$TO_SUB" "$SNAP/after-rollback-tgt" || fail=1
cmp_ok=0; python "$HERE/udc.py" move-compare --before-src "$SNAP/before-src" --before-tgt "$SNAP/before-tgt" --after-src "$SNAP/after-rollback-src" --after-tgt "$SNAP/after-rollback-tgt" --manifest "$M" --rolled-back || { cmp_ok=1; fail=1; }
# whole-account fingerprints include TemplateFields, which the app re-saves on every view: a differing
# fingerprint with a PASSING item compare means only "something was opened in between" -> INFO
fp() { # $1 label $2 wanted $3 user $4 sub
  [ -n "$2" ] || return 0
  local have; have="$(bash "$HERE/source-hash.sh" "$ENV" "$3" "$4" 2>/dev/null)"
  if [ "$have" = "$2" ]; then echo "PASS  $1 fingerprint back to $2"
  elif [ $cmp_ok -eq 0 ]; then echo "INFO  $1 fingerprint differs ($have) but every item compares identical -- views in between re-saved TemplateFields"
  else echo "FAIL  $1 fingerprint $have != $2"; fail=1; fi
}
fp source "$(jr '.sourceHash // empty' "$M")" "$FROM" "$FROM_SUB"
fp target "$(jr '.targetHashBefore // empty' "$M")" "$TO" "$TO_SUB"
madd --arg now "$(NOW)" --argjson ok "$([ $fail -eq 0 ] && echo true || echo false)" '.rolledBackAt=$now | .rollbackOk=$ok'
echo "move-rollback: $([ $fail -eq 0 ] && echo ALL PASS || echo FAILURES)" >&2
exit $fail
