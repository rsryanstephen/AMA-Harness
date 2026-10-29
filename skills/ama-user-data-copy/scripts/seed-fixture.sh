#!/usr/bin/env bash
# seed-fixture.sh -- seed a NON-production source user with a realistic data set to rehearse
# a user-data copy against. Everything goes through the real APIs as that user.
# Usage: seed-fixture.sh <qa|staging> <samples-dir> <manifest-out.json>
#   samples-dir holds strict-JSON samples pulled read-only from production:
#     samples-bands.jsonl        one DynamicColumn row per line (row_to_json)
#     samples-reports.jsonl      one UserReport row per line (row_to_json)
#     samples-mongo.tsv          "COHORT|<json>" and "COHORTREPORT|<json>" lines (JSON.stringify)
# Source user = .users.<env>.tier3500, share target = .users.<env>.tier1800 (credentials file).
# What it creates (all names prefixed "AMA copy-fixture - "):
#   bands x3 (one per sample) | cohorts x5 (4 samples + 1 extra that gets deleted) |
#   cohort reports x5 (cohorts remapped onto the fixture cohorts, one dc__ field remapped) |
#   saved reports x7 (6 samples + 1 extra that gets deleted; dc__ refs remapped round-robin) |
#   one custom folder with one report moved into it | one report shared with tier1800 |
#   monthly downloads ON for one report | one report + one cohort soft-deleted.
# Writes every created id to the manifest so the rehearsal can be torn down afterwards.
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
# Name prefix for everything seeded. Override with FIXTURE_PREFIX on a re-seed: the band
# name-exists check (DynamicColumnExistHandlerQueryBuilder) ignores IsDeleted, so a deleted
# fixture band still blocks its name.
PREFIX="${FIXTURE_PREFIX:-AMA copy-fixture - }"

ENV="${1:?usage: seed-fixture.sh <qa|staging> <samples-dir> <manifest-out.json>}"
SAMPLES="${2:?usage: seed-fixture.sh <env> <samples-dir> <manifest-out.json>}"
MANIFEST="${3:?usage: seed-fixture.sh <env> <samples-dir> <manifest-out.json>}"
case "$ENV" in qa|staging) ;; *) echo "seed-fixture.sh: qa/staging only" >&2; exit 1 ;; esac
for f in samples-bands.jsonl samples-reports.jsonl samples-mongo.tsv; do
  [ -s "$SAMPLES/$f" ] || { echo "missing $SAMPLES/$f" >&2; exit 1; }
done

CREDS="$HOME/.claude/.ama-ui-credentials.json"
SRC="$(jr --arg e "$ENV" '.users[$e].tier3500' "$CREDS")"
SHARE_WITH="$(jr --arg e "$ENV" '.users[$e].tier1800' "$CREDS")"

umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TOK="$TMP/tok.json"
bash "$HERE/cognito-token.sh" "$ENV" "$SRC" "$TOK" || exit 1
API() { bash "$HERE/api.sh" "$ENV" "$TOK" "$@" 2>>"$TMP/http.log"; }
last_http() { tail -1 "$TMP/http.log"; }
die() { echo "seed-fixture.sh: $*" >&2; echo "last HTTP: $(last_http)" >&2; exit 1; }

M="$TMP/manifest.json"
echo '{"env":"'"$ENV"'","sourceUser":"'"$SRC"'","bands":[],"cohorts":[],"cohortReports":[],"reports":[],"folder":null,"shared":null,"monthly":null,"deleted":{}}' > "$M"
madd() { local tmp="$TMP/m.$$"; jq "$@" "$M" > "$tmp" && mv "$tmp" "$M"; }

# ---------- 1. bands ----------
echo "== bands" >&2
BAND_IDS=()
# Resume after a failure past steps 1-2: SEED_BAND_IDS / SEED_COHORT_IDS / SEED_EXTRA_COHORT
# (comma lists, in sample order, from the previous run's log) skip the creates and the wait.
if [ -n "${SEED_BAND_IDS:-}" ]; then
  IFS=',' read -ra BAND_IDS <<< "$SEED_BAND_IDS"; echo "  reusing ${#BAND_IDS[@]} existing bands" >&2
  i=0; while IFS= read -r row; do madd --arg id "${BAND_IDS[$i]}" --arg n "$(jr .Name <<<"$row")" --arg src "$(jr .Id <<<"$row")" '.bands += [{id:$id, name:$n, sampleId:$src}]'; i=$((i+1)); done < "$SAMPLES/samples-bands.jsonl"
fi
[ -n "${SEED_BAND_IDS:-}" ] || while IFS= read -r row; do
  body="$TMP/band.json"
  jq --arg p "$PREFIX" '{name: ($p + .Name), condition: .Condition, description: .Description,
    type: .Type, baseField: .BaseField, fieldType: .FieldType, metadata: .Metadata}' <<<"$row" > "$body"
  resp="$(API POST /source/dynamic-column "$body")" || die "band create failed: $resp"
  id="$(jr '.id // .Id' <<<"$resp")"; [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || die "band create returned no id: $resp"
  BAND_IDS+=("$id"); echo "  band $id  $(jr .Name <<<"$row")" >&2
  madd --arg id "$id" --arg n "$(jr .Name <<<"$row")" --arg src "$(jr .Id <<<"$row")" '.bands += [{id:$id, name:$n, sampleId:$src}]'
done < "$SAMPLES/samples-bands.jsonl"
[ ${#BAND_IDS[@]} -ge 1 ] || die "no bands created"

# ---------- 2. cohorts (4 samples + 1 extra copy of the 2nd sample, later deleted) ----------
echo "== cohorts" >&2
COHORT_IDS=()
create_cohort() { # $1 = cohort doc json, $2 = name suffix
  local body="$TMP/cohort.json" resp id
  jq --arg p "$PREFIX" --arg sfx "$2" '{name: ($p + .name + $sfx), description: .description,
    criteria: [.criteria[] | {field, operator, value}], sharedWith: [], source: .source}' <<<"$1" > "$body"
  resp="$(API POST /cohort "$body")" || die "cohort create failed: $resp"
  id="$(jr '.id // .Id' <<<"$resp")"; [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || die "cohort create returned no id: $resp"
  echo "$id"
}
mapfile -t COHORT_DOCS < <(grep '^COHORT|' "$SAMPLES/samples-mongo.tsv" | cut -d'|' -f2-)
if [ -n "${SEED_COHORT_IDS:-}" ]; then
  IFS=',' read -ra COHORT_IDS <<< "$SEED_COHORT_IDS"; EXTRA_COHORT="${SEED_EXTRA_COHORT:?SEED_EXTRA_COHORT needed with SEED_COHORT_IDS}"
  echo "  reusing ${#COHORT_IDS[@]} existing cohorts + extra $EXTRA_COHORT" >&2
  i=0; for doc in "${COHORT_DOCS[@]}"; do madd --arg id "${COHORT_IDS[$i]}" --arg n "$(jr .name <<<"$doc")" --arg t "$(jr .type <<<"$doc")" '.cohorts += [{id:$id, name:$n, type:$t}]'; i=$((i+1)); done
else
for doc in "${COHORT_DOCS[@]}"; do
  id="$(create_cohort "$doc" "")"; COHORT_IDS+=("$id"); echo "  cohort $id  $(jr .name <<<"$doc") ($(jr .type <<<"$doc"))" >&2
  madd --arg id "$id" --arg n "$(jr .name <<<"$doc")" --arg t "$(jr .type <<<"$doc")" '.cohorts += [{id:$id, name:$n, type:$t}]'
done
EXTRA_COHORT="$(create_cohort "${COHORT_DOCS[1]}" " (to delete)")"; echo "  cohort $EXTRA_COHORT  (extra, will be deleted)" >&2
fi

# wait for generation: progress.status 2 = Completed, 3 = Failed
echo "== waiting for cohort data generation" >&2
deadline=$(( $(date +%s) + 1800 ))
for id in "${COHORT_IDS[@]}" "$EXTRA_COHORT"; do
  while :; do
    st="$(API GET "/cohort/$id" | jr '.progress.status // .Progress.Status // "?"')"
    case "$st" in
      2) echo "  $id completed" >&2; break ;;
      3) die "cohort $id generation FAILED" ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || die "timed out waiting for cohort $id (status $st)"
    sleep 10
  done
done

# ---------- 3. cohort reports ----------
echo "== cohort reports" >&2
# dc__ in cohort-report fields uses the UNDERSCORED guid; map every sample band id -> first fixture band
band_ul="${BAND_IDS[0]//-/_}"
mapfile -t CR_DOCS < <(grep '^COHORTREPORT|' "$SAMPLES/samples-mongo.tsv" | cut -d'|' -f2-)
for doc in "${CR_DOCS[@]}"; do
  n="$(jr '.cohorts|length' <<<"$doc")"
  # plain bash JSON array -- `jq -R . | jq -s .` came back [] on this box (jq 1.5 + CRLF)
  if [ "$n" -gt 0 ]; then cohorts_json="[$(printf '"%s",' "${COHORT_IDS[@]:0:$n}" | sed 's/,$//')]"; else cohorts_json="[]"; fi
  body="$TMP/cr.json"
  jq --arg p "$PREFIX" --argjson cohorts "$cohorts_json" --arg b "$band_ul" '
    def remap: if type=="string" then gsub("dc__[0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12}"; "dc__" + $b) else . end;
    {name: ($p + .name), description: .description, template: .template, cohorts: $cohorts,
     fields: (if .fields == null then null else [.fields[] | remap] end),
     criteria: .criteria, orderBys: .orderBys, sharedWith: []}' <<<"$doc" > "$body"
  resp="$(API POST /cohort/report "$body")" || die "cohort report create failed: $resp"
  id="$(jr '.id // .Id' <<<"$resp")"; [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || die "cohort report create returned no id: $resp"
  echo "  cohort report $id  $(jr .name <<<"$doc") (cohorts=$n, template=$(jr .template <<<"$doc"))" >&2
  madd --arg id "$id" --arg n "$(jr .name <<<"$doc")" --argjson c "$cohorts_json" '.cohortReports += [{id:$id, name:$n, cohorts:$c}]'
done

# ---------- 4. saved reports (6 samples + the last one again, later deleted) ----------
echo "== saved reports" >&2
# every distinct band id referenced by the samples -> a fixture band, round-robin (both guid forms)
mapfile -t SRC_BANDS < <(grep -oE 'dc__[0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12}' "$SAMPLES/samples-reports.jsonl" | sed 's/^dc__//' | sort -u)
SED_ARGS=()
i=0
for ul in "${SRC_BANDS[@]}"; do
  new="${BAND_IDS[$(( i % ${#BAND_IDS[@]} ))]}"; i=$((i+1))
  SED_ARGS+=(-e "s/${ul}/${new//-/_}/g" -e "s/${ul//_/-}/${new}/g")
done
REPORT_IDS=()
create_report() { # $1 = row json, $2 = name suffix
  local row body resp id
  row="$(sed "${SED_ARGS[@]}" <<<"$1")"
  body="$TMP/report.json"
  jq --arg p "$PREFIX" --arg sfx "$2" '
    {Report: (
      del(.Id, .OwnedBy, .LastUpdated, .LastOpened, .OpenedTally, .MetadataLatestCprPeriod, .MetadataLatestCprYear)
      | .Name = ($p + .Name + $sfx) | .IsShared = false | .SharedOrgUuid = null | .MonthlyDownloadsActivated = false
      | .Report = (.Report | del(.Id) | .IsShared = false)
    ), Folder: null}' <<<"$row" > "$body"
  resp="$(API POST /report "$body")" || die "report create failed: $resp"
  id="$(jr '.Id // .id' <<<"$resp")"; [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || die "report create returned no id: $resp"
  echo "$id"
}
LAST_ROW=""
while IFS= read -r row; do
  id="$(create_report "$row" "")"; REPORT_IDS+=("$id"); LAST_ROW="$row"
  echo "  report $id  $(jr .Name <<<"$row") ($(jr .BasedOn <<<"$row"))" >&2
  madd --arg id "$id" --arg n "$(jr .Name <<<"$row")" --arg t "$(jr .BasedOn <<<"$row")" '.reports += [{id:$id, name:$n, basedOn:$t}]'
done < "$SAMPLES/samples-reports.jsonl"
EXTRA_REPORT="$(create_report "$LAST_ROW" " (to delete)")"; echo "  report $EXTRA_REPORT  (extra, will be deleted)" >&2

# ---------- 5. folder: create one under Home, move the first report into it ----------
echo "== folder" >&2
folders="$(API GET /report/user-folder)" || die "user-folder read failed"
home="$(jr '.Folders[0].Id' <<<"$folders")"
jq -n --arg n "${PREFIX}folder" --arg h "$home" '{FolderName:$n, ParentFolderId:$h}' > "$TMP/folder.json"
folders="$(API POST /report/user-folder "$TMP/folder.json")" || die "folder create failed: $folders"
newf="$(jr --arg n "${PREFIX}folder" '.. | objects | select(.Name? == $n) | .Id' <<<"$folders" | head -1)"
[[ "$newf" =~ ^[0-9a-f-]{36}$ ]] || die "new folder id not found in $folders"
jq -n --arg r "${REPORT_IDS[0]}" --arg c "$home" --arg n "$newf" '{ReportId:$r, CurrentFolderId:$c, NewFolderId:$n}' > "$TMP/move.json"
API PUT /report/user-folder/report "$TMP/move.json" >/dev/null || die "move report to folder failed"
echo "  folder $newf <- report ${REPORT_IDS[0]}" >&2
madd --arg f "$newf" --arg r "${REPORT_IDS[0]}" '.folder = {id:$f, reportMoved:$r}'

# ---------- 6. share the second report with the tier1800 test user ----------
echo "== share" >&2
tgt="$(API GET "/manage/users/username/$SHARE_WITH")" || die "could not read $SHARE_WITH"
jq -n --arg r "${REPORT_IDS[1]}" --argjson t "$tgt" '{ReportUuid:$r, FirstShare:true, Title:"AMA copy-fixture share", Body:"fixture",
  Users:[{OrganizationId:$t.organisationUuid, UserGuid:$t.uid}], IsCustom:true}' > "$TMP/share.json"
API PUT /report/share "$TMP/share.json" >/dev/null || die "share failed"
echo "  report ${REPORT_IDS[1]} shared with $SHARE_WITH" >&2
madd --arg r "${REPORT_IDS[1]}" --arg u "$SHARE_WITH" '.shared = {report:$r, with:$u}'

# ---------- 7. monthly downloads ON for the third report ----------
echo "== monthly downloads" >&2
jq -n --arg r "${REPORT_IDS[2]}" '{ReportId:$r, MonthlyDownloadsActivated:true}' > "$TMP/md.json"
if API PUT /report/monthly-downloads/set "$TMP/md.json" >/dev/null; then
  echo "  monthly downloads on for ${REPORT_IDS[2]}" >&2; madd --arg r "${REPORT_IDS[2]}" '.monthly = $r'
else
  echo "  WARN monthly-downloads/set refused ($(last_http)) -- fixture continues without it" >&2
fi

# ---------- 8. soft-delete the extras ----------
echo "== deletes" >&2
API DELETE "/report/$EXTRA_REPORT" >/dev/null || die "report delete failed"
API DELETE "/cohort/$EXTRA_COHORT" >/dev/null || die "cohort delete failed"
madd --arg r "$EXTRA_REPORT" --arg c "$EXTRA_COHORT" '.deleted = {report:$r, cohort:$c}'

mkdir -p "$(dirname "$MANIFEST")"
cp "$M" "$MANIFEST"
echo "== done; manifest: $MANIFEST" >&2
jq -c '{bands:(.bands|length), cohorts:(.cohorts|length), cohortReports:(.cohortReports|length), reports:(.reports|length), folder:.folder.id, shared:.shared.report, monthly:.monthly, deleted:.deleted}' "$MANIFEST"
