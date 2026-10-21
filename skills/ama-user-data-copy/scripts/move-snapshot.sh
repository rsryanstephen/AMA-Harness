#!/usr/bin/env bash
# move-snapshot.sh -- READ-ONLY. Dump everything one user owns (and the shares they receive) into
# a directory, one JSON per line, so an owner switch can be compared item by item before/after
# and rolled back from the exact pre-move rows.
# Usage: move-snapshot.sh <qa|staging|production> <username> <sub> <out-dir>
# Files: reports.jsonl (UserReport rows incl. deleted), saved.tsv (UserSavedReport + report owner),
#        folder.tsv (UserFolder row), bands.jsonl (DynamicColumn incl. deleted), bandshares.tsv
#        (ShareDynamicColumn rows granted TO this sub), cohort.jsonl / cohortreport.jsonl (incl.
#        deleted), shared-cohort.jsonl / shared-cohortreport.jsonl (others' docs sharedWith user).
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"
ENV="${1:?usage: move-snapshot.sh <env> <username> <sub> <out-dir>}"; U="${2:?}"; SUB="${3:?}"; OUT="${4:?}"
PG="$HOME/.claude/skills/ama-postgres-access/scripts/pg-connect.sh"
DOCDB="$HOME/.claude/skills/ama-mongo-access/scripts/docdb-query.sh"
umask 077; mkdir -p "$OUT"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/reports.sql" <<SQL
\\set u '$U'
select row_to_json(u)::text as row from "UserReport" u where u."OwnedBy"=:'u' order by u."Id";
SQL
cat > "$TMP/saved.sql" <<SQL
\\set s '$SUB'
select s."Id", s."UserUid", s."ReportUuid", s."UserFolderId", coalesce(r."OwnedBy",'') as "OwnedBy", coalesce(r."BasedOn",'') as "BasedOn", coalesce(r."IsDeleted"::text,'') as "IsDeleted", coalesce(r."Name",'') as "Name"
from "UserSavedReport" s left join "UserReport" r on r."Id"=s."ReportUuid" where s."UserUid"=:'s'::uuid order by s."Id";
SQL
cat > "$TMP/folder.sql" <<SQL
\\set s '$SUB'
select "Id","Folders"::text as "Folders" from "UserFolder" where "UserUid"=:'s'::uuid order by "Id";
SQL
cat > "$TMP/bands.sql" <<SQL
\\set u '$U'
select row_to_json(d)::text as row from "DynamicColumn" d where d."UserName"=:'u' order by d."Id";
SQL
cat > "$TMP/bandshares.sql" <<SQL
\\set s '$SUB'
select "Id","SharedWithId","ColumnId" from "ShareDynamicColumn" where "SharedWithId"=:'s'::uuid order by "Id";
SQL
for f in reports saved folder; do
  bash "$PG" "$ENV" reports -f "$TMP/$f.sql" > "$OUT/$f.tsv" 2>"$TMP/$f.err" || { cat "$TMP/$f.err" >&2; exit 1; }
done
for f in bands bandshares; do
  bash "$PG" "$ENV" export -f "$TMP/$f.sql" > "$OUT/$f.tsv" 2>"$TMP/$f.err" || { cat "$TMP/$f.err" >&2; exit 1; }
done
# row_to_json tsv -> jsonl (drop the header line)
awk 'NR>1' "$OUT/reports.tsv" > "$OUT/reports.jsonl"; awk 'NR>1' "$OUT/bands.tsv" > "$OUT/bands.jsonl"
bash "$HERE/mongo-dump.sh" "$ENV" cohort "$U" "$OUT/cohort.jsonl" --include-deleted 2>/dev/null || exit 1
bash "$HERE/mongo-dump.sh" "$ENV" cohortreport "$U" "$OUT/cohortreport.jsonl" --include-deleted 2>/dev/null || exit 1
for col in cohort cohortreport; do
  bash "$DOCDB" "$ENV" "var c=db.getSiblingDB('cohort'); c.$col.find({sharedWith: '$U', user: {\$ne: '$U'}}).forEach(function(d){ print('DOC|'+JSON.stringify(d)); });" 2>/dev/null \
    | grep '^DOC|' | cut -d'|' -f2- > "$OUT/shared-$col.jsonl" || true
done
printf 'env=%s user=%s sub=%s at=%s\n' "$ENV" "$U" "$SUB" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT/META"
echo "snapshot $U: reports=$(grep -c . "$OUT/reports.jsonl") saved=$(( $(grep -c . "$OUT/saved.tsv") - 1 )) folder=$(( $(grep -c . "$OUT/folder.tsv") - 1 )) bands=$(grep -c . "$OUT/bands.jsonl") bandShares=$(( $(grep -c . "$OUT/bandshares.tsv") - 1 )) cohorts=$(grep -c . "$OUT/cohort.jsonl") cohortReports=$(grep -c . "$OUT/cohortreport.jsonl") sharedCohorts=$(grep -c . "$OUT/shared-cohort.jsonl") sharedCohortReports=$(grep -c . "$OUT/shared-cohortreport.jsonl")" >&2
