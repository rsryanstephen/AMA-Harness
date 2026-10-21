#!/usr/bin/env python
"""Index every tfstate listed in sweep-states.txt into state-index.tsv (ids/arns/names only) + state-meta.tsv.
Each state is fetched (read-only GetObject) to a short temp path, parsed, and DELETED immediately: state files hold
plaintext secrets, nothing secret-bearing persists. Resumable: keys already indexed OK in state-meta.tsv are skipped.
Handles state format v4 (TF >= 0.12) and v3 (TF 0.11 and earlier)."""
import csv, json, os, subprocess, sys, tempfile
S = os.path.dirname(os.path.abspath(__file__))
lst = os.path.join(S, "sweep-states.txt")
IDX = os.path.join(S, "state-index.tsv"); META = os.path.join(S, "state-meta.tsv")
done = set(); prev_meta = []; prev_idx = []
if os.path.exists(META):
    for row in csv.reader(open(META, encoding="utf-8", newline=""), delimiter="\t"):
        if row and row[0] != "bucket" and (len(row) < 7 or not row[6]):
            done.add((row[0], row[1])); prev_meta.append(row)
    if os.path.exists(IDX):
        for row in csv.reader(open(IDX, encoding="utf-8", newline=""), delimiter="\t"):
            if row and row[0] != "bucket" and (row[0], row[1]) in done: prev_idx.append(row)
idx = open(IDX, "w", newline="", encoding="utf-8"); w = csv.writer(idx, delimiter="\t", lineterminator="\n")
w.writerow(["bucket","key","last_modified","tf_version","serial","type","name","module","id","arn","name_attr"]); w.writerows(prev_idx)
meta = open(META, "w", newline="", encoding="utf-8"); mw = csv.writer(meta, delimiter="\t", lineterminator="\n")
mw.writerow(["bucket","key","last_modified","tf_version","serial","resources","note"]); mw.writerows(prev_meta)
def pick(a, k):
    v = a.get(k) if isinstance(a, dict) else None
    v = "" if v is None else (v if isinstance(v, str) else json.dumps(v))
    if k == "id" and v.startswith(("AKIA", "ASIA")) and len(v) == 20:
        v = v[:4] + "..." + v[-4:]  # IAM access key id: enough to match, never the full id
    return v
tmpdir = tempfile.mkdtemp(prefix="tfs", dir="C:/tfd" if os.path.isdir("C:/tfd") else None)
n = 0; fails = 0
for line in open(lst, encoding="utf-8"):
    parts = line.rstrip("\r\n").split("\t")
    if len(parts) < 4 or parts[1] in ("", "None"): continue
    bucket, key, size, lm = parts[0], parts[1], parts[2], parts[3]
    if (bucket, key) in done: continue
    local = os.path.join(tmpdir, "s.json")
    r = subprocess.run(["aws", "s3api", "get-object", "--bucket", bucket, "--key", key, local], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(local):
        fails += 1
        if fails <= 3: print("FAIL", bucket, key, "rc", r.returncode, (r.stderr or r.stdout).strip()[:300], flush=True)
        mw.writerow([bucket, key, lm, "", "", "", "download-failed: rc%s %s" % (r.returncode, (r.stderr or "").strip()[:120])]); continue
    try:
        with open(local, encoding="utf-8") as fh: st = json.load(fh)
    except Exception as e:
        mw.writerow([bucket, key, lm, "", "", "", "unparseable: " + str(e)[:100]]); os.remove(local); continue
    os.remove(local)
    tfv = st.get("terraform_version", ""); serial = st.get("serial", ""); cnt = 0
    if st.get("version") == 4:
        for res in st.get("resources", []):
            if res.get("mode") != "managed": continue
            for inst in res.get("instances", []):
                a = inst.get("attributes", {}) or {}
                w.writerow([bucket, key, lm, tfv, serial, res.get("type"), res.get("name"), res.get("module", ""), pick(a, "id"), pick(a, "arn"), pick(a, "name")]); cnt += 1
    else:
        for m in st.get("modules", []):
            mod = ".".join(m.get("path", [])[1:])
            for rname, res in (m.get("resources") or {}).items():
                if rname.startswith("data."): continue
                a = (res.get("primary") or {}).get("attributes", {}) or {}
                w.writerow([bucket, key, lm, tfv, serial, res.get("type"), rname.split(".", 1)[-1], mod, pick(a, "id"), pick(a, "arn"), pick(a, "name")]); cnt += 1
    mw.writerow([bucket, key, lm, tfv, serial, cnt, ""]); n += 1
    idx.flush(); meta.flush()
idx.close(); meta.close()
try: os.rmdir(tmpdir)
except OSError: pass
print("indexed", n, "new states,", len(done), "already done,", fails, "download failures")
