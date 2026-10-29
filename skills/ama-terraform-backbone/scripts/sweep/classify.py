#!/usr/bin/env python
"""Classify every plan log in sweep/planlogs: per label -> plan summary, per-resource actions and changed attributes,
drift class. Writes sweep/drift.tsv (label, root, env, rc, summary, class, detail) and sweep/drift-resources.tsv
(label, action, address, changed_attrs). Classes: no-change | tags-only | error | create | destroy | replace | update:<attrs>."""
import csv, glob, os, re
S = os.path.dirname(os.path.abspath(__file__))
TAG_ATTRS = {"tags", "tags_all"}
def parse(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    summ = re.search(r"^(Plan: \d+ to add, \d+ to change, \d+ to destroy\.|No changes\. Infrastructure is up-to-date\.)", txt, re.M)
    err = re.search(r"^Error: (.*)", txt, re.M)
    res = []
    # resource blocks: "  # addr will be updated in-place" ... until blank line after closing "    }"
    for m in re.finditer(r"^  # (?P<addr>\S+) (?:will be|must be|is tainted, so must be) (?P<act>created|updated in-place|destroyed|replaced|read during apply)[^\n]*\n(?P<body>(?:^.*\n)*?)(?=^  # |\nPlan: |\Z)", txt, re.M):
        addr, act, body = m.group("addr"), m.group("act"), m.group("body")
        attrs = set()
        for a in re.finditer(r"^\s{6}[~+-] (?P<name>[A-Za-z0-9_]+)\s*(?:=|\{)", body, re.M):
            attrs.add(a.group("name"))
        # nested-block changes count under their block name (e.g. "~ ordered_cache_behavior")
        for a in re.finditer(r"^\s{6}[~+-] (?P<name>[A-Za-z0-9_]+) \{", body, re.M):
            attrs.add(a.group("name"))
        forces = re.search(r"# forces replacement", body)
        res.append((act, addr, sorted(attrs), bool(forces)))
    return summ.group(1) if summ else "", err.group(1)[:160] if err else "", res
def classify(summ, err, res, rc):
    if err or rc not in (0, "0"): return "error", err or "rc=%s" % rc
    if summ.startswith("No changes"): return "no-change", ""
    acts = {a for a, _, _, _ in res}
    if "destroyed" in acts or any(f for _, _, _, f in res): return ("destroy" if "destroyed" in acts else "replace"), "; ".join(f"{a}:{ad}" for a, ad, _, _ in res if a == "destroyed" or _)
    if "created" in acts: return "create", "; ".join(ad for a, ad, _, _ in res if a == "created")
    allattrs = set().union(*[set(at) for _, _, at, _ in res]) if res else set()
    if res and allattrs and allattrs <= TAG_ATTRS: return "tags-only", f"{len(res)} resources"
    return "update", ", ".join(sorted(allattrs - TAG_ATTRS))[:200]
idx = {}
for row in csv.reader(open(os.path.join(S, "render-index.tsv"), encoding="utf-8", newline=""), delimiter="\t"):
    if len(row) >= 4: idx[row[0]] = (row[1], row[3])
rcs = {}
for rf in sorted(glob.glob(os.path.join(S, "planlogs", "results*.txt")), key=os.path.getmtime):  # later runs win
    for line in open(rf, encoding="utf-8", errors="replace"):
        m = re.match(r"(\S+) rc=(\S+)", line)
        if m: rcs[m.group(1)] = m.group(2)
out = open(os.path.join(S, "drift.tsv"), "w", encoding="utf-8", newline=""); w = csv.writer(out, delimiter="\t", lineterminator="\n")
w.writerow(["label", "root", "env", "rc", "summary", "class", "detail"])
out2 = open(os.path.join(S, "drift-resources.tsv"), "w", encoding="utf-8", newline=""); w2 = csv.writer(out2, delimiter="\t", lineterminator="\n")
w2.writerow(["label", "action", "address", "forces_replacement", "changed_attrs"])
counts = {}
for label in sorted(idx):
    root, env = idx[label]; rc = rcs.get(label, "?")
    p = os.path.join(S, "planlogs", label + ".plan.log")
    if not os.path.exists(p):
        il = os.path.join(S, "planlogs", label + ".init.log")
        e = ""
        if os.path.exists(il):
            m = re.search(r"Error: (.*)", open(il, encoding="utf-8", errors="replace").read()); e = m.group(1)[:160] if m else "init failed"
        cls, det = ("skip", rc) if rc.startswith("SKIP") else ("init-error", e or rc)
        w.writerow([label, root, env, rc, "", cls, det]); counts[cls] = counts.get(cls, 0) + 1; continue
    summ, err, res = parse(p)
    cls, det = classify(summ, err, res, rc)
    w.writerow([label, root, env, rc, summ, cls, det]); counts[cls] = counts.get(cls, 0) + 1
    for a, ad, at, f in res: w2.writerow([label, a, ad, f, ",".join(at)])
out.close(); out2.close()
print(counts)
