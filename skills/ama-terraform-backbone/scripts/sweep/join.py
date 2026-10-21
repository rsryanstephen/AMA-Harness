#!/usr/bin/env python
"""Join the AWS inventory (sweep/aws/*.json) against the Terraform state index (sweep/state-index.tsv).
Outputs (tab-separated, in sweep/):
  tracked.tsv   - AWS resource -> state(s) that manage it (bucket, key, last_modified, tf_version)
  untracked.tsv - AWS resources with NO matching state resource (candidate "no Terraform" findings)
  stale.tsv     - state resources (of inventoried types) with NO live AWS match (candidate dead state)
  summary.txt   - counts per type
Match keys: inventory id / arn / name vs state id / arn / name_attr, after light normalisation."""
import csv, glob, json, os, re, sys
S = os.path.dirname(os.path.abspath(__file__))
def norm(v):
    if not v: return ""
    v = v.strip()
    if v.startswith("/hostedzone/"): v = v[len("/hostedzone/"):]
    return v
# --- state index
state_by_key = {}; state_rows = []
for row in csv.DictReader(open(os.path.join(S, "state-index.tsv"), encoding="utf-8", newline=""), delimiter="\t"):
    state_rows.append(row)
    for k in ("id", "arn"):
        v = norm(row.get(k, ""))
        if v and len(v) >= 3:
            state_by_key.setdefault(v, []).append(row)
# name_attr only counts for types whose Terraform id is not the name (e.g. aws_lb arn vs name): index it separately
name_idx = {}
for row in state_rows:
    v = norm(row.get("name_attr", ""))
    if v: name_idx.setdefault((row["type"], v), []).append(row)
# --- inventory
inv = []
for f in sorted(glob.glob(os.path.join(S, "aws", "*.json"))):
    try: items = json.load(open(f, encoding="utf-8"))
    except Exception as e: print("bad json", f, e); continue
    g = os.path.basename(f)[:-5]
    for it in items:
        if isinstance(it, dict): it["_group"] = g; inv.append(it)
tracked = open(os.path.join(S, "tracked.tsv"), "w", encoding="utf-8", newline=""); tw = csv.writer(tracked, delimiter="\t", lineterminator="\n")
untracked = open(os.path.join(S, "untracked.tsv"), "w", encoding="utf-8", newline=""); uw = csv.writer(untracked, delimiter="\t", lineterminator="\n")
tw.writerow(["group","service","type","id","arn","name","state_bucket","state_key","state_last_modified","state_tf_version","state_type","state_name","matched_on"])
uw.writerow(["group","service","type","id","arn","name","tags","extra"])
seen_state = set(); counts = {}
for it in inv:
    t = it.get("type", ""); cid = norm(it.get("id", "")); carn = norm(it.get("arn", "")); cname = norm(it.get("name", ""))
    hits = []
    for key, how in ((cid, "id"), (carn, "arn")):
        if key and key in state_by_key:
            hits += [(r, how) for r in state_by_key[key]]
    if not hits and cname and (t, cname) in name_idx:
        hits = [(r, "name") for r in name_idx[(t, cname)]]
    if not hits and cid and (t, cid) in name_idx:
        hits = [(r, "name=id") for r in name_idx[(t, cid)]]
    c = counts.setdefault(t, [0, 0]); c[1] += 1
    if hits:
        c[0] += 1
        for r, how in hits:
            seen_state.add((r["bucket"], r["key"], r["type"], r["name"], r["module"]))
            tw.writerow([it["_group"], it.get("service",""), t, cid, carn, cname, r["bucket"], r["key"], r["last_modified"], r["tf_version"], r["type"], r["name"], how])
    else:
        uw.writerow([it["_group"], it.get("service",""), t, cid, carn, cname, json.dumps(it.get("tags", {}), sort_keys=True), json.dumps(it.get("extra", {}), sort_keys=True)])
tracked.close(); untracked.close()
inv_types = {it.get("type") for it in inv}
stale = open(os.path.join(S, "stale.tsv"), "w", encoding="utf-8", newline=""); sw = csv.writer(stale, delimiter="\t", lineterminator="\n")
sw.writerow(["bucket","key","last_modified","tf_version","type","name","module","id","arn"])
nstale = 0
for r in state_rows:
    if r["type"] not in inv_types: continue
    if (r["bucket"], r["key"], r["type"], r["name"], r["module"]) in seen_state: continue
    sw.writerow([r["bucket"], r["key"], r["last_modified"], r["tf_version"], r["type"], r["name"], r["module"], r["id"], r["arn"]]); nstale += 1
stale.close()
with open(os.path.join(S, "summary.txt"), "w", encoding="utf-8") as out:
    out.write("type\ttracked\ttotal\tuntracked\n")
    for t, (a, b) in sorted(counts.items(), key=lambda x: -(x[1][1]-x[1][0])):
        out.write(f"{t}\t{a}\t{b}\t{b-a}\n")
    out.write(f"\ninventory={len(inv)} tracked={sum(a for a,b in counts.values())} untracked={sum(b-a for a,b in counts.values())} stale_state_rows={nstale} state_rows={len(state_rows)}\n")
print(open(os.path.join(S, "summary.txt"), encoding="utf-8").read())
