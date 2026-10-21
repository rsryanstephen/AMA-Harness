#!/usr/bin/env python
"""udc.py -- helpers for ama-user-data-copy. Pure stdlib, invoked by the bash steps.

Subcommands
  newid                              print a fresh uuid4
  guid2bin <guid>                    base64 of the CSharpLegacy (subtype 3) bytes -> BinData(3, ...)
  bin2guid <base64>                  reverse
  mongo-id <json>                    the _id field as JSON.stringify printed it (legacy shell
                                     {"$binary":..,"$type":"03"}, mongosh EJSON {"$binary":{"base64":..}}
                                     or a bare base64 string) -> guid string
  cohort-report-js <doc.json> <manifest.json> <from-user> <to-user> <new-guid>
                                     print the mongosh/legacy-shell JS that inserts the clone
  reports-sql ... (see reports_sql)  build the one-transaction INSERT script for saved reports
  check-no-source-ids <text-file> <manifest.json> <from-user>
                                     exit 1 if any OLD id (either guid form) or the source username
                                     survives in the file -- the "no cross-user coupling" assertion

Id forms: Postgres/API use hyphenated guids; report field names use dc__<guid with _>; Mongo
cohort._id is BinData subtype 3 with CSharpLegacy byte order (first 3 groups little-endian).
"""
import base64
import json
import os
import re
import sys
import uuid

GUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def guid2bin(g):
    return base64.b64encode(uuid.UUID(g).bytes_le).decode()


def bin2guid(b64):
    return str(uuid.UUID(bytes_le=base64.b64decode(b64)))


def mongo_id(v):
    if isinstance(v, str):
        s = v.strip()
        if GUID_RE.fullmatch(s):
            return s.lower()
        try:
            v = json.loads(s)
        except ValueError:
            return bin2guid(s)
        if isinstance(v, str):  # mongosh 7: JSON.stringify(Binary) is the bare base64 string
            return s.lower() if GUID_RE.fullmatch(v) else bin2guid(v)
    if isinstance(v, dict) and "$binary" in v:
        b = v["$binary"]
        if isinstance(b, dict):
            b = b["base64"]
        return bin2guid(b)
    if isinstance(v, dict) and "$uuid" in v:
        return v["$uuid"].lower()
    raise SystemExit(f"mongo-id: unrecognised _id shape: {str(v)[:120]}")


def id_pairs(manifest):
    """Every old->new id pair the manifest knows (bands, cohorts, cohort reports, reports)."""
    pairs = []
    for key in ("bands", "cohorts", "cohortReports", "reports"):
        for e in manifest.get(key, []) or []:
            if e.get("old") and e.get("new"):
                pairs.append((e["old"].lower(), e["new"].lower()))
    return pairs


def rewrite_text(text, pairs):
    for old, new in pairs:
        text = text.replace(old, new).replace(old.replace("-", "_"), new.replace("-", "_"))
        text = text.replace(old.upper(), new).replace(old.upper().replace("-", "_"), new.replace("-", "_"))
    return text


OWNER_KEYS = {"OwnedBy", "Author", "User", "UserName", "Owner", "user", "author", "owner", "userName"}


def rewrite_owner(obj, from_user, to_user):
    if isinstance(obj, dict):
        return {k: (to_user if (k in OWNER_KEYS and v == from_user) else rewrite_owner(v, from_user, to_user))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [rewrite_owner(x, from_user, to_user) for x in obj]
    return obj


def check_no_source_ids(path, manifest, from_user):
    text = open(path, encoding="utf-8").read()
    bad = []
    for old, _ in id_pairs(manifest):
        for form in (old, old.replace("-", "_"), old.upper(), old.upper().replace("-", "_")):
            if form in text:
                bad.append(form)
                break
    if re.search(r'"' + re.escape(from_user) + r'"', text):
        bad.append(f"username {from_user}")
    if bad:
        print("SOURCE IDS SURVIVE IN COPY: " + ", ".join(bad), file=sys.stderr)
        return 1
    return 0


# ---------------------------------------------------------------- cohort report clone JS
def js_string(s):
    return json.dumps(s)


def cohort_report_js(doc_path, manifest_path, from_user, to_user, new_guid):
    doc = json.load(open(doc_path, encoding="utf-8"))
    manifest = json.load(open(manifest_path, encoding="utf-8"))
    cohort_map = {e["old"].lower(): e["new"] for e in manifest.get("cohorts", []) if e.get("new")}
    doc.pop("_id", None)
    # cohorts[] must point at COPIED cohorts, every one of them.
    cohorts = doc.get("cohorts") or []
    mapped = []
    for c in cohorts:
        if c.lower() not in cohort_map:
            raise SystemExit(f"cohort report {doc.get('name')!r} references cohort {c} with no copy in the manifest")
        mapped.append(cohort_map[c.lower()])
    doc["cohorts"] = mapped
    doc["user"] = to_user
    doc["sharedWith"] = []
    doc["viewCount"] = 0
    doc = rewrite_owner(doc, from_user, to_user)
    text = rewrite_text(json.dumps(doc), id_pairs(manifest))
    doc = json.loads(text)
    # typed fields: JSON.stringify flattened them; rebuild them in the shell.
    dates = [k for k in ("created", "lastUpdated", "lastViewed", "dataLastAvailable") if doc.get(k)]
    js = [
        "var c = db.getSiblingDB('cohort');",
        "var d = " + json.dumps(doc) + ";",
        "function I(x){ return (typeof Int32 !== 'undefined') ? Int32(x) : NumberInt(x); }",
        f"d._id = BinData(3, {js_string(guid2bin(new_guid))});",
    ]
    for k in dates:
        js.append(f"d.{k} = new Date(d.{k});")
    js.append("d.mappingId = NumberLong(0);")
    js.append("d.viewCount = I(0);")
    js.append("d.progress = { cohortId: BinData(3, 'AAAAAAAAAAAAAAAAAAAAAA=='), reportedAt: new Date('0001-01-01T00:00:00Z'), progressPercentage: '0', status: I(0) };")
    js.append("var r = c.cohortreport.insertOne(d);")
    js.append("print('INSERTED ' + JSON.stringify(r.insertedId));")
    return "\n".join(js)


# ---------------------------------------------------------------- saved reports SQL
STD_FOLDERS = {"home", "shared with me", "shared by me"}


def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        lines = [l.rstrip("\r\n") for l in f if l.strip()]
    if not lines:
        return rows
    header = lines[0].split("\t")
    for l in lines[1:]:
        rows.append(dict(zip(header, l.split("\t"))))
    return rows


def dq(name):
    return '"' + name.replace('"', '""') + '"'


def sql_lit(v, typ):
    if v is None:
        return "NULL"
    if typ in ("jsonb", "json"):
        tag = "$udc$"
        s = json.dumps(v) if not isinstance(v, str) else v
        assert tag not in s
        return f"{tag}{s}{tag}::{typ}"
    if typ == "boolean":
        return "TRUE" if v in (True, "t", "true", "True") else "FALSE"
    if typ in ("numeric", "integer", "bigint", "smallint", "double precision", "real"):
        return str(v)
    s = str(v).replace("'", "''")
    return f"'{s}'"


def folder_walk(folders, path=()):
    for f in folders or []:
        p = path + (f["Name"],)
        yield p, f
        yield from folder_walk(f.get("Subfolders") or [], p)


def reports_sql(args):
    opts = dict(zip(args[::2], args[1::2]))
    rows = [json.loads(r["row"]) for r in read_tsv(opts["--rows"])]
    cols = [tuple(c.split(":", 1)) for c in open(opts["--columns"], encoding="utf-8").read().split(",") if c.strip()]
    saved = read_tsv(opts["--saved"])
    src_folder_rows = read_tsv(opts["--src-folder"])
    tgt_folder_rows = read_tsv(opts["--tgt-folder"])
    manifest = json.load(open(opts["--manifest"], encoding="utf-8"))
    from_user, from_sub = opts["--from-user"], opts["--from-sub"].lower()
    to_user, to_sub = opts["--to-user"], opts["--to-sub"].lower()
    out = open(opts["--out"], "w", encoding="utf-8", newline="\n")

    def new_id_for(key, old, name):
        for e in manifest.setdefault(key, []):
            if e["old"].lower() == old.lower():
                return e["new"], False
        nid = str(uuid.uuid4())
        manifest[key].append({"old": old.lower(), "new": nid, "name": name})
        return nid, True

    # --- folders: source tree -> target tree (create missing customs, map ids)
    src_tree = json.loads(src_folder_rows[0]["Folders"]) if src_folder_rows else []
    if tgt_folder_rows:
        tgt_row_id = tgt_folder_rows[0]["Id"]
        tgt_tree = json.loads(tgt_folder_rows[0]["Folders"])
        tgt_created = False
    else:
        tgt_row_id = str(uuid.uuid4())
        tgt_tree = [{"Id": str(uuid.uuid4()), "Name": "Home", "Subfolders": [
            {"Id": str(uuid.uuid4()), "Name": "Shared with me", "Subfolders": []},
            {"Id": str(uuid.uuid4()), "Name": "Shared by me", "Subfolders": []}]}]
        tgt_created = True
    src_home = src_tree[0] if src_tree else None
    tgt_home = tgt_tree[0]
    assert tgt_home["Name"].lower() == "home", "target Folders[0] is not Home"
    folder_map = {}
    if src_home:
        folder_map[src_home["Id"].lower()] = tgt_home["Id"]
    # standard subfolders by name
    for s in (src_home or {}).get("Subfolders") or []:
        if s["Name"].lower() in STD_FOLDERS:
            for t in tgt_home.get("Subfolders") or []:
                if t["Name"].lower() == s["Name"].lower():
                    folder_map[s["Id"].lower()] = t["Id"]
    # customs: same path under the target, created when missing (case-insensitive), appended AFTER index 1
    def ensure(parent_tgt, name):
        for sub in parent_tgt.setdefault("Subfolders", []):
            if sub["Name"].lower() == name.lower():
                return sub, False
        new = {"Id": str(uuid.uuid4()), "Name": name, "Subfolders": []}
        parent_tgt["Subfolders"].append(new)
        return new, True
    folders_created = []
    for path, f in folder_walk(src_tree):
        if f["Id"].lower() in folder_map:
            continue
        if len(path) == 1:  # a second top-level folder beside Home -- unexpected, keep under Home
            parent_path = ()
        else:
            parent_path = path[:-1]
        # resolve the parent in the target by walking the mapped path
        parent = tgt_home
        for seg in parent_path[1:]:
            parent, _ = ensure(parent, seg)
        node, created = ensure(parent, f["Name"])
        folder_map[f["Id"].lower()] = node["Id"]
        if created:
            folders_created.append({"old": f["Id"].lower(), "new": node["Id"], "name": f["Name"], "path": "/".join(path)})
    manifest["folders"] = folders_created
    manifest["targetFolderCreated"] = tgt_created
    manifest["targetFolderRowId"] = tgt_row_id

    # --- reports
    skipped = []
    plan = []
    for r in rows:
        if r.get("IsDeleted") in (True, "t"):
            skipped.append((r["Name"], "deleted")); continue
        if (r.get("BasedOn") or "") == "client-loan-data":
            skipped.append((r["Name"], "client-loan-data (another company's loan data)")); continue
        nid, _ = new_id_for("reports", r["Id"], r["Name"])
        plan.append((r, nid))
    pairs = id_pairs(manifest)

    out.write("BEGIN;\n")
    out.write("CREATE TEMP TABLE udc_expect(what text, n int);\n")
    if tgt_created:
        out.write(f'INSERT INTO "UserFolder" ("Id","UserUid","Folders") VALUES ({sql_lit(tgt_row_id,"uuid")}, {sql_lit(to_sub,"uuid")}, {sql_lit(tgt_tree,"jsonb")});\n')
    else:
        out.write(f'UPDATE "UserFolder" SET "Folders" = {sql_lit(tgt_tree,"jsonb")} WHERE "Id" = {sql_lit(tgt_row_id,"uuid")} AND "UserUid" = {sql_lit(to_sub,"uuid")};\n')
    colnames = [c for c, _ in cols]
    coltypes = dict(cols)
    for r, nid in plan:
        row = dict(r)
        row["Id"] = nid
        row["OwnedBy"] = to_user
        row["IsShared"] = False
        row["SharedOrgUuid"] = None
        row["LastOpened"] = None
        row["OpenedTally"] = None
        row["MonthlyDownloadsActivated"] = False
        row["IsDeleted"] = False
        for jcol in ("Report", "Query", "TemplateFields"):
            if row.get(jcol) is not None:
                v = rewrite_owner(row[jcol], from_user, to_user)
                if jcol == "Report" and isinstance(v, dict) and "Id" in v:
                    v["Id"] = nid
                if jcol == "Report" and isinstance(v, dict) and "IsShared" in v:
                    v["IsShared"] = False
                text = rewrite_text(json.dumps(v), pairs + [(r["Id"].lower(), nid)])
                row[jcol] = json.loads(text)
        vals = []
        for c in colnames:
            if c not in row:
                raise SystemExit(f"column {c} missing from the selected row -- select with row_to_json(u) over the full table")
            vals.append(sql_lit(row[c], coltypes[c]))
        out.write(f'INSERT INTO "UserReport" ({", ".join(dq(c) for c in colnames)}) VALUES ({", ".join(vals)});\n')
        # saved rows: the source's own Home/custom rows -> mapped folders; none -> Home
        own = [s for s in saved if s["ReportUuid"].lower() == r["Id"].lower() and s["UserUid"].lower() == from_sub]
        targets = []
        for s in own:
            fid = s["UserFolderId"].lower()
            name = next((p[-1] for p, f in folder_walk(src_tree) if f["Id"].lower() == fid), None)
            if name and name.lower() in ("shared with me", "shared by me"):
                continue
            targets.append(folder_map.get(fid, tgt_home["Id"]))
        if not targets:
            targets = [tgt_home["Id"]]
        for t in dict.fromkeys(targets):
            out.write(f'INSERT INTO "UserSavedReport" ("Id","UserUid","ReportUuid","UserFolderId") VALUES ({sql_lit(str(uuid.uuid4()),"uuid")}, {sql_lit(to_sub,"uuid")}, {sql_lit(nid,"uuid")}, {sql_lit(t,"uuid")});\n')
    out.write(f"INSERT INTO udc_expect VALUES ('reports', {len(plan)});\n")
    out.write(f"""DO $do$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM "UserReport" WHERE "OwnedBy" = {sql_lit(to_user,'text')} AND "Id" IN ({", ".join(sql_lit(nid,'uuid') for _, nid in plan) or "NULL"});
  IF n <> {len(plan)} THEN RAISE EXCEPTION 'expected {len(plan)} copied UserReport rows, found %', n; END IF;
  SELECT count(*) INTO n FROM "UserFolder" WHERE "UserUid" = {sql_lit(to_sub,'uuid')};
  IF n <> 1 THEN RAISE EXCEPTION 'target must have exactly one UserFolder row, found %', n; END IF;
END $do$;
""")
    out.write("COMMIT;\n")
    out.close()
    json.dump(manifest, open(opts["--manifest"], "w", encoding="utf-8"), indent=1)
    print(f"reports planned: {len(plan)}; skipped: {len(skipped)}; folders created: {len(folders_created)}; target folder row {'CREATED' if tgt_created else 'updated'}")
    for name, why in skipped:
        print(f"  skip  {name}  ({why})")
    return 0


# ---------------------------------------------------------------- OWNER SWITCH (move, not copy)
# A move keeps every id: rows/docs change owner in place. Postgres statements are generated from a
# move-snapshot.sh directory; Mongo gets one updateOne per doc (by _id AND current user).
VOLATILE_REPORT = {"LastOpened", "OpenedTally"}
VOLATILE_MONGO = {"lastViewed", "viewCount", "reportViewCount", "lastReportViewed", "curveSearchCount", "lastCurveSearch"}


def parse_opts(args):
    """--key value pairs; bare --flags are left to the caller ('--flag' in args)."""
    opts, i = {}, 0
    while i < len(args):
        a = args[i]
        if a.startswith("--") and i + 1 < len(args) and not args[i + 1].startswith("--"):
            opts[a] = args[i + 1]; i += 2
        else:
            i += 1
    return opts


def load_jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line:
            out.append(json.loads(line))
    return out


def snap(d):
    return {
        "reports": load_jsonl(os.path.join(d, "reports.jsonl")),
        "saved": read_tsv(os.path.join(d, "saved.tsv")),
        "folder": read_tsv(os.path.join(d, "folder.tsv")),
        "bands": load_jsonl(os.path.join(d, "bands.jsonl")),
        "bandshares": read_tsv(os.path.join(d, "bandshares.tsv")),
        "cohort": load_jsonl(os.path.join(d, "cohort.jsonl")),
        "cohortreport": load_jsonl(os.path.join(d, "cohortreport.jsonl")),
        "shared-cohort": load_jsonl(os.path.join(d, "shared-cohort.jsonl")),
        "shared-cohortreport": load_jsonl(os.path.join(d, "shared-cohortreport.jsonl")),
    }


def move_sql(args):
    """UPDATE statements for the reports DB (UserReport owner + owner strings in the JSON columns,
    UserSavedReport sub + folder remap, target UserFolder tree merged) and the export DB (DynamicColumn
    UserName, optional ShareDynamicColumn re-point). Writes <out>.reports.sql / <out>.export.sql and
    fills the manifest (ids only -- the before-rows live in the snapshot dir)."""
    opts = parse_opts(args)
    shares = "--include-received-shares" in args
    src, tgt = snap(opts["--src"]), snap(opts["--tgt"])
    manifest = json.load(open(opts["--manifest"], encoding="utf-8"))
    from_user, from_sub = opts["--from-user"], opts["--from-sub"].lower()
    to_user, to_sub = opts["--to-user"], opts["--to-sub"].lower()
    out_base = opts["--out"]

    # --- target folder tree: keep the target's row, merge the source's custom folders into it
    src_tree = json.loads(src["folder"][0]["Folders"]) if src["folder"] else []
    if tgt["folder"]:
        tgt_row_id, tgt_tree, tgt_created = tgt["folder"][0]["Id"], json.loads(tgt["folder"][0]["Folders"]), False
    else:
        tgt_row_id, tgt_created = str(uuid.uuid4()), True
        tgt_tree = [{"Id": str(uuid.uuid4()), "Name": "Home", "Subfolders": [
            {"Id": str(uuid.uuid4()), "Name": "Shared with me", "Subfolders": []},
            {"Id": str(uuid.uuid4()), "Name": "Shared by me", "Subfolders": []}]}]
    tgt_before = json.dumps(tgt_tree)
    tgt_home = tgt_tree[0]
    assert tgt_home["Name"].lower() == "home", "target Folders[0] is not Home"
    src_home = src_tree[0] if src_tree else None
    folder_map = {}
    if src_home:
        folder_map[src_home["Id"].lower()] = tgt_home["Id"]
        for s in src_home.get("Subfolders") or []:
            if s["Name"].lower() in STD_FOLDERS:
                for t in tgt_home.get("Subfolders") or []:
                    if t["Name"].lower() == s["Name"].lower():
                        folder_map[s["Id"].lower()] = t["Id"]

    def ensure(parent_tgt, name):
        for sub in parent_tgt.setdefault("Subfolders", []):
            if sub["Name"].lower() == name.lower():
                return sub, False
        new = {"Id": str(uuid.uuid4()), "Name": name, "Subfolders": []}
        parent_tgt["Subfolders"].append(new)
        return new, True
    folders_created = []
    for path, f in folder_walk(src_tree):
        if f["Id"].lower() in folder_map:
            continue
        parent = tgt_home
        for seg in (path[:-1])[1:]:
            parent, _ = ensure(parent, seg)
        node, created = ensure(parent, f["Name"])
        folder_map[f["Id"].lower()] = node["Id"]
        if created:
            folders_created.append({"old": f["Id"].lower(), "new": node["Id"], "name": f["Name"], "path": "/".join(path)})
    std_shared_with_me = next((t["Id"] for t in tgt_home.get("Subfolders") or [] if t["Name"].lower() == "shared with me"), tgt_home["Id"])

    # --- reports: every row the source owns, except another company's loan data
    moved, skipped = [], []
    for r in src["reports"]:
        if (r.get("BasedOn") or "") == "client-loan-data":
            skipped.append({"id": r["Id"].lower(), "name": r.get("Name"), "why": "client-loan-data (another company's loan data)"}); continue
        moved.append(r)
    moved_ids = {r["Id"].lower() for r in moved}

    rep = open(out_base + ".reports.sql", "w", encoding="utf-8", newline="\n")
    rep.write("BEGIN;\n")
    if tgt_created:
        rep.write(f'INSERT INTO "UserFolder" ("Id","UserUid","Folders") VALUES ({sql_lit(tgt_row_id,"uuid")}, {sql_lit(to_sub,"uuid")}, {sql_lit(tgt_tree,"jsonb")});\n')
    elif json.dumps(tgt_tree) != tgt_before:
        rep.write(f'UPDATE "UserFolder" SET "Folders" = {sql_lit(tgt_tree,"jsonb")} WHERE "Id" = {sql_lit(tgt_row_id,"uuid")} AND "UserUid" = {sql_lit(to_sub,"uuid")};\n')
    for r in moved:
        sets = [f'"OwnedBy" = {sql_lit(to_user,"text")}']
        for jcol in ("Report", "Query", "TemplateFields"):
            if r.get(jcol) is not None:
                v = rewrite_owner(r[jcol], from_user, to_user)
                if v != r[jcol]:
                    sets.append(f'{dq(jcol)} = {sql_lit(v,"jsonb")}')
        rep.write(f'UPDATE "UserReport" SET {", ".join(sets)} WHERE "Id" = {sql_lit(r["Id"],"uuid")} AND "OwnedBy" = {sql_lit(from_user,"text")};\n')
    # --- saved rows: own reports always; rows for others' reports (received shares) only when asked
    saved_rows, saved_skipped = [], []
    for s in src["saved"]:
        rid = s["ReportUuid"].lower()
        own = rid in moved_ids
        if not own and not shares:
            saved_skipped.append({"id": s["Id"].lower(), "reportUuid": rid, "why": "received share (not requested)" if s.get("OwnedBy") else "report row missing"}); continue
        if not own and any(k["id"] == rid for k in skipped):
            saved_skipped.append({"id": s["Id"].lower(), "reportUuid": rid, "why": "client-loan-data report stays"}); continue
        fid = s["UserFolderId"].lower()
        new_fid = folder_map.get(fid) if own else std_shared_with_me
        if new_fid is None:
            new_fid = tgt_home["Id"]
        saved_rows.append({"id": s["Id"].lower(), "reportUuid": rid, "oldFolderId": fid, "newFolderId": new_fid, "received": not own})
        rep.write(f'UPDATE "UserSavedReport" SET "UserUid" = {sql_lit(to_sub,"uuid")}, "UserFolderId" = {sql_lit(new_fid,"uuid")} WHERE "Id" = {sql_lit(s["Id"],"uuid")} AND "UserUid" = {sql_lit(from_sub,"uuid")};\n')
    rep.write(f"""DO $do$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM "UserReport" WHERE "OwnedBy" = {sql_lit(to_user,'text')} AND "Id" IN ({", ".join(sql_lit(i,'uuid') for i in moved_ids) or "NULL"});
  IF n <> {len(moved_ids)} THEN RAISE EXCEPTION 'expected {len(moved_ids)} UserReport rows owned by target, found %', n; END IF;
  SELECT count(*) INTO n FROM "UserReport" WHERE "OwnedBy" = {sql_lit(from_user,'text')} AND "Id" IN ({", ".join(sql_lit(i,'uuid') for i in moved_ids) or "NULL"});
  IF n <> 0 THEN RAISE EXCEPTION 'source still owns % moved reports', n; END IF;
  SELECT count(*) INTO n FROM "UserSavedReport" WHERE "UserUid" = {sql_lit(to_sub,'uuid')} AND "Id" IN ({", ".join(sql_lit(s['id'],'uuid') for s in saved_rows) or "NULL"});
  IF n <> {len(saved_rows)} THEN RAISE EXCEPTION 'expected {len(saved_rows)} saved rows under target, found %', n; END IF;
  SELECT count(*) INTO n FROM "UserFolder" WHERE "UserUid" = {sql_lit(to_sub,'uuid')};
  IF n <> 1 THEN RAISE EXCEPTION 'target must have exactly one UserFolder row, found %', n; END IF;
END $do$;
COMMIT;
""")
    rep.close()

    # --- export DB: bands (all rows incl. deleted), optional received band shares
    bands = [{"old": b["Id"].lower(), "new": b["Id"].lower(), "name": b.get("Name"), "deleted": b.get("IsDeleted") in (True, "t")} for b in src["bands"]]
    band_shares = [{"id": s["Id"], "columnId": s["ColumnId"].lower()} for s in src["bandshares"]] if shares else []
    exp = open(out_base + ".export.sql", "w", encoding="utf-8", newline="\n")
    exp.write("BEGIN;\n")
    for b in bands:
        exp.write(f'UPDATE "DynamicColumn" SET "UserName" = {sql_lit(to_user,"text")} WHERE "Id" = {sql_lit(b["old"],"uuid")} AND "UserName" = {sql_lit(from_user,"text")};\n')
    for s in band_shares:
        exp.write(f'UPDATE "ShareDynamicColumn" SET "SharedWithId" = {sql_lit(to_sub,"uuid")} WHERE "Id" = {s["id"]} AND "SharedWithId" = {sql_lit(from_sub,"uuid")};\n')
    exp.write(f"""DO $do$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM "DynamicColumn" WHERE "UserName" = {sql_lit(to_user,'text')} AND "Id" IN ({", ".join(sql_lit(b['old'],'uuid') for b in bands) or "NULL"});
  IF n <> {len(bands)} THEN RAISE EXCEPTION 'expected {len(bands)} bands owned by target, found %', n; END IF;
END $do$;
COMMIT;
""")
    exp.close()

    def st(doc):
        p = doc.get("progress") or {}
        return p.get("status") if isinstance(p, dict) else None
    cohorts = [{"old": mongo_id(d["_id"]), "new": mongo_id(d["_id"]), "name": d.get("name"), "type": d.get("type"),
                "status": st(d), "deleted": bool(d.get("isDeleted")), "flipped": not d.get("isDeleted")} for d in src["cohort"]]
    cohort_reports = [{"old": mongo_id(d["_id"]), "new": mongo_id(d["_id"]), "name": d.get("name"), "deleted": bool(d.get("isDeleted"))} for d in src["cohortreport"]]
    manifest.update({
        "mode": "move",
        "cohorts": cohorts, "cohortReports": cohort_reports,
        "sharedCohorts": [mongo_id(d["_id"]) for d in src["shared-cohort"]] if shares else [],
        "sharedCohortReports": [mongo_id(d["_id"]) for d in src["shared-cohortreport"]] if shares else [],
        "reports": [{"old": r["Id"].lower(), "new": r["Id"].lower(), "name": r.get("Name"), "deleted": r.get("IsDeleted") in (True, "t")} for r in moved],
        "skippedReports": skipped,
        "savedRows": saved_rows, "skippedSavedRows": saved_skipped,
        "folders": folders_created,
        "targetFolder": {"rowId": tgt_row_id, "created": tgt_created, "before": None if tgt_created else json.loads(tgt_before)},
        "bands": bands, "bandShares": band_shares,
        "includeReceivedShares": shares,
    })
    json.dump(manifest, open(opts["--manifest"], "w", encoding="utf-8"), indent=1)
    live = sum(1 for r in moved if r.get("IsDeleted") not in (True, "t"))
    print(f"move plan: reports {len(moved)} ({live} live), skipped {len(skipped)}; saved rows {len(saved_rows)} (skipped {len(saved_skipped)}); folders to create {len(folders_created)}; bands {len(bands)}; band shares {len(band_shares)}; target folder row {'CREATED' if tgt_created else 'kept'}; cohorts {len(cohorts)} ({sum(1 for c in cohorts if c['flipped'])} live); cohort reports {len(cohort_reports)} ({sum(1 for c in cohort_reports if not c['deleted'])} live)")
    for k in skipped:
        print(f"  skip report  {k['name']}  ({k['why']})")
    return 0


def mongo_move_js(args):
    """One updateOne per document (by _id AND current owner) flipping every top-level owner key
    that equals the source user; sharedWith entries re-pointed only with --include-received-shares.
    Prints JS for docdb-query.sh. Args: <snapshot-dir> <collection> <from> <to> [--include-received-shares] [--reverse]"""
    d, col, from_user, to_user = args[0], args[1], args[2], args[3]
    shares = "--include-received-shares" in args
    reverse = "--reverse" in args
    # the snapshot holds the PRE-MOVE docs: owner keys equal the original source user. Decide the
    # touched docs/keys from that, then swap direction for a reverse (match on target, set source).
    docs = load_jsonl(os.path.join(d, f"{col}.jsonl"))
    orig_from = from_user
    if reverse:
        from_user, to_user = to_user, from_user
    ops = []
    for doc in docs:
        keys = [k for k, v in doc.items() if k in OWNER_KEYS and v == orig_from]
        if not keys:
            continue
        ops.append({"id": guid2bin(mongo_id(doc["_id"])), "set": {k: to_user for k in keys}})
    shared = []
    if shares:
        for doc in load_jsonl(os.path.join(d, f"shared-{col}.jsonl")):
            shared.append(guid2bin(mongo_id(doc["_id"])))
    # Chunked: one shell call per <=CHUNK ops, separated by a '//CHUNK' line. A single call carrying
    # 144 ops to the production legacy shell returned NO output after ~7 min (67 had applied) -- the
    # callers sum the per-chunk counts and treat a silent chunk as "unknown, re-run" (idempotent).
    chunk = 40
    for a in args:
        if a.startswith("--chunk="):
            chunk = int(a.split("=", 1)[1])
    scripts = []
    for i in range(0, max(len(ops), 1), chunk):
        part = ops[i:i + chunk]
        js = ["var c = db.getSiblingDB('cohort');", f"var ops = {json.dumps(part)};", "var m = 0, mod = 0;",
              f"ops.forEach(function(o) {{ var r = c.{col}.updateOne({{_id: BinData(3, o.id), user: {json.dumps(from_user)}}}, {{$set: o.set}}); m += r.matchedCount; mod += r.modifiedCount; }});",
              f"print('OWNER matched ' + m + ' modified ' + mod + ' of ' + ops.length);"]
        scripts.append("\n".join(js))
    if shared:
        js = ["var c = db.getSiblingDB('cohort');", f"var sh = {json.dumps(shared)}; var sm = 0;",
              f"sh.forEach(function(id) {{ var r = c.{col}.updateOne({{_id: BinData(3, id), sharedWith: {json.dumps(from_user)}}}, {{$set: {{'sharedWith.$': {json.dumps(to_user)}}}}}); sm += r.matchedCount; }});",
              "print('SHARED matched ' + sm + ' of ' + sh.length);"]
        scripts.append("\n".join(js))
    print("\n//CHUNK\n".join(scripts))
    return 0


def _norm_report(r, from_user, to_user):
    r = {k: v for k, v in r.items() if k not in VOLATILE_REPORT}
    r["OwnedBy"] = to_user if r.get("OwnedBy") == from_user else r.get("OwnedBy")
    for jcol in ("Report", "Query", "TemplateFields"):
        if r.get(jcol) is not None:
            r[jcol] = rewrite_owner(r[jcol], from_user, to_user)
    return r


def _norm_mongo(d, from_user, to_user, shares):
    d = {k: v for k, v in d.items() if k not in VOLATILE_MONGO}
    d = {k: (to_user if (k in OWNER_KEYS and v == from_user) else v) for k, v in d.items()}
    if shares and isinstance(d.get("sharedWith"), list):
        d["sharedWith"] = [to_user if x == from_user else x for x in d["sharedWith"]]
    return d


def move_compare(args):
    """Item-by-item truth after a move (or after a rollback with --rolled-back).
    Args: --before-src D --before-tgt D --after-src D --after-tgt D --manifest M [--rolled-back]"""
    opts = parse_opts(args)
    rolled_back = "--rolled-back" in args
    m = json.load(open(opts["--manifest"], encoding="utf-8"))
    fu, tu = m["from"]["username"], m["to"]["username"]
    shares = bool(m.get("includeReceivedShares"))
    bs, bt, as_, at = snap(opts["--before-src"]), snap(opts["--before-tgt"]), snap(opts["--after-src"]), snap(opts["--after-tgt"])
    fails = []
    P = lambda ok, msg: (print(("PASS  " if ok else "FAIL  ") + msg), None if ok else fails.append(msg))
    moved_reports = {e["old"] for e in m["reports"]}
    moved_saved = {e["id"] for e in m["savedRows"]}
    moved_bands = {e["old"] for e in m["bands"]}
    mid = lambda doc: mongo_id(doc["_id"]).lower()
    if rolled_back:
        # the source must be byte-identical to before; the target must be byte-identical to before.
        # Exception: a report OPENED in between (LastOpened moved) has its TemplateFields re-saved by the
        # app on view -- a view side effect, not a move artefact; reported as INFO, not compared.
        viewed = 0
        for key in ("reports", "bands", "cohort", "cohortreport"):
            b = {(r["Id"] if "Id" in r else mid(r)).lower(): r for r in bs[key]}
            a = {(r["Id"] if "Id" in r else mid(r)).lower(): r for r in as_[key]}
            if key == "reports":
                for k in list(b):
                    if k in a and a[k].get("LastOpened") != b[k].get("LastOpened"):
                        viewed += 1; b[k] = {x: y for x, y in b[k].items() if x != "TemplateFields"}; a[k] = {x: y for x, y in a[k].items() if x != "TemplateFields"}
                b = {k: {x: y for x, y in v.items() if x not in VOLATILE_REPORT} for k, v in b.items()}; a = {k: {x: y for x, y in v.items() if x not in VOLATILE_REPORT} for k, v in a.items()}
                if viewed:
                    print(f"INFO  {viewed} report(s) were opened between snapshot and rollback (LastOpened/OpenedTally/TemplateFields re-saved by the app on view; excluded)")
            if key in ("cohort", "cohortreport"):
                b = {k: {x: y for x, y in v.items() if x not in VOLATILE_MONGO} for k, v in b.items()}; a = {k: {x: y for x, y in v.items() if x not in VOLATILE_MONGO} for k, v in a.items()}
            P(b == a, f"source {key}: {len(a)} after == {len(b)} before, content identical" if b == a else f"source {key}: differs ({len(b)} before, {len(a)} after; {sum(1 for k in b if b[k] != a.get(k))} changed)")
        P([(s["Id"], s["UserFolderId"], s["ReportUuid"]) for s in bs["saved"]] == [(s["Id"], s["UserFolderId"], s["ReportUuid"]) for s in as_["saved"]], f"source saved rows identical ({len(as_['saved'])})")
        P(bs["folder"] == as_["folder"], "source folder row identical")
        P(bt["folder"] == at["folder"], f"target folder row back to before ({'none' if not bt['folder'] else 'same tree'})")
        for key in ("reports", "bands", "cohort", "cohortreport"):
            b = {(r["Id"] if "Id" in r else mid(r)).lower() for r in bt[key]}; a = {(r["Id"] if "Id" in r else mid(r)).lower() for r in at[key]}
            P(b == a, f"target {key}: same {len(a)} items as before")
        P({s["Id"] for s in bt["saved"]} == {s["Id"] for s in at["saved"]}, f"target saved rows back to before ({len(at['saved'])})")
        print(f"move-compare: {'ALL PASS' if not fails else str(len(fails)) + ' FAIL(S)'}")
        return 1 if fails else 0

    # ---- after the move
    after_t_reports = {r["Id"].lower(): r for r in at["reports"]}
    after_s_reports = {r["Id"].lower(): r for r in as_["reports"]}
    bad = 0
    for r in bs["reports"]:
        rid = r["Id"].lower()
        if rid not in moved_reports:
            P(rid in after_s_reports, f"skipped report {r.get('Name')!r} still with source"); continue
        a = after_t_reports.get(rid)
        if a is None:
            bad += 1; print(f"  MISSING on target: report {r.get('Name')!r} {rid}"); continue
        if _norm_report(r, fu, tu) != {k: v for k, v in a.items() if k not in VOLATILE_REPORT}:
            bad += 1; print(f"  CONTENT DIFFERS: report {r.get('Name')!r} {rid}")
        if rid in after_s_reports:
            bad += 1; print(f"  STILL ON SOURCE: report {r.get('Name')!r}")
    P(bad == 0, f"reports: {len(moved_reports)} moved, content identical apart from owner strings")
    # target's own reports untouched
    bt_reports = {r["Id"].lower(): r for r in bt["reports"]}
    same = all(after_t_reports.get(k) is not None and {x: y for x, y in after_t_reports[k].items() if x not in VOLATILE_REPORT} == {x: y for x, y in v.items() if x not in VOLATILE_REPORT} for k, v in bt_reports.items())
    P(same, f"target's own {len(bt_reports)} reports unchanged")
    # saved rows
    at_saved = {s["Id"].lower(): s for s in at["saved"]}
    as_saved = {s["Id"].lower(): s for s in as_["saved"]}
    ok = True
    tgt_tree = json.loads(at["folder"][0]["Folders"]) if at["folder"] else []
    tgt_folder_ids = {f["Id"].lower() for _, f in folder_walk(tgt_tree)}
    for e in m["savedRows"]:
        a = at_saved.get(e["id"])
        if a is None or a["UserFolderId"].lower() != e["newFolderId"].lower() or e["id"] in as_saved or a["UserFolderId"].lower() not in tgt_folder_ids:
            ok = False; print(f"  saved row {e['id']} wrong: {a}")
    P(ok, f"saved rows: {len(moved_saved)} under target in folders that exist in its tree")
    P({s["Id"].lower() for s in bt["saved"]} <= set(at_saved), f"target's own {len(bt['saved'])} saved rows still present")
    P(bs["folder"] == as_["folder"], "source folder row untouched")
    bt_tree = json.loads(bt["folder"][0]["Folders"]) if bt["folder"] else []
    P({f["Id"].lower() for _, f in folder_walk(bt_tree)} <= tgt_folder_ids, "target folder tree kept every folder it had")
    # bands
    at_bands = {b["Id"].lower(): b for b in at["bands"]}; as_bands = {b["Id"].lower(): b for b in as_["bands"]}
    bad = 0
    for b in bs["bands"]:
        bid = b["Id"].lower(); a = at_bands.get(bid)
        nb = dict(b); nb["UserName"] = tu
        if a is None or a != nb or bid in as_bands:
            bad += 1; print(f"  band {b.get('Name')!r} {bid}: {'missing' if a is None else 'differs or still on source'}")
    P(bad == 0, f"bands: {len(moved_bands)} moved, content identical apart from UserName")
    P({b["Id"].lower() for b in bt["bands"]} <= set(at_bands), f"target's own {len(bt['bands'])} bands still present")
    # mongo
    for col in ("cohort", "cohortreport"):
        before = {mid(d): d for d in bs[col]}
        after_t = {mid(d): d for d in at[col]}; after_s = {mid(d): d for d in as_[col]}
        bad = 0
        for k, d in before.items():
            a = after_t.get(k)
            if a is None or _norm_mongo(d, fu, tu, False) != {x: y for x, y in a.items() if x not in VOLATILE_MONGO} or k in after_s:
                bad += 1; print(f"  {col} {d.get('name')!r} {k}: {'missing on target' if a is None else ('still on source' if k in after_s else 'content differs')}")
        P(bad == 0, f"{col}: {len(before)} moved (incl. deleted), content identical apart from user")
        P({mid(d) for d in bt[col]} <= set(after_t), f"target's own {len(bt[col])} {col} docs still present")
        if shares:
            sb = {mid(d) for d in bs[f"shared-{col}"]}; sa = {mid(d) for d in at[f"shared-{col}"]}
            P(sb <= sa, f"{col}: {len(sb)} received shares now name the target")
    print(f"move-compare: {'ALL PASS' if not fails else str(len(fails)) + ' FAIL(S)'}")
    return 1 if fails else 0


def move_rollback_sql(args):
    """Restore the pre-move rows from the before-source snapshot. Args: --before-src D --manifest M --out BASE"""
    opts = parse_opts(args)
    m = json.load(open(opts["--manifest"], encoding="utf-8"))
    bs = snap(opts["--before-src"])
    fu, fs = m["from"]["username"], m["from"]["sub"].lower()
    tu, ts = m["to"]["username"], m["to"]["sub"].lower()
    moved = {e["old"] for e in m["reports"]}
    rep = open(opts["--out"] + ".reports.sql", "w", encoding="utf-8", newline="\n")
    rep.write("BEGIN;\n")
    for r in bs["reports"]:
        if r["Id"].lower() not in moved:
            continue
        sets = [f'"OwnedBy" = {sql_lit(fu,"text")}'] + [f'{dq(j)} = {sql_lit(r[j],"jsonb")}' for j in ("Report", "Query", "TemplateFields") if r.get(j) is not None]
        rep.write(f'UPDATE "UserReport" SET {", ".join(sets)} WHERE "Id" = {sql_lit(r["Id"],"uuid")} AND "OwnedBy" = {sql_lit(tu,"text")};\n')
    for e in m["savedRows"]:
        rep.write(f'UPDATE "UserSavedReport" SET "UserUid" = {sql_lit(fs,"uuid")}, "UserFolderId" = {sql_lit(e["oldFolderId"],"uuid")} WHERE "Id" = {sql_lit(e["id"],"uuid")} AND "UserUid" = {sql_lit(ts,"uuid")};\n')
    tf = m["targetFolder"]
    if tf["created"]:
        rep.write(f'DELETE FROM "UserFolder" WHERE "Id" = {sql_lit(tf["rowId"],"uuid")} AND "UserUid" = {sql_lit(ts,"uuid")};\n')
    elif tf.get("before") is not None:
        rep.write(f'UPDATE "UserFolder" SET "Folders" = {sql_lit(tf["before"],"jsonb")} WHERE "Id" = {sql_lit(tf["rowId"],"uuid")} AND "UserUid" = {sql_lit(ts,"uuid")};\n')
    rep.write(f"""DO $do$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM "UserReport" WHERE "OwnedBy" = {sql_lit(fu,'text')} AND "Id" IN ({", ".join(sql_lit(i,'uuid') for i in moved) or "NULL"});
  IF n <> {len(moved)} THEN RAISE EXCEPTION 'expected {len(moved)} reports back with source, found %', n; END IF;
END $do$;
COMMIT;
""")
    rep.close()
    exp = open(opts["--out"] + ".export.sql", "w", encoding="utf-8", newline="\n")
    exp.write("BEGIN;\n")
    for b in m["bands"]:
        exp.write(f'UPDATE "DynamicColumn" SET "UserName" = {sql_lit(fu,"text")} WHERE "Id" = {sql_lit(b["old"],"uuid")} AND "UserName" = {sql_lit(tu,"text")};\n')
    for s in m.get("bandShares") or []:
        exp.write(f'UPDATE "ShareDynamicColumn" SET "SharedWithId" = {sql_lit(fs,"uuid")} WHERE "Id" = {s["id"]} AND "SharedWithId" = {sql_lit(ts,"uuid")};\n')
    exp.write("COMMIT;\n")
    exp.close()
    print(f"rollback plan: {len(moved)} reports, {len(m['savedRows'])} saved rows, folder {'delete' if tf['created'] else 'restore'}, {len(m['bands'])} bands, {len(m.get('bandShares') or [])} band shares")
    return 0


def main(argv):
    if not argv:
        print(__doc__); return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "move-sql":
        return move_sql(rest)
    if cmd == "mongo-move-js":
        return mongo_move_js(rest)
    if cmd == "move-compare":
        return move_compare(rest)
    if cmd == "move-rollback-sql":
        return move_rollback_sql(rest)
    if cmd == "newid":
        print(uuid.uuid4()); return 0
    if cmd == "guid2bin":
        print(guid2bin(rest[0])); return 0
    if cmd == "bin2guid":
        print(bin2guid(rest[0])); return 0
    if cmd == "mongo-id":
        print(mongo_id(rest[0])); return 0
    if cmd == "cohort-report-js":
        print(cohort_report_js(*rest)); return 0
    if cmd == "reports-sql":
        return reports_sql(rest)
    if cmd == "check-no-source-ids":
        return check_no_source_ids(rest[0], json.load(open(rest[1], encoding="utf-8")), rest[2])
    print(f"unknown subcommand {cmd}", file=sys.stderr); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
