#!/usr/bin/env bash
# copy-received-shares.sh -- OPT-IN step 5: re-grant to the target every share the SOURCE user
# received from other users, so the target sees the same shared items.
# Usage: copy-received-shares.sh <manifest.json> [--dry-run]
# What a received share is, per store (the original item stays with its owner; nothing is cloned):
#   reports  UserSavedReport row (UserUid = source sub) on a report OwnedBy someone else, sitting in
#            the source's "Shared with me" folder  -> new row (target sub, same ReportUuid, target's
#            "Shared with me" folder), exactly what ShareReportFacade writes for a recipient
#   bands    ShareDynamicColumn (SharedWithId = source sub) on a band owned by someone else
#            -> new row (SharedWithId = target sub, same ColumnId); the source's SELF-share rows
#            (its own bands) are skipped; ORG-level band shares (ShareDynamicColumnOrganization)
#            cannot be carried -- they follow the organisation, not the person
#   Mongo    cohort / cohortreport documents owned by others with sharedWith containing the source
#            username -> $addToSet sharedWith: target (what PUT /cohort/{id}/share does)
# Deleted items are skipped. Everything granted is recorded under .receivedShares for rollback.
# DECISION, not mechanics: a share was granted by a colleague to the source as THEIR colleague.
# Extending it to an account at another company is the client's call -- run this only when
# the client contact has said yes. Needs the same gate hatches as the copy.
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
M="${1:?usage: copy-received-shares.sh <manifest.json> [--dry-run]}"; DRY="${2:-}"
PG="$HOME/.claude/skills/ama-postgres-access/scripts/pg-connect.sh"
DOCDB="$HOME/.claude/skills/ama-mongo-access/scripts/docdb-query.sh"
ENV="$(jr .env "$M")"; FROM="$(jr .from.username "$M")"; FROM_SUB="$(jr .from.sub "$M")"
TO="$(jr .to.username "$M")"; TO_SUB="$(jr .to.sub "$M")"
umask 077; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
madd() { local t="$TMP/m"; jq "$@" "$M" > "$t" && cat "$t" > "$M"; }
jq -e '.receivedShares' "$M" >/dev/null 2>&1 || madd '.receivedShares = {reports:[], bands:[], cohorts:[], cohortReports:[]}'

# ---------- reports shared WITH the source ----------
cat > "$TMP/r.sql" <<SQL
\\set f '$FROM'
\\set fs '$FROM_SUB'
\\set ts '$TO_SUB'
\\echo == received
select s."ReportUuid", r."Name", r."OwnedBy"
from "UserSavedReport" s join "UserReport" r on r."Id"=s."ReportUuid"
where s."UserUid"=:'fs'::uuid and r."OwnedBy"<>:'f' and not r."IsDeleted"
  and not exists (select 1 from "UserSavedReport" t where t."UserUid"=:'ts'::uuid and t."ReportUuid"=s."ReportUuid")
order by r."Name";
\\echo == target shared-with-me folder
select f->>'Id' from "UserFolder" u, jsonb_array_elements(u."Folders"->0->'Subfolders') f
where u."UserUid"=:'ts'::uuid and lower(f->>'Name')='shared with me';
SQL
bash "$PG" "$ENV" reports -f "$TMP/r.sql" > "$TMP/r.tsv" 2>"$TMP/r.err" || { cat "$TMP/r.err" >&2; exit 1; }
section() { awk -v s="== $1" 'index($0,s)==1{f=1;next} /^== /{f=0} f' "$2" | awk 'NR>1'; }
mapfile -t RECV < <(section received "$TMP/r.tsv")
SWM="$(section 'target shared-with-me folder' "$TMP/r.tsv" | head -1)"
echo "received-shares: ${#RECV[@]} report share(s) the source holds from others and the target lacks; target 'Shared with me' folder: ${SWM:-MISSING}" >&2
if [ ${#RECV[@]} -gt 0 ]; then
  [[ "$SWM" =~ ^[0-9a-f-]{36}$ ]] || { echo "received-shares: target has no 'Shared with me' folder -- run copy-reports.sh first (it creates the default tree)" >&2; exit 1; }
  { echo "BEGIN;"
    for line in "${RECV[@]}"; do
      rid="${line%%$'\t'*}"; rest="${line#*$'\t'}"; name="${rest%%$'\t'*}"; owner="${rest##*$'\t'}"
      nid="$(python "$HERE/udc.py" newid)"
      echo "INSERT INTO \"UserSavedReport\" (\"Id\",\"UserUid\",\"ReportUuid\",\"UserFolderId\") VALUES ('$nid'::uuid, '$TO_SUB'::uuid, '$rid'::uuid, '$SWM'::uuid);"
      madd --arg r "$rid" --arg n "$name" --arg o "$owner" --arg row "$nid" '.receivedShares.reports += [{reportId:$r, name:$n, owner:$o, savedRowId:$row}]'
      echo "  report '$name' (owner $owner) -> target Shared with me" >&2
    done
    echo "COMMIT;"; } > "$TMP/r-ins.sql"
  if [ "$DRY" = "--dry-run" ]; then echo "received-shares: DRY RUN, report share rows not applied" >&2; madd '.receivedShares.reports = []'
  else bash "$PG" "$ENV" reports -f "$TMP/r-ins.sql" >"$TMP/r-ins.out" 2>&1 || { cat "$TMP/r-ins.out" >&2; exit 1; }; grep -qi ERROR "$TMP/r-ins.out" && { cat "$TMP/r-ins.out" >&2; exit 1; }; fi
fi

# ---------- bands shared WITH the source (by other users, not org-level, not self) ----------
cat > "$TMP/e.sql" <<SQL
\\set f '$FROM'
\\set fs '$FROM_SUB'
\\set ts '$TO_SUB'
\\echo == received
select sdc."ColumnId", d."Name", d."UserName"
from "ShareDynamicColumn" sdc join "DynamicColumn" d on d."Id"=sdc."ColumnId"
where sdc."SharedWithId"=:'fs'::uuid and d."UserName"<>:'f' and not d."IsDeleted"
  and not exists (select 1 from "ShareDynamicColumn" t where t."SharedWithId"=:'ts'::uuid and t."ColumnId"=sdc."ColumnId")
order by d."Name";
SQL
bash "$PG" "$ENV" export -f "$TMP/e.sql" > "$TMP/e.tsv" 2>"$TMP/e.err" || { cat "$TMP/e.err" >&2; exit 1; }
mapfile -t BRECV < <(section received "$TMP/e.tsv")
echo "received-shares: ${#BRECV[@]} band share(s) from other users the target lacks" >&2
if [ ${#BRECV[@]} -gt 0 ]; then
  { echo "BEGIN;"
    for line in "${BRECV[@]}"; do
      cid="${line%%$'\t'*}"; rest="${line#*$'\t'}"; name="${rest%%$'\t'*}"; owner="${rest##*$'\t'}"
      echo "INSERT INTO \"ShareDynamicColumn\" (\"SharedWithId\",\"ColumnId\") VALUES ('$TO_SUB'::uuid, '$cid'::uuid);"
      madd --arg c "$cid" --arg n "$name" --arg o "$owner" '.receivedShares.bands += [{columnId:$c, name:$n, owner:$o}]'
      echo "  band '$name' (owner $owner) -> shared with target" >&2
    done
    echo "COMMIT;"; } > "$TMP/e-ins.sql"
  if [ "$DRY" = "--dry-run" ]; then echo "received-shares: DRY RUN, band share rows not applied" >&2; madd '.receivedShares.bands = []'
  else bash "$PG" "$ENV" export -f "$TMP/e-ins.sql" >"$TMP/e-ins.out" 2>&1 || { cat "$TMP/e-ins.out" >&2; exit 1; }; grep -qi ERROR "$TMP/e-ins.out" && { cat "$TMP/e-ins.out" >&2; exit 1; }; fi
fi

# ---------- Mongo: cohorts / cohort reports shared WITH the source ----------
for coll in cohort cohortreport; do
  key="cohorts"; [ "$coll" = "cohortreport" ] && key="cohortReports"
  JS="var c=db.getSiblingDB('cohort'); c.$coll.find({sharedWith: '$FROM', user: {\$ne: '$FROM'}, isDeleted: {\$ne: true}}).forEach(function(d){ var has = (d.sharedWith||[]).indexOf('$TO') >= 0; print('DOC|' + JSON.stringify({_id: d._id, name: d.name, user: d.user, alreadyShared: has})); });"
  bash "$DOCDB" "$ENV" "$JS" 2>/dev/null | grep '^DOC|' | cut -d'|' -f2- > "$TMP/$coll.jsonl"
  n="$(grep -c . "$TMP/$coll.jsonl" || true)"
  echo "received-shares: $n $coll doc(s) shared with the source by others" >&2
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    id="$(python "$HERE/udc.py" mongo-id "$(jq -c ._id <<<"$d")")"; name="$(jr .name <<<"$d")"; owner="$(jr .user <<<"$d")"
    if [ "$(jr .alreadyShared <<<"$d")" = "true" ]; then echo "  $coll '$name' already shared with target" >&2; continue; fi
    if [ "$DRY" = "--dry-run" ]; then echo "  would \$addToSet sharedWith $TO on $coll '$name' (owner $owner)" >&2; continue; fi
    b64="$(python "$HERE/udc.py" guid2bin "$id")"
    out="$(bash "$DOCDB" "$ENV" "var c=db.getSiblingDB('cohort'); var r=c.$coll.updateOne({_id: BinData(3,'$b64')}, {\$addToSet: {sharedWith: '$TO'}}); print('MOD '+r.modifiedCount);" 2>/dev/null)"
    grep -q 'MOD 1' <<<"$out" || { echo "received-shares: addToSet failed on $coll $id: $out" >&2; exit 1; }
    madd --arg k "$key" --arg i "$id" --arg n "$name" --arg o "$owner" '.receivedShares[$k] += [{id:$i, name:$n, owner:$o}]'
    echo "  $coll '$name' (owner $owner) -> shared with target" >&2
  done < "$TMP/$coll.jsonl"
done
echo "received-shares: done" >&2
