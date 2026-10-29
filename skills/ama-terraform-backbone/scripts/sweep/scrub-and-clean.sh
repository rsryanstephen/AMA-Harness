#!/usr/bin/env bash
# After the Linux plan run: scrub every plan/init log against the Octopus variable values whose NAME looks secret
# (password|secret|token|key|connection), then delete every secret-bearing input: rendered plans, plans.tar, leftover states.
set -u
S="${SWEEP_DIR:?set SWEEP_DIR=<work dir>}"
python -I - "$S/sweep" <<'EOF'
import glob, os, re, sys
root = sys.argv[1]
vals = set()
for f in glob.glob(os.path.join(root, "plans", "*", ".vars.tsv")):
    for line in open(f, encoding="utf-8", errors="replace"):
        k, _, v = line.rstrip("\r\n").partition("\t")
        if re.search(r"password|secret|token|apikey|api-key|connection", k, re.I) and len(v) >= 6 and v != "<<SENSITIVE>>":
            vals.add(v)
vals = sorted(vals, key=len, reverse=True)
hits = 0
for f in glob.glob(os.path.join(root, "planlogs", "*.log")):
    t = open(f, encoding="utf-8", errors="replace").read(); o = t
    for v in vals: t = t.replace(v, "<redacted>")
    if t != o:
        hits += 1; open(f, "w", encoding="utf-8").write(t)
print(f"scrub: {len(vals)} secret-shaped values, {hits} log files redacted")
EOF
rm -rf "$S/plans" "$S/linux/plans.tar" "$S/states"
echo "deleted plans/, plans.tar, states/"
ls "$S/sweep"
