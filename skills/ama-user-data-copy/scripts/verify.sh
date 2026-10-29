#!/usr/bin/env bash
# verify.sh -- prove a copy run did what the manifest says, and nothing else.
# Usage: verify.sh <manifest.json>
# Checks (each prints PASS/FAIL, exit 1 on any FAIL):
#   bands     every .bands[].new exists for the target, equal to its source row except Id/UserName/IsDeleted
#   cohorts   every .cohorts[].new is owned by the target, progress.status 2, not failed; type/criteria equal source
#   cohortrep every .cohortReports[].new exists for the target; cohorts[] only reference target-owned copies
#   reports   every .reports[].new exists, OwnedBy target, not deleted; its Report/Query/TemplateFields equal
#             the source's after the SAME id/owner rewrite; one UserSavedReport row per copy under the target's
#             sub pointing into the target's own folder tree
#   coupling  no source id (either guid form) and no source username inside ANY target-owned JSON
#   source    source fingerprint (source-hash.sh) equals the one recorded before the copy
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
M="${1:?usage: verify.sh <manifest.json>}"
PG="$HOME/.claude/skills/ama-postgres-access/scripts/pg-connect.sh"
ENV="$(jr .env "$M")"; FROM="$(jr .from.username "$M")"; FROM_SUB="$(jr .from.sub "$M")"
TO="$(jr .to.username "$M")"; TO_SUB="$(jr .to.sub "$M")"
umask 077; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0; pass() { echo "PASS  $*"; }; failm() { echo "FAIL  $*"; fail=1; }

# ---- Postgres dumps
cat > "$TMP/r.sql" <<SQL
\\set f '$FROM'
\\set t '$TO'
\\set ts '$TO_SUB'
\\echo == rows
select row_to_json(u)::text from "UserReport" u where u."OwnedBy" in (:'f', :'t') order by u."Id";
\\echo == saved
select "ReportUuid"||':'||"UserFolderId" from "UserSavedReport" where "UserUid"=:'ts'::uuid;
\\echo == folder
select "Folders"::text from "UserFolder" where "UserUid"=:'ts'::uuid;
SQL
cat > "$TMP/e.sql" <<SQL
\\set f '$FROM'
\\set t '$TO'
\\echo == bands
select row_to_json(d)::text from "DynamicColumn" d where d."UserName" in (:'f', :'t') order by d."Id";
SQL
bash "$PG" "$ENV" reports -f "$TMP/r.sql" > "$TMP/r.tsv" 2>/dev/null || failm "reports DB read"
bash "$PG" "$ENV" export  -f "$TMP/e.sql" > "$TMP/e.tsv" 2>/dev/null || failm "export DB read"
bash "$HERE/mongo-dump.sh" "$ENV" cohort "$TO" "$TMP/tc.jsonl" 2>/dev/null
bash "$HERE/mongo-dump.sh" "$ENV" cohort "$FROM" "$TMP/sc.jsonl" 2>/dev/null
bash "$HERE/mongo-dump.sh" "$ENV" cohortreport "$TO" "$TMP/tcr.jsonl" 2>/dev/null
bash "$HERE/mongo-dump.sh" "$ENV" cohortreport "$FROM" "$TMP/scr.jsonl" 2>/dev/null

python - "$M" "$TMP" <<'PY'
import json, sys, re, base64, uuid
M = json.load(open(sys.argv[1], encoding='utf-8')); T = sys.argv[2]
FROM, TO = M['from']['username'], M['to']['username']; TO_SUB = M['to']['sub'].lower()
fail = 0
def P(ok, msg):
    global fail
    print(("PASS  " if ok else "FAIL  ") + msg)
    if not ok: fail = 1
def section(path, name):
    out, on = [], False
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\r\n')
        if line.startswith('== '): on = (line == '== ' + name); hdr = True; continue
        if on:
            if hdr: hdr = False; continue
            if line: out.append(line)
    return out
def mid(v):
    # mongosh 7 prints a Binary as its bare base64 string; the legacy shell as {"$binary","$type"}
    if isinstance(v, str):
        return v.lower() if re.fullmatch(r'[0-9a-fA-F-]{36}', v) else str(uuid.UUID(bytes_le=base64.b64decode(v)))
    b = v['$binary']; b = b['base64'] if isinstance(b, dict) else b
    return str(uuid.UUID(bytes_le=base64.b64decode(b)))
pairs = []
for k in ('bands','cohorts','cohortReports','reports'):
    for e in M.get(k, []) or []:
        if e.get('old') and e.get('new'): pairs.append((e['old'].lower(), e['new'].lower()))
def rewrite(text):
    for o, n in pairs:
        text = text.replace(o, n).replace(o.replace('-','_'), n.replace('-','_')).replace(o.upper(), n).replace(o.upper().replace('-','_'), n.replace('-','_'))
    return text
OWNER = {"OwnedBy","Author","User","UserName","Owner","user","author","owner","userName"}
def reown(o):
    if isinstance(o, dict): return {k: (TO if (k in OWNER and v == FROM) else reown(v)) for k, v in o.items()}
    if isinstance(o, list): return [reown(x) for x in o]
    return o
def no_source(text, what):
    bad = [o for o, _ in pairs if o in text.lower() or o.replace('-','_') in text.lower()]
    if re.search(r'"' + re.escape(FROM) + r'"', text): bad.append('username ' + FROM)
    P(not bad, f"coupling: {what} carries no source ids/username" + (f" -- found {bad[:3]}" if bad else ""))

# bands
bands = {}
for line in section(f"{T}/e.tsv", 'bands'):
    d = json.loads(line); bands[d['Id'].lower()] = d
for e in M.get('bands', []):
    s, n = bands.get(e['old']), bands.get(e['new'])
    if not n: P(False, f"band {e['name']}: copy {e['new']} missing"); continue
    P(n['UserName'] == TO and not n['IsDeleted'], f"band {e['name']}: owned by {TO}, live")
    strip = lambda r: {k: v for k, v in r.items() if k not in ('Id','UserName','IsDeleted')}
    P(s is not None and strip(s) == strip(n), f"band {e['name']}: content equals source")
# cohorts
tc = {}
for line in open(f"{T}/tc.jsonl", encoding='utf-8'):
    d = json.loads(line); tc[mid(d['_id'])] = d
sc = {}
for line in open(f"{T}/sc.jsonl", encoding='utf-8'):
    d = json.loads(line); sc[mid(d['_id'])] = d
for e in M.get('cohorts', []):
    n = tc.get(e['new']); s = sc.get(e['old'])
    if not n: P(False, f"cohort {e['name']}: copy {e['new']} not owned by {TO}"); continue
    st = (n.get('progress') or {}).get('status')
    P(st == 2 and not n.get('dataMappingFailed'), f"cohort {e['name']}: generation completed (status {st}, failed {n.get('dataMappingFailed')})")
    if s:
        P(s.get('type') == n.get('type'), f"cohort {e['name']}: type {s.get('type')} preserved")
        key = lambda c: (c.get('field'), c.get('operator'), c.get('value'), c.get('rawValue'))
        P([key(c) for c in s.get('criteria') or []] == [key(c) for c in n.get('criteria') or []], f"cohort {e['name']}: criteria equal source")
P(len([d for d in tc.values()]) >= len(M.get('cohorts', [])), f"cohorts: target owns {len(tc)} live (manifest {len(M.get('cohorts', []))})")
# cohort reports
tcr = {}
for line in open(f"{T}/tcr.jsonl", encoding='utf-8'):
    d = json.loads(line); tcr[mid(d['_id'])] = d
scr = {}
for line in open(f"{T}/scr.jsonl", encoding='utf-8'):
    d = json.loads(line); scr[mid(d['_id'])] = d
for e in M.get('cohortReports', []):
    n = tcr.get(e['new']); s = scr.get(e['old'])
    if not n: P(False, f"cohort report {e['name']}: copy missing"); continue
    refs = [c.lower() for c in n.get('cohorts') or []]
    P(all(r in tc for r in refs), f"cohort report {e['name']}: {len(refs)} cohort ref(s) all target-owned copies")
    if s:
        drop = ('_id','user','sharedWith','viewCount','cohorts','lastUpdated','progress','mappingId')
        ss = json.loads(rewrite(json.dumps(reown({k: v for k, v in s.items() if k not in drop}))))
        nn = {k: v for k, v in n.items() if k not in drop}
        P(ss == nn, f"cohort report {e['name']}: content equals rewritten source")
no_source(open(f"{T}/tcr.jsonl", encoding='utf-8').read(), "target cohort reports")
# reports
rows = {}
for line in section(f"{T}/r.tsv", 'rows'):
    d = json.loads(line); rows[d['Id'].lower()] = d
saved = {}
for line in section(f"{T}/r.tsv", 'saved'):
    r, f = line.split(':'); saved.setdefault(r.lower(), []).append(f.lower())
folders = section(f"{T}/r.tsv", 'folder')
P(len(folders) == 1, f"target has exactly one UserFolder row ({len(folders)})")
fids = set()
def walk(fs):
    for f in fs or []:
        fids.add(f['Id'].lower()); walk(f.get('Subfolders'))
if folders: walk(json.loads(folders[0]))
target_json = []
for e in M.get('reports', []):
    s, n = rows.get(e['old']), rows.get(e['new'])
    if not n: P(False, f"report {e['name']}: copy {e['new']} missing"); continue
    P(n['OwnedBy'] == TO and not n['IsDeleted'] and not n['IsShared'] and not n.get('MonthlyDownloadsActivated'), f"report {e['name']}: owned by {TO}, live, unshared, monthly off")
    if s:
        def norm(r, nid):
            out = {}
            for k in ('Report','Query','TemplateFields'):
                v = r.get(k)
                if v is None: out[k] = None; continue
                v = reown(v)
                if k == 'Report' and isinstance(v, dict):
                    v.pop('Id', None); v.pop('IsShared', None)
                out[k] = json.loads(rewrite(json.dumps(v)).replace(e['old'], nid))
            for k in ('Name','ReportDescription','QueryDescription','ReportType','BasedOn','AutoUpdateFields','MetadataLatestCprPeriod','MetadataLatestCprYear','LastUpdated'):
                out[k] = r.get(k)
            return out
        P(norm(s, e['new']) == norm(n, e['new']), f"report {e['name']}: definition equals rewritten source")
    sv = saved.get(e['new'], [])
    P(len(sv) >= 1 and all(f in fids for f in sv), f"report {e['name']}: {len(sv)} saved row(s) in the target's own folder tree")
    target_json.append(json.dumps({k: n.get(k) for k in ('Report','Query','TemplateFields')}))
no_source("\n".join(target_json), "target saved reports")
sys.exit(fail)
PY
[ $? -eq 0 ] || fail=1

# ---- source untouched
if h0="$(jr '.sourceHash // empty' "$M")" && [ -n "$h0" ]; then
  h1="$(bash "$HERE/source-hash.sh" "$ENV" "$FROM" "$FROM_SUB" 2>/dev/null)"
  if [ "$h0" = "$h1" ]; then pass "source fingerprint unchanged"; else failm "source fingerprint CHANGED ($h0 -> $h1)"; fi
else
  echo "SKIP  source fingerprint (none recorded before the copy)"
fi
[ $fail -eq 0 ] && echo "verify: ALL PASS" || { echo "verify: FAILURES above" >&2; exit 1; }
