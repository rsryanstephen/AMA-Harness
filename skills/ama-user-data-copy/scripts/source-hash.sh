#!/usr/bin/env bash
# source-hash.sh -- READ-ONLY fingerprint of everything a user owns, to prove a copy left the
# source untouched. Usage: source-hash.sh <env> <username> <sub>   -> prints one sha256.
# Covers UserReport rows (minus the view counters LastOpened/OpenedTally the app bumps on open),
# UserSavedReport rows, the UserFolder tree, DynamicColumn rows, and the Mongo cohort and
# cohortreport documents (minus lastViewed/viewCount/reportViewCount/lastReportViewed/
# curveSearchCount/lastCurveSearch, which a read as any user may bump). Deleted rows included.
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
ENV="${1:?usage: source-hash.sh <env> <username> <sub>}"; U="${2:?}"; SUB="${3:?}"
PG="$HOME/.claude/skills/ama-postgres-access/scripts/pg-connect.sh"
umask 077; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/r.sql" <<SQL
\\set u '$U'
\\set s '$SUB'
select (row_to_json(u)::jsonb - 'LastOpened' - 'OpenedTally')::text from "UserReport" u where u."OwnedBy"=:'u' order by u."Id";
select "Id"||':'||"UserUid"||':'||"ReportUuid"||':'||"UserFolderId" from "UserSavedReport" where "UserUid"=:'s'::uuid order by 1;
select "Id"||':'||"Folders"::text from "UserFolder" where "UserUid"=:'s'::uuid order by 1;
SQL
cat > "$TMP/e.sql" <<SQL
\\set u '$U'
select row_to_json(d)::text from "DynamicColumn" d where d."UserName"=:'u' order by d."Id";
SQL
bash "$PG" "$ENV" reports -f "$TMP/r.sql" > "$TMP/r.out" 2>/dev/null
bash "$PG" "$ENV" export  -f "$TMP/e.sql" > "$TMP/e.out" 2>/dev/null
bash "$HERE/mongo-dump.sh" "$ENV" cohort "$U" "$TMP/c.jsonl" --include-deleted 2>/dev/null
bash "$HERE/mongo-dump.sh" "$ENV" cohortreport "$U" "$TMP/cr.jsonl" --include-deleted 2>/dev/null
jq -c 'del(.lastViewed,.viewCount,.reportViewCount,.lastReportViewed,.curveSearchCount,.lastCurveSearch)' "$TMP/c.jsonl" "$TMP/cr.jsonl" 2>/dev/null | sort > "$TMP/m.out"
echo "reports=$(( $(grep -c . "$TMP/r.out") )) bands=$(( $(grep -c . "$TMP/e.out") )) mongo=$(wc -l < "$TMP/m.out" | tr -d ' ')" >&2
cat "$TMP/r.out" "$TMP/e.out" "$TMP/m.out" | sha256sum | cut -d' ' -f1
