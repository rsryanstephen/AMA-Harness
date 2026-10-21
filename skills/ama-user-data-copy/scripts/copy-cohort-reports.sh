#!/usr/bin/env bash
# copy-cohort-reports.sh -- step 3: clone the source user's live cohort reports in Mongo.
# Usage: copy-cohort-reports.sh <manifest.json> [--dry-run]
# The create handler only maps request fields 1:1 and stamps timestamps, so a document clone is
# equivalent to the API and keeps created/lastViewed. Per report: new _id (BinData 3), user =
# target, sharedWith [], viewCount 0, cohorts[] remapped onto the COPIED cohorts (a reference
# to a cohort with no copy -- deleted or missing at the source -- is a dangling ref: the report
# is SKIPPED and listed, never copied), every known old id rewritten in the JSON text (both guid
# forms: searchRequest.CohortIds/ReportId/BandFields, dc__ field names), typed fields rebuilt
# (dates, NumberLong, BinData) by udc.py cohort-report-js. Runs after copy-cohorts.sh.
# Manifest entries: .cohortReports[] = {old,new,name}; .skippedCohortReports[] = {old,name,why}.
# Needs AMA_ALLOW_MONGO_WRITE=1 (AMA_ALLOW_PROD_MONGO_WRITE=1 for production).
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
M="${1:?usage: copy-cohort-reports.sh <manifest.json> [--dry-run]}"; DRY="${2:-}"
DOCDB="$HOME/.claude/skills/ama-mongo-access/scripts/docdb-query.sh"
ENV="$(jr .env "$M")"; FROM="$(jr .from.username "$M")"; TO="$(jr .to.username "$M")"
umask 077; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
madd() { local t="$TMP/m"; jq "$@" "$M" > "$t" && cat "$t" > "$M"; }

bash "$HERE/mongo-dump.sh" "$ENV" cohortreport "$FROM" "$TMP/src.jsonl" || exit 1
total="$(wc -l < "$TMP/src.jsonl" | tr -d ' ')"
if [ "$DRY" = "--dry-run" ]; then
  # no cohorts were created in a dry run: pretend every LIVE source cohort has a copy so the
  # report plan reflects what the real run will do (a ref to a deleted/missing cohort still skips)
  bash "$HERE/mongo-dump.sh" "$ENV" cohort "$FROM" "$TMP/srccoh.jsonl" || exit 1
  cp "$M" "$TMP/dry-manifest.json"; M="$TMP/dry-manifest.json"
  while IFS= read -r cd; do
    o="$(python "$HERE/udc.py" mongo-id "$(jq -c ._id <<<"$cd")")"
    jq -e --arg o "$o" '.cohorts[]? | select(.old==$o and .new!=null)' "$M" >/dev/null && continue
    madd --arg o "$o" --arg n "$(jr .name <<<"$cd")" '.cohorts += [{old:$o,new:"00000000-0000-0000-0000-00000000dead",name:$n}]'
  done < "$TMP/srccoh.jsonl"
fi
done_n=0; skip_n=0; new_n=0
while IFS= read -r doc; do
  old="$(python "$HERE/udc.py" mongo-id "$(jq -c ._id <<<"$doc")")"
  name="$(jr .name <<<"$doc")"
  if jq -e --arg o "$old" '.cohortReports[]? | select(.old==$o)' "$M" >/dev/null; then done_n=$((done_n+1)); continue; fi
  new="$(python "$HERE/udc.py" newid)"
  printf '%s' "$doc" > "$TMP/doc.json"
  if ! js="$(python "$HERE/udc.py" cohort-report-js "$TMP/doc.json" "$M" "$FROM" "$TO" "$new" 2>"$TMP/js.err")"; then
    why="$(tail -1 "$TMP/js.err")"
    echo "  SKIP '$name': $why" >&2
    madd --arg o "$old" --arg n "$name" --arg w "$why" '.skippedCohortReports = ((.skippedCohortReports // []) + [{old:$o,name:$n,why:$w}])'
    skip_n=$((skip_n+1)); continue
  fi
  if [ "$DRY" = "--dry-run" ]; then
    echo "  would insert clone of '$name' as $new (cohorts: $(jq -c .cohorts <<<"$doc"))" >&2; new_n=$((new_n+1)); continue
  fi
  out="$(bash "$DOCDB" "$ENV" "$js" 2>"$TMP/ins.err")"
  grep -q '^INSERTED' <<<"$out" || { echo "copy-cohort-reports: insert failed for '$name': $out $(tail -2 "$TMP/ins.err")" >&2; exit 1; }
  madd --arg o "$old" --arg n "$new" --arg nm "$name" '.cohortReports += [{old:$o,new:$n,name:$nm}]'
  echo "  inserted $new  $name" >&2; new_n=$((new_n+1))
done < "$TMP/src.jsonl"
echo "copy-cohort-reports: $total live at source; $new_n $( [ "$DRY" = "--dry-run" ] && echo 'would be' || echo '')inserted, $done_n already done, $skip_n skipped (dangling cohort refs)" >&2
