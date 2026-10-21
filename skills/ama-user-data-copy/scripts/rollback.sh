#!/usr/bin/env bash
# rollback.sh -- undo a copy run: remove exactly the ids the manifest recorded, nothing else.
# Usage: rollback.sh <manifest.json> [--dry-run]
# Order matters:
#   1. cohort report clones  -> Mongo deleteOne per _id (nothing derived from them)
#   2. cohort copies         -> flip user back to the temp test user, then DELETE /cohort/{id} as
#                               that user: owner-only, and its CohortDeletedEvent drops the Redshift
#                               mapping rows + CohortNameMapping row (a raw Mongo delete would orphan them)
#   3. saved reports         -> DELETE UserSavedReport + UserReport for the new ids; created folders
#                               removed from the target tree (or the whole UserFolder row if we created it)
#   4. bands                 -> DELETE DynamicColumn for the new ids (owned by the target)
# Every delete is keyed on the NEW id AND the target owner, so a wrong manifest cannot reach the source.
# Needs the same gate hatches as the copy.
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
M="${1:?usage: rollback.sh <manifest.json> [--dry-run]}"; DRY="${2:-}"
PG="$HOME/.claude/skills/ama-postgres-access/scripts/pg-connect.sh"
DOCDB="$HOME/.claude/skills/ama-mongo-access/scripts/docdb-query.sh"
ENV="$(jr .env "$M")"; TO="$(jr .to.username "$M")"; TO_SUB="$(jr .to.sub "$M")"; TEMP="$(jr .tempUser "$M")"
umask 077; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
madd() { local t="$TMP/m"; jq "$@" "$M" > "$t" && cat "$t" > "$M"; }
run() { if [ "$DRY" = "--dry-run" ]; then echo "  would: $*" >&2; else "$@"; fi; }

echo "rollback: $ENV target=$TO temp=$TEMP manifest=$M ${DRY:+[DRY RUN]}" >&2
fail=0
# Mongo/API steps below record per-item results; a Postgres step clears its manifest section only on COMMIT.

# 0. received shares granted to the target (copy-received-shares.sh) -- rows/array entries only,
#    the shared items themselves belong to other users and are never touched
if jq -e '.receivedShares' "$M" >/dev/null 2>&1; then
  echo "== 0/4 received shares" >&2
  mapfile -t RSR < <(jr '.receivedShares.reports[]?.savedRowId' "$M")
  if [ ${#RSR[@]} -gt 0 ]; then
    ids="$(printf "'%s'::uuid," "${RSR[@]}")"; ids="${ids%,}"
    printf 'BEGIN;\nDELETE FROM "UserSavedReport" WHERE "UserUid"=%s AND "Id" IN (%s);\nCOMMIT;\n' "'$TO_SUB'::uuid" "$ids" > "$TMP/rs-r.sql"
    run bash "$PG" "$ENV" reports -f "$TMP/rs-r.sql" >&2
  fi
  mapfile -t RSB < <(jr '.receivedShares.bands[]?.columnId' "$M")
  if [ ${#RSB[@]} -gt 0 ]; then
    ids="$(printf "'%s'::uuid," "${RSB[@]}")"; ids="${ids%,}"
    printf 'BEGIN;\nDELETE FROM "ShareDynamicColumn" WHERE "SharedWithId"=%s AND "ColumnId" IN (%s);\nCOMMIT;\n' "'$TO_SUB'::uuid" "$ids" > "$TMP/rs-b.sql"
    run bash "$PG" "$ENV" export -f "$TMP/rs-b.sql" >&2
  fi
  for coll in cohort cohortreport; do
    key="cohorts"; [ "$coll" = "cohortreport" ] && key="cohortReports"
    for id in $(jr ".receivedShares.$key[]?.id" "$M"); do
      b64="$(python "$HERE/udc.py" guid2bin "$id")"
      run bash "$DOCDB" "$ENV" "var c=db.getSiblingDB('cohort'); var r=c.$coll.updateOne({_id: BinData(3,'$b64')}, {\$pull: {sharedWith: '$TO'}}); print('UNSHARED '+r.modifiedCount);" 2>/dev/null | sed 's/^/  /' >&2
    done
  done
  [ "$DRY" = "--dry-run" ] || madd '.receivedShares = {reports:[], bands:[], cohorts:[], cohortReports:[]}'
fi

# 1. cohort reports
mapfile -t CRS < <(jr '.cohortReports[]?.new' "$M")
echo "== 1/4 cohort report clones: ${#CRS[@]}" >&2
for id in "${CRS[@]}"; do
  b64="$(python "$HERE/udc.py" guid2bin "$id")"
  js="var c=db.getSiblingDB('cohort'); var r=c.cohortreport.deleteOne({_id: BinData(3,'$b64'), user: '$TO'}); print('DELETED '+r.deletedCount);"
  run bash "$DOCDB" "$ENV" "$js" 2>/dev/null | sed 's/^/  /' >&2
done
[ "$DRY" = "--dry-run" ] || madd '.cohortReports = []'

# 2. cohorts
mapfile -t COH < <(jr '.cohorts[]?.new' "$M")
echo "== 2/4 cohort copies: ${#COH[@]}" >&2
if [ ${#COH[@]} -gt 0 ] && [ "$DRY" != "--dry-run" ]; then bash "$HERE/cognito-token.sh" "$ENV" "$TEMP" "$TMP/tok.json" || exit 1; fi
for id in "${COH[@]}"; do
  b64="$(python "$HERE/udc.py" guid2bin "$id")"
  js="var c=db.getSiblingDB('cohort'); var r=c.cohort.updateOne({_id: BinData(3,'$b64'), user: {\$in: ['$TO','$TEMP']}}, {\$set: {user: '$TEMP'}}); print('FLIPPED '+r.matchedCount);"
  run bash "$DOCDB" "$ENV" "$js" 2>/dev/null | sed 's/^/  /' >&2
  if [ "$DRY" = "--dry-run" ]; then echo "  would: DELETE /cohort/$id as $TEMP" >&2; else
    bash "$HERE/api.sh" "$ENV" "$TMP/tok.json" DELETE "/cohort/$id" >/dev/null 2>"$TMP/del.err" && echo "  deleted $id via API" >&2 || echo "  WARN API delete of $id: $(tail -1 "$TMP/del.err")" >&2
  fi
done
[ "$DRY" = "--dry-run" ] || madd '.cohorts = []'

# 3. reports + folders
mapfile -t REP < <(jr '.reports[]?.new' "$M")
NFOLD="$(jq '.folders|length' "$M")"
echo "== 3/4 saved report copies: ${#REP[@]} (folders to remove: $NFOLD)" >&2
if [ ${#REP[@]} -gt 0 ] || [ "$NFOLD" != "0" ] || [ "$(jr '.targetFolderCreated // false' "$M")" = "true" ]; then
  ids=""; [ ${#REP[@]} -gt 0 ] && { ids="$(printf "'%s'::uuid," "${REP[@]}")"; ids="${ids%,}"; }
  {
    echo "BEGIN;"
    if [ -n "$ids" ]; then
      echo "DELETE FROM \"UserSavedReport\" WHERE \"UserUid\"='$TO_SUB'::uuid AND \"ReportUuid\" IN ($ids);"
      echo "DELETE FROM \"UserReport\" WHERE \"OwnedBy\"='$TO' AND \"Id\" IN ($ids);"
    fi
    if [ "$(jr '.targetFolderCreated // false' "$M")" = "true" ]; then
      echo "DELETE FROM \"UserFolder\" WHERE \"UserUid\"='$TO_SUB'::uuid AND \"Id\"='$(jr .targetFolderRowId "$M")'::uuid;"
    elif [ "$(jq '.folders|length' "$M")" != "0" ]; then
      # remove only the folders we created, by id, anywhere in the tree -- read the live tree,
      # prune in Python (a regex over the JSON text left a dangling comma and rolled the whole
      # transaction back, 2026-10-07), write it back whole
      printf 'select "Folders"::text from "UserFolder" where "UserUid"=%s::uuid;\n' "'$TO_SUB'" > "$TMP/tree.sql"
      bash "$PG" "$ENV" reports -f "$TMP/tree.sql" 2>/dev/null | awk 'NR==2' > "$TMP/tree.json"
      python - "$TMP/tree.json" "$M" <<'PY' > "$TMP/tree.pruned.json"
import json, sys
tree = json.load(open(sys.argv[1], encoding='utf-8'))
drop = {f['new'].lower() for f in json.load(open(sys.argv[2], encoding='utf-8')).get('folders', [])}
def prune(folders):
    kept = []
    for f in folders or []:
        if f['Id'].lower() in drop: continue
        f['Subfolders'] = prune(f.get('Subfolders') or [])
        kept.append(f)
    return kept
print(json.dumps(prune(tree)))
PY
      [ -s "$TMP/tree.pruned.json" ] && echo "UPDATE \"UserFolder\" SET \"Folders\" = \$udc\$$(cat "$TMP/tree.pruned.json")\$udc\$::jsonb WHERE \"UserUid\"='$TO_SUB'::uuid;"
    fi
    echo "COMMIT;"
  } > "$TMP/rb.sql"
  cp "$TMP/rb.sql" "$(dirname "$M")/$(basename "$M" .json).rollback-reports.sql"
  if [ "$DRY" = "--dry-run" ]; then run bash "$PG" "$ENV" reports -f "$TMP/rb.sql"
  else
    # clear the manifest section ONLY on a committed transaction -- a ROLLBACK must leave the ids in
    # place for the next attempt (2026-10-07: a failed folder UPDATE rolled everything back while the
    # manifest was wiped, stranding 13 copies with no record of them)
    bash "$PG" "$ENV" reports -f "$TMP/rb.sql" > "$TMP/rb.out" 2>&1; cat "$TMP/rb.out" >&2
    if grep -q '^COMMIT' "$TMP/rb.out" && ! grep -qiE 'ERROR|ROLLBACK' "$TMP/rb.out"; then madd '.reports = [] | .folders = []'
    else echo "rollback: saved-report deletes NOT committed -- manifest keeps them for a retry" >&2; fail=1; fi
  fi
fi

# 4. bands
mapfile -t BND < <(jr '.bands[]?.new' "$M")
echo "== 4/4 band copies: ${#BND[@]}" >&2
if [ ${#BND[@]} -gt 0 ]; then
  ids="$(printf "'%s'::uuid," "${BND[@]}")"; ids="${ids%,}"
  printf 'BEGIN;\nDELETE FROM "DynamicColumn" WHERE "UserName"=%s AND "Id" IN (%s);\nCOMMIT;\n' "'$TO'" "$ids" > "$TMP/rbb.sql"
  if [ "$DRY" = "--dry-run" ]; then run bash "$PG" "$ENV" export -f "$TMP/rbb.sql"
  else
    bash "$PG" "$ENV" export -f "$TMP/rbb.sql" > "$TMP/rbb.out" 2>&1; cat "$TMP/rbb.out" >&2
    if grep -q '^COMMIT' "$TMP/rbb.out" && ! grep -qiE 'ERROR|ROLLBACK' "$TMP/rbb.out"; then madd '.bands = []'
    else echo "rollback: band deletes NOT committed -- manifest keeps them for a retry" >&2; fail=1; fi
  fi
fi
if [ "$DRY" != "--dry-run" ] && [ "${fail:-0}" = 0 ]; then madd --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.rolledBackAt = $now'; fi
[ "${fail:-0}" = 0 ] && echo "rollback: done" >&2 || { echo "rollback: INCOMPLETE -- re-run after fixing the error above" >&2; exit 1; }
