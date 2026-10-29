#!/usr/bin/env bash
# copy-cohorts.sh -- step 2: recreate the source user's live cohorts through the real API, then
# re-own each copy with one Mongo update.
# Usage: copy-cohorts.sh <manifest.json> [--dry-run] [--batch N]
# Why the API: POST /cohort is the only path that allocates MappingId, writes the Redshift
# CohortNameMapping row and queues cohortdata generation (CohortCreatedEvent). The POST runs
# as the harness test user named in .tempUser (Tier3500 satisfies Roles.DynamicCohorts); the
# copy is then flipped to the target with updateOne({$set:{user, created}}) -- ONLY after
# progress.status is 2 (Completed): the progress handler ReplaceOne()s the whole document, so
# an earlier flip would be silently reverted. Batched (default 5 at a time) so generation load
# on the shared Redshift cluster stays bounded.
# Manifest entries: .cohorts[] = {old,new,name,type,status,flipped}. Idempotent/resumable.
# The Mongo update needs AMA_ALLOW_MONGO_WRITE=1 (AMA_ALLOW_PROD_MONGO_WRITE=1 for production)
# in Claude Code's own environment.
# Redshift window: creation stops (exit 3, resumable) when lib-redshift-window.sh says the
# Mon-Fri 9-5 ET window is open or about to open; cohorts already posted are still waited for
# and flipped (light: GET polling + one Mongo update each).
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
M="${1:?usage: copy-cohorts.sh <manifest.json> [--dry-run] [--batch N]}"; shift
DRY=""; BATCH=5
while [ $# -gt 0 ]; do case "$1" in --dry-run) DRY=1 ;; --batch) BATCH="$2"; shift ;; esac; shift; done
DOCDB="$HOME/.claude/skills/ama-mongo-access/scripts/docdb-query.sh"
. "$HERE/lib-redshift-window.sh"
ENV="$(jr .env "$M")"; FROM="$(jr .from.username "$M")"; TO="$(jr .to.username "$M")"; TEMP="$(jr .tempUser "$M")"
umask 077; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
madd() { local t="$TMP/m"; jq "$@" "$M" > "$t" && cat "$t" > "$M"; }
TOK="$TMP/tok.json"
API() { bash "$HERE/api.sh" "$ENV" "$TOK" "$@" 2>>"$TMP/http.log"; }

bash "$HERE/mongo-dump.sh" "$ENV" cohort "$FROM" "$TMP/src.jsonl" || exit 1
bash "$HERE/mongo-dump.sh" "$ENV" cohort "$TO" "$TMP/tgt.jsonl" || exit 1
bash "$HERE/mongo-dump.sh" "$ENV" cohort "$TEMP" "$TMP/tmpuser.jsonl" || exit 1
total="$(wc -l < "$TMP/src.jsonl" | tr -d ' ')"
echo "copy-cohorts: $total live cohorts owned by $FROM; target $TO has $(wc -l < "$TMP/tgt.jsonl" | tr -d ' '); temp user $TEMP has $(wc -l < "$TMP/tmpuser.jsonl" | tr -d ' ')" >&2

# Name clashes. POST checks the CALLER's names (case-insensitive) -> a temp-user leftover 400s;
# after the flip two same-named cohorts under the target make GET /cohort?name= 500.
jr '.name|ascii_downcase' "$TMP/tmpuser.jsonl" | sort > "$TMP/tmp.names"
jr '.name|ascii_downcase' "$TMP/tgt.jsonl"     | sort > "$TMP/tgt.names"
jr '.name|ascii_downcase' "$TMP/src.jsonl"     | sort > "$TMP/src.names"
if comm -12 "$TMP/src.names" "$TMP/tmp.names" | grep -q .; then
  echo "copy-cohorts: temp user $TEMP already owns cohorts with these names -- delete them first:" >&2
  comm -12 "$TMP/src.names" "$TMP/tmp.names" >&2; exit 1
fi
comm -12 "$TMP/src.names" "$TMP/tgt.names" > "$TMP/clash.names"
[ -s "$TMP/clash.names" ] && echo "copy-cohorts: target already has $(wc -l < "$TMP/clash.names") same-named cohort(s); those copies get the suffix ' (copy)'" >&2

[ -n "$DRY" ] || bash "$HERE/cognito-token.sh" "$ENV" "$TEMP" "$TOK" || exit 1

# ---- plan: every source cohort not yet created
mapfile -t PENDING < <(while IFS= read -r doc; do
  old="$(python "$HERE/udc.py" mongo-id "$(jq -c ._id <<<"$doc")")"
  jq -e --arg o "$old" '.cohorts[]? | select(.old==$o and .new!=null)' "$M" >/dev/null && continue
  printf '%s\t%s\n' "$old" "$doc"
done < "$TMP/src.jsonl")
echo "copy-cohorts: ${#PENDING[@]} to create, $(( total - ${#PENDING[@]} )) already created" >&2
if [ -n "$DRY" ]; then
  for p in "${PENDING[@]}"; do doc="${p#*$'\t'}"; echo "  would POST /cohort as $TEMP: $(jr '"\(.name) [\(.type)] criteria=\(.criteria|length)"' <<<"$doc") then flip user -> $TO" >&2; done
  if reason="$(window_blocked "$ENV" "${#PENDING[@]}")"; then echo "copy-cohorts: NOTE a live run now would stop before creating: $reason" >&2; fi
  echo "copy-cohorts: DRY RUN, nothing created" >&2; exit 0
fi

create_one() { # $1 old-guid  $2 doc
  local old="$1" doc="$2" name lname body resp new sfx=""
  name="$(jr .name <<<"$doc")"; lname="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  grep -qxF "$lname" "$TMP/clash.names" && sfx=" (copy)"
  body="$TMP/c.json"
  jq --arg sfx "$sfx" '{name: (.name + $sfx), description: .description, criteria: [.criteria[] | {field, operator, value}], sharedWith: [], source: .source}' <<<"$doc" > "$body"
  resp="$(API POST /cohort "$body")" || { echo "copy-cohorts: POST failed for '$name': $resp ($(tail -1 "$TMP/http.log"))" >&2; return 1; }
  new="$(jr '.id // .Id' <<<"$resp")"; [[ "$new" =~ ^[0-9a-f-]{36}$ ]] || { echo "copy-cohorts: no id in response for '$name': $resp" >&2; return 1; }
  madd --arg o "$old" --arg n "$new" --arg nm "$name" --arg t "$(jr .type <<<"$doc")" --arg cr "$(jr .created <<<"$doc")" \
    '.cohorts += [{old:$o,new:$n,name:$nm,type:$t,created:$cr,status:"created",flipped:false}]'
  echo "  created $new  $name" >&2
}

wait_and_flip() { # $@ = new ids
  # COHORT_WAIT_SECS: per-batch ceiling. QA drained ~1 cohort / 10 min, so a batch of 10 needs well
  # over an hour; a timeout here is resumable (--resume finishes created-but-unflipped cohorts).
  local deadline=$(( $(date +%s) + ${COHORT_WAIT_SECS:-10800} )) id st
  for id in "$@"; do
    while :; do
      st="$(API GET "/cohort/$id" | jr '.progress.status // .Progress.Status // "?"')"
      case "$st" in
        2) break ;;
        3) echo "copy-cohorts: generation FAILED for $id" >&2; madd --arg n "$id" '(.cohorts[] | select(.new==$n) | .status) = "failed"'; continue 2 ;;
      esac
      [ "$(date +%s)" -lt "$deadline" ] || { echo "copy-cohorts: timed out waiting for $id (status $st)" >&2; return 1; }
      sleep 10
    done
    local created b64 js out
    created="$(jr --arg n "$id" '.cohorts[] | select(.new==$n) | .created' "$M")"
    b64="$(python "$HERE/udc.py" guid2bin "$id")"
    js="var c=db.getSiblingDB('cohort'); var r=c.cohort.updateOne({_id: BinData(3,'$b64'), user: '$TEMP'}, {\$set: {user: '$TO', created: new Date('$created')}}); print('MATCHED '+r.matchedCount+' MODIFIED '+r.modifiedCount); var d=c.cohort.findOne({_id: BinData(3,'$b64')}); print('AFTER|'+JSON.stringify({user:d.user, status:d.progress.status, failed:d.dataMappingFailed, type:d.type, mappingId:d.mappingId, criteria:d.criteria}));"
    out="$(bash "$DOCDB" "$ENV" "$js" 2>/dev/null)"
    grep -q 'MODIFIED 1' <<<"$out" || { echo "copy-cohorts: flip did not modify $id: $out" >&2; return 1; }
    local after; after="$(grep '^AFTER|' <<<"$out" | cut -d'|' -f2-)"
    [ "$(jr .user <<<"$after")" = "$TO" ] || { echo "copy-cohorts: user not $TO after flip: $after" >&2; return 1; }
    madd --arg n "$id" --argjson a "$after" '(.cohorts[] | select(.new==$n)) |= (.status="completed" | .flipped=true | .mappingIdNew=($a.mappingId|tostring) | .typeNew=$a.type | .criteriaNew=$a.criteria)'
    echo "  completed + re-owned $id" >&2
  done
}

i=0; batch=(); STOPPED=""
for p in "${PENDING[@]}"; do
  if reason="$(window_blocked "$ENV" "${#PENDING[@]}")"; then
    echo "copy-cohorts: $reason -- not creating more cohorts now ($i of ${#PENDING[@]} pending created); finishing the ones in flight" >&2
    STOPPED=1; break
  fi
  old="${p%%$'\t'*}"; doc="${p#*$'\t'}"
  create_one "$old" "$doc" || exit 1
  batch+=("$(jr --arg o "$old" '.cohorts[] | select(.old==$o) | .new' "$M")")
  i=$((i+1))
  if [ $(( i % BATCH )) -eq 0 ]; then wait_and_flip "${batch[@]}" || exit 1; batch=(); fi
done
[ ${#batch[@]} -gt 0 ] && { wait_and_flip "${batch[@]}" || exit 1; }

# anything created earlier but never flipped (resumed run)
mapfile -t LEFT < <(jr '.cohorts[] | select(.flipped!=true and .status!="failed") | .new' "$M")
[ ${#LEFT[@]} -gt 0 ] && { echo "copy-cohorts: finishing ${#LEFT[@]} earlier-created cohorts" >&2; wait_and_flip "${LEFT[@]}" || exit 1; }

# fidelity: type and criteria fields/rawValue must equal the source (CmoCohortCriteriaFixer rewrites legacy collateral_cte fields)
python - "$M" "$TMP/src.jsonl" <<'PY' >&2
import json, sys
m = json.load(open(sys.argv[1], encoding='utf-8'))
src = {}
import base64, uuid
def mid(v):
    # mongosh 7 prints a Binary as its bare base64 string; the legacy shell as {"$binary","$type"}
    if isinstance(v, str):
        return str(uuid.UUID(bytes_le=base64.b64decode(v)))
    b = v['$binary']; b = b['base64'] if isinstance(b, dict) else b
    return str(uuid.UUID(bytes_le=base64.b64decode(b)))
for line in open(sys.argv[2], encoding='utf-8'):
    d = json.loads(line); src[mid(d['_id'])] = d
bad = 0
for e in m.get('cohorts', []):
    s = src.get(e['old'])
    if not s or not e.get('flipped'):
        continue
    if (s.get('type') != e.get('typeNew')):
        print(f"  TYPE CHANGED {e['name']}: {s.get('type')} -> {e.get('typeNew')}"); bad += 1
    sc = [(c.get('field'), c.get('operator'), c.get('value'), c.get('rawValue')) for c in s.get('criteria') or []]
    nc = [(c.get('field'), c.get('operator'), c.get('value'), c.get('rawValue')) for c in e.get('criteriaNew') or []]
    if sc != nc:
        print(f"  CRITERIA DIFFER {e['name']}"); bad += 1
print(f"copy-cohorts: fidelity check -> {bad} difference(s) across {sum(1 for e in m.get('cohorts',[]) if e.get('flipped'))} copied cohorts")
sys.exit(1 if bad else 0)
PY
rc=$?; [ $rc -eq 0 ] || exit $rc
if [ -n "$STOPPED" ]; then
  echo "copy-cohorts: STOPPED for the Redshift window -- re-run after 17:00 ET (or at the weekend) with --resume; everything created so far is kept in the manifest" >&2
  exit 3
fi
exit 0
