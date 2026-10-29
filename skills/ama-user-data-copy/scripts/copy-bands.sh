#!/usr/bin/env bash
# copy-bands.sh -- step 1: clone the source user's custom bands (export DB "DynamicColumn").
# Usage: copy-bands.sh <manifest.json> [--dry-run]
# Reads env/from/to from the manifest. One INSERT ... SELECT per live band with an explicit
# column list taken from information_schema (so a later migration adding a column fails loudly
# instead of silently dropping it), overriding only Id, UserName and IsDeleted. No share rows.
# Records {old,new,name} under .bands. Idempotent: bands already mapped are skipped.
# The INSERT needs AMA_ALLOW_PG_WRITE=1 (AMA_ALLOW_PROD_PG_WRITE=1 for production) in Claude
# Code's own environment -- psql-write-gate.sh reads its process env, not the command line.
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
M="${1:?usage: copy-bands.sh <manifest.json> [--dry-run]}"; DRY="${2:-}"
PG="$HOME/.claude/skills/ama-postgres-access/scripts/pg-connect.sh"
ENV="$(jr .env "$M")"; FROM="$(jr .from.username "$M")"; TO="$(jr .to.username "$M")"
umask 077; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
madd() { local t="$TMP/m"; jq "$@" "$M" > "$t" && cat "$t" > "$M"; }

cat > "$TMP/read.sql" <<SQL
\\set u '$FROM'
\\set t '$TO'
\\echo == columns
select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_name='DynamicColumn';
\\echo == source
select "Id","Name" from "DynamicColumn" where "UserName"=:'u' and not "IsDeleted" order by "Name";
\\echo == target existing names
select lower("Name") from "DynamicColumn" where "UserName"=:'t' and not "IsDeleted";
\\echo == target existing ids
select "Id" from "DynamicColumn" where "UserName"=:'t';
SQL
bash "$PG" "$ENV" export -f "$TMP/read.sql" > "$TMP/read.tsv" 2>"$TMP/read.err" || { cat "$TMP/read.err" >&2; exit 1; }
section() { awk -v s="== $1" 'index($0,s)==1{f=1;next} /^== /{f=0} f' "$TMP/read.tsv" | awk 'NR>1'; }
COLS="$(section columns)"
mapfile -t SRC < <(section source)
mapfile -t TGT_NAMES < <(section 'target existing names')
mapfile -t TGT_IDS < <(section 'target existing ids' | tr 'A-Z' 'a-z')
echo "copy-bands: ${#SRC[@]} live bands owned by $FROM on $ENV; target $TO already has ${#TGT_NAMES[@]}" >&2
[ ${#SRC[@]} -gt 0 ] || { echo "copy-bands: nothing to copy" >&2; exit 0; }

: > "$TMP/insert.sql"
echo "BEGIN;" >> "$TMP/insert.sql"
n=0; done_n=0
for line in "${SRC[@]}"; do
  old="${line%%$'\t'*}"; name="${line#*$'\t'}"
  new="$(jr --arg o "$old" '.bands[]? | select(.old==$o) | .new' "$M")"
  if [ -n "$new" ]; then
    # resumed run: a mapped band that already exists on the target is done -- never re-insert
    for t in "${TGT_IDS[@]}"; do [ "$t" = "${new,,}" ] && { done_n=$((done_n+1)); continue 2; }; done
  else
    new="$(python "$HERE/udc.py" newid)"; madd --arg o "$old" --arg n "$new" --arg nm "$name" '.bands += [{old:$o,new:$n,name:$nm}]'
  fi
  lname="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  for t in "${TGT_NAMES[@]}"; do [ "$t" = "$lname" ] && echo "copy-bands: WARN target already has a band named '$name' -- copying anyway (bands are referenced by id)" >&2; done
  sel=""
  IFS=',' read -ra CA <<< "$COLS"
  for c in "${CA[@]}"; do
    case "$c" in
      Id) sel+="'$new'::uuid, " ;;
      UserName) sel+="'$TO', " ;;
      IsDeleted) sel+="false, " ;;
      *) sel+="\"$c\", " ;;
    esac
  done
  sel="${sel%, }"
  collist="$(printf '"%s",' $(tr ',' ' ' <<< "$COLS"))"; collist="${collist%,}"
  echo "INSERT INTO \"DynamicColumn\" ($collist) SELECT $sel FROM \"DynamicColumn\" WHERE \"Id\"='$old'::uuid AND \"UserName\"='$FROM' AND NOT \"IsDeleted\";" >> "$TMP/insert.sql"
  n=$((n+1))
done
total=$(( n + done_n ))
cat >> "$TMP/insert.sql" <<SQL
DO \$do\$ DECLARE k int; BEGIN
  SELECT count(*) INTO k FROM "DynamicColumn" WHERE "UserName" = '$TO' AND NOT "IsDeleted";
  IF k < $total THEN RAISE EXCEPTION 'expected at least $total bands for $TO, found %', k; END IF;
END \$do\$;
COMMIT;
SQL
cp "$TMP/insert.sql" "$(dirname "$M")/$(basename "$M" .json).bands.sql"
if [ "$n" -eq 0 ]; then echo "copy-bands: all $done_n bands already copied, nothing to apply" >&2; exit 0; fi
[ "$done_n" -gt 0 ] && echo "copy-bands: $done_n already copied, $n to insert" >&2
if [ "$DRY" = "--dry-run" ]; then
  echo "copy-bands: DRY RUN -- $n INSERTs written to $(dirname "$M")/$(basename "$M" .json).bands.sql, nothing applied" >&2
  exit 0
fi
bash "$PG" "$ENV" export -f "$TMP/insert.sql" >"$TMP/apply.out" 2>"$TMP/apply.err" || { cat "$TMP/apply.out" "$TMP/apply.err" >&2; echo "copy-bands: APPLY FAILED" >&2; exit 1; }
grep -qi 'ERROR' "$TMP/apply.out" "$TMP/apply.err" && { cat "$TMP/apply.out" "$TMP/apply.err" >&2; exit 1; }
echo "copy-bands: $n bands copied to $TO" >&2
