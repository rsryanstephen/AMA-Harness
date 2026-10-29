#!/usr/bin/env bash
# inventory.sh -- READ-ONLY. Everything one AMA user owns, across every store, before a copy.
# Usage: inventory.sh <qa|staging|production> <username> <sub> [out-dir]
#   username = Cognito username exactly as the access-token `username` claim spells it
#   sub      = Cognito sub (uuid)
# Writes raw per-store output under out-dir (default
# $CLAUDE_STATE_DIR/logs/user-data-copy/inventory-<env>-<username>/) and prints a summary.
# Only SELECTs (pg-connect.sh) and find()s (docdb-query.sh). Nothing here writes.
#
# Stores + owner keys (see ../SKILL.md): reports Postgres UserReport.OwnedBy=username,
# UserSavedReport/UserFolder.UserUid=sub; export Postgres DynamicColumn.UserName=username,
# ShareDynamicColumn.SharedWithId=sub; Mongo db `cohort` collections cohort/cohortreport
# field user=username. Mongo field names are camelCase on disk (isDeleted, cohorts, ...).
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }

ENV="${1:?usage: inventory.sh <qa|staging|production> <username> <sub> [out-dir]}"
USERNAME="${2:?usage: inventory.sh <env> <username> <sub> [out-dir]}"
SUB="${3:?usage: inventory.sh <env> <username> <sub> [out-dir]}"
PG="$HOME/.claude/skills/ama-postgres-access/scripts/pg-connect.sh"
DOCDB="$HOME/.claude/skills/ama-mongo-access/scripts/docdb-query.sh"
STATE="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}"
OUT="${4:-$STATE/logs/user-data-copy/inventory-$ENV-$USERNAME}"
mkdir -p "$OUT"

case "$ENV" in qa|staging|production) ;; *) echo "bad env: $ENV" >&2; exit 1 ;; esac
[[ "$USERNAME" =~ ^[A-Za-z0-9._@+-]+$ ]] || { echo "username has unexpected characters" >&2; exit 1; }
[[ "$SUB" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "sub is not a uuid" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------- reports DB ----------
cat > "$TMP/reports.sql" <<SQL
\\set u '$USERNAME'
\\set s '$SUB'
\\echo == UserReport columns
select string_agg(column_name||':'||data_type, ', ' order by ordinal_position) as cols
from information_schema.columns where table_name='UserReport';
\\echo == owned reports
select u."Id", u."Name", u."BasedOn", u."ReportType", u."IsShared", u."SharedOrgUuid",
  u."MonthlyDownloadsActivated", u."AutoUpdateFields", u."IsDeleted", u."LastUpdated",
  u."Report"->>'Id' as report_inner_id,
  u."Report"->>'Author' as report_author,
  u."Query"->>'Author' as query_author,
  coalesce(u."Report"->>'CohortIds','') as cohort_ids,
  coalesce(u."Query"->>'CohortIds','') as query_cohort_ids,
  coalesce(u."Query"->>'ReportId','') as query_report_id,
  coalesce(u."Query"->>'BandFields','') as band_fields,
  (select count(*) from regexp_matches(u."Report"::text || coalesce(u."Query"::text,'') || coalesce(u."TemplateFields"::text,''), 'dc__', 'g')) as dc_refs,
  (select count(*) from "UserSavedReport" s where s."ReportUuid"=u."Id" and s."UserUid"<>:'s'::uuid) as shared_with_n,
  (select count(*) from "UserSavedReport" s where s."ReportUuid"=u."Id" and s."UserUid"=:'s'::uuid) as own_rows,
  (select string_agg(s."UserFolderId"::text, ',') from "UserSavedReport" s where s."ReportUuid"=u."Id" and s."UserUid"=:'s'::uuid) as own_folder_ids
from "UserReport" u where u."OwnedBy"=:'u' order by u."IsDeleted", u."Name";
\\echo == Report jsonb top-level keys (first owned report)
select (select string_agg(k, ',') from jsonb_object_keys(u."Report") k) as report_keys,
       (select string_agg(k, ',') from jsonb_object_keys(coalesce(u."Query",'{}'::jsonb)) k) as query_keys
from "UserReport" u where u."OwnedBy"=:'u' limit 1;
\\echo == folder tree
select "Id", "Folders"::text from "UserFolder" where "UserUid"=:'s'::uuid;
\\echo == saved rows for other owners reports (shared WITH user, not copied)
select s."ReportUuid", r."Name", r."OwnedBy", r."IsDeleted"
from "UserSavedReport" s join "UserReport" r on r."Id"=s."ReportUuid"
where s."UserUid"=:'s'::uuid and r."OwnedBy"<>:'u';
\\echo == templates used (non-deleted)
select "BasedOn", count(*) from "UserReport" where "OwnedBy"=:'u' and not "IsDeleted" group by 1 order by 1;
\\echo == ReportAccess (template org access, all rows)
select "TemplateId","OrgId","Enabled" from "ReportAccess" order by 2,1;
SQL

# ---------- export DB ----------
cat > "$TMP/export.sql" <<SQL
\\set u '$USERNAME'
\\set s '$SUB'
\\echo == DynamicColumn columns
select string_agg(column_name||':'||data_type, ', ' order by ordinal_position) as cols
from information_schema.columns where table_name='DynamicColumn';
\\echo == owned bands
select "Id","Name","FieldType","IsDeleted","CreatedOn","LastUpdated" from "DynamicColumn" where "UserName"=:'u' order by "IsDeleted","Name";
\\echo == bands shared WITH user (not copied)
select sdc."ColumnId", d."Name", d."UserName" from "ShareDynamicColumn" sdc join "DynamicColumn" d on d."Id"=sdc."ColumnId" where sdc."SharedWithId"=:'s'::uuid;
\\echo == user's bands shared BY user
select sdc."ColumnId", d."Name", sdc."SharedWithId" from "ShareDynamicColumn" sdc join "DynamicColumn" d on d."Id"=sdc."ColumnId" where d."UserName"=:'u';
SQL

# ---------- manage DB ----------
cat > "$TMP/manage.sql" <<SQL
\\set s '$SUB'
\\echo == organization_users row
select * from organization_users where user_guid=:'s'::uuid;
\\echo == organizations
select * from organization order by 1;
SQL

# ---------- Mongo ----------
# Works in both mongosh 7 (qa/staging) and the mongo:4.0 legacy shell (production).
# g() tolerates either camelCase (on disk) or PascalCase (C# names) spellings.
cat > "$TMP/mongo.js" <<JS
var u = "$USERNAME";
var c = db.getSiblingDB("cohort");
function g(d, k) { var p = k.charAt(0).toUpperCase() + k.slice(1); return d[k] !== undefined ? d[k] : d[p]; }
function sr(d, k) { var s = g(d, "searchRequest"); return s ? g(s, k) : null; }
print("== cohorts owned");
c.cohort.find({\$or: [{user: u}, {User: u}]}).forEach(function(d) {
  print(JSON.stringify({id: d._id, name: g(d,"name"), type: g(d,"type"), dataAvailable: g(d,"dataAvailable"),
    failed: g(d,"dataMappingFailed"), deleted: g(d,"isDeleted"), mappingId: g(d,"mappingId"),
    progress: g(d,"progress"), sharedWith: g(d,"sharedWith"), criteriaN: (g(d,"criteria")||[]).length,
    source: g(d,"source"), created: g(d,"created"), lastUpdated: g(d,"lastUpdated")}));
});
print("== cohorts shared WITH user (not copied)");
c.cohort.find({\$or: [{sharedWith: u}, {SharedWith: u}]}).forEach(function(d) {
  print(JSON.stringify({id: d._id, name: g(d,"name"), owner: g(d,"user"), deleted: g(d,"isDeleted")}));
});
print("== cohort reports owned");
c.cohortreport.find({\$or: [{user: u}, {User: u}]}).forEach(function(d) {
  var fields = g(d,"fields") || [];
  var dc = fields.filter(function(f) { return /dc__/.test(f); }).length;
  print(JSON.stringify({id: d._id, name: g(d,"name"), template: g(d,"template"), cohorts: g(d,"cohorts"),
    deleted: g(d,"isDeleted"), dataAvailable: g(d,"dataAvailable"), sharedWith: g(d,"sharedWith"),
    fieldsN: fields.length, dcRefs: dc, reportId: sr(d,"reportId"), srCohortIds: sr(d,"cohortIds"),
    bandFields: sr(d,"bandFields"), created: g(d,"created"), lastViewed: g(d,"lastViewed"), viewCount: g(d,"viewCount")}));
});
print("== cohort reports shared WITH user (not copied)");
c.cohortreport.find({\$or: [{sharedWith: u}, {SharedWith: u}]}).forEach(function(d) {
  print(JSON.stringify({id: d._id, name: g(d,"name"), owner: g(d,"user"), deleted: g(d,"isDeleted")}));
});
print("== one raw cohort doc (shape)");
var one = c.cohort.findOne({\$or: [{user: u}, {User: u}]}); if (one) { printjson(one); }
print("== one raw cohortreport doc (shape)");
var two = c.cohortreport.findOne({\$or: [{user: u}, {User: u}]}); if (two) { printjson(two); }
JS

echo "# inventory $ENV $USERNAME ($SUB) -> $OUT" >&2
bash "$PG" "$ENV" reports -f "$TMP/reports.sql" > "$OUT/reports.tsv" 2> "$OUT/reports.err"; echo "reports rc=$?" >&2
bash "$PG" "$ENV" export  -f "$TMP/export.sql"  > "$OUT/export.tsv"  2> "$OUT/export.err";  echo "export rc=$?" >&2
bash "$PG" "$ENV" manage  -f "$TMP/manage.sql"  > "$OUT/manage.tsv"  2> "$OUT/manage.err";  echo "manage rc=$?" >&2
bash "$DOCDB" "$ENV" "$(cat "$TMP/mongo.js")" > "$OUT/mongo.txt" 2> "$OUT/mongo.err"; echo "mongo rc=$?" >&2

# ---------- summary ----------
section() { awk -v s="== $1" 'index($0,s)==1{f=1;next} /^== /{f=0} f' "$2"; }
count_rows() { section "$1" "$2" | awk 'NR>1 && NF' | wc -l | tr -d ' '; }   # skip header
echo
echo "=== SUMMARY $ENV $USERNAME"
echo "reports owned (incl deleted):      $(count_rows 'owned reports' "$OUT/reports.tsv")"
echo "  of which deleted:                $(section 'owned reports' "$OUT/reports.tsv" | awk -F'\t' 'NR>1 && $9=="t"' | wc -l | tr -d ' ')"
echo "  monthly downloads on:            $(section 'owned reports' "$OUT/reports.tsv" | awk -F'\t' 'NR>1 && $7=="t"' | wc -l | tr -d ' ')"
echo "  with cohort ids:                 $(section 'owned reports' "$OUT/reports.tsv" | awk -F'\t' 'NR>1 && $14!="" && $14!="[]"' | wc -l | tr -d ' ')"
echo "  with dc__ (band) refs:           $(section 'owned reports' "$OUT/reports.tsv" | awk -F'\t' 'NR>1 && $18>0' | wc -l | tr -d ' ')"
echo "  shared with others:              $(section 'owned reports' "$OUT/reports.tsv" | awk -F'\t' 'NR>1 && $19>0' | wc -l | tr -d ' ')"
echo "reports shared WITH user:          $(count_rows "saved rows for other owners reports" "$OUT/reports.tsv")"
echo "templates used:"; section 'templates used' "$OUT/reports.tsv" | awk 'NR>1' | sed 's/^/    /'
echo "folder rows:                       $(count_rows 'folder tree' "$OUT/reports.tsv")"
echo "bands owned:                       $(count_rows 'owned bands' "$OUT/export.tsv")"
echo "bands shared WITH user:            $(count_rows 'bands shared WITH user' "$OUT/export.tsv")"
echo "cohorts owned:                     $(section 'cohorts owned' "$OUT/mongo.txt" | grep -c '^{')"
echo "  deleted:                         $(section 'cohorts owned' "$OUT/mongo.txt" | grep -c '"deleted":true')"
echo "  dataAvailable false:             $(section 'cohorts owned' "$OUT/mongo.txt" | grep -c '"dataAvailable":false')"
echo "cohorts shared WITH user:          $(section 'cohorts shared WITH user' "$OUT/mongo.txt" | grep -c '^{')"
echo "cohort reports owned:              $(section 'cohort reports owned' "$OUT/mongo.txt" | grep -c '^{')"
echo "  deleted:                         $(section 'cohort reports owned' "$OUT/mongo.txt" | grep -c '"deleted":true')"
echo "cohort reports shared WITH user:   $(section 'cohort reports shared WITH user' "$OUT/mongo.txt" | grep -c '^{')"
echo "org:"; section 'organization_users row' "$OUT/manage.tsv" | sed 's/^/    /'
echo "raw files: $OUT"
