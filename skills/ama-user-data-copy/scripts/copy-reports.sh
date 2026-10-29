#!/usr/bin/env bash
# copy-reports.sh -- step 4: clone the source user's live saved reports (reports DB) in ONE
# transaction: UserReport rows (new Id, OwnedBy = target, IsShared false, SharedOrgUuid null,
# access-record columns null, MonthlyDownloadsActivated false, every known old id rewritten in
# Report/Query/TemplateFields -- bands, cohorts, the report's own Id/ReportId -- and owner
# strings OwnedBy/Author swapped), UserSavedReport rows under the target's sub in the mapped
# folder, and the target's UserFolder tree patched to carry the source's custom folders
# (created when missing, matched case-insensitively, standard Home/Shared folders mapped by
# name, customs appended after index 1). Excludes IsDeleted rows and client-loan-data reports.
# Usage: copy-reports.sh <manifest.json> [--dry-run]
# udc.py reports-sql builds the SQL and updates the manifest (.reports[], .folders[]).
# Needs AMA_ALLOW_PG_WRITE=1 (AMA_ALLOW_PROD_PG_WRITE=1 for production).
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
M="${1:?usage: copy-reports.sh <manifest.json> [--dry-run]}"; DRY="${2:-}"
PG="$HOME/.claude/skills/ama-postgres-access/scripts/pg-connect.sh"
ENV="$(jr .env "$M")"; FROM="$(jr .from.username "$M")"; FROM_SUB="$(jr .from.sub "$M")"
TO="$(jr .to.username "$M")"; TO_SUB="$(jr .to.sub "$M")"
umask 077; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
OUTDIR="$(dirname "$M")"; BASE="$(basename "$M" .json)"

cat > "$TMP/cols.sql" <<'SQL'
select string_agg(column_name||':'||data_type, ',' order by ordinal_position) from information_schema.columns where table_name='UserReport';
SQL
cat > "$TMP/rows.sql" <<SQL
\\set u '$FROM'
select row_to_json(u)::text as row from "UserReport" u where u."OwnedBy"=:'u' order by u."Name";
SQL
cat > "$TMP/saved.sql" <<SQL
\\set s '$FROM_SUB'
select "Id","UserUid","ReportUuid","UserFolderId" from "UserSavedReport" where "UserUid"=:'s'::uuid;
SQL
cat > "$TMP/srcfolder.sql" <<SQL
\\set s '$FROM_SUB'
select "Id","Folders"::text as "Folders" from "UserFolder" where "UserUid"=:'s'::uuid;
SQL
cat > "$TMP/tgtfolder.sql" <<SQL
\\set s '$TO_SUB'
select "Id","Folders"::text as "Folders" from "UserFolder" where "UserUid"=:'s'::uuid;
SQL
for f in cols rows saved srcfolder tgtfolder; do
  bash "$PG" "$ENV" reports -f "$TMP/$f.sql" > "$TMP/$f.tsv" 2>"$TMP/$f.err" || { cat "$TMP/$f.err" >&2; exit 1; }
done
awk 'NR==2' "$TMP/cols.tsv" > "$TMP/cols.txt"
echo "copy-reports: $(( $(wc -l < "$TMP/rows.tsv") - 1 )) UserReport rows owned by $FROM (incl. deleted), $(( $(wc -l < "$TMP/saved.tsv") - 1 )) saved rows, target folder rows: $(( $(wc -l < "$TMP/tgtfolder.tsv") - 1 ))" >&2

python "$HERE/udc.py" reports-sql --rows "$TMP/rows.tsv" --columns "$TMP/cols.txt" --saved "$TMP/saved.tsv" \
  --src-folder "$TMP/srcfolder.tsv" --tgt-folder "$TMP/tgtfolder.tsv" --manifest "$M" \
  --from-user "$FROM" --from-sub "$FROM_SUB" --to-user "$TO" --to-sub "$TO_SUB" --out "$TMP/insert.sql" >&2 || exit 1
cp "$TMP/insert.sql" "$OUTDIR/$BASE.reports.sql"
python "$HERE/udc.py" check-no-source-ids "$TMP/insert.sql" "$M" "$FROM" || { echo "copy-reports: refusing to apply -- source ids survive in the generated SQL" >&2; exit 1; }

if [ "$DRY" = "--dry-run" ]; then
  echo "copy-reports: DRY RUN -- SQL written to $OUTDIR/$BASE.reports.sql, nothing applied" >&2; exit 0
fi
bash "$PG" "$ENV" reports -f "$TMP/insert.sql" >"$TMP/apply.out" 2>"$TMP/apply.err" || { cat "$TMP/apply.out" "$TMP/apply.err" >&2; echo "copy-reports: APPLY FAILED (transaction rolled back)" >&2; exit 1; }
if grep -qiE 'ERROR|ROLLBACK' "$TMP/apply.out" "$TMP/apply.err"; then cat "$TMP/apply.out" "$TMP/apply.err" >&2; echo "copy-reports: APPLY FAILED" >&2; exit 1; fi
echo "copy-reports: applied -- $(jq '.reports|length' "$M") reports now owned by $TO" >&2
