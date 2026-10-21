#!/usr/bin/env bash
# Self-test for harness-config-vars.py. No network, no real config, no Octopus -- synthetic
# fixtures only, so it is safe to run anywhere and cannot touch the org store.
#
# The invariant that matters: flatten -> unflatten must reproduce the config BYTE-IDENTICALLY,
# key order included. Everything else here exists because it broke once while this was built.
#
# Usage: bash scripts/harness-config-vars-selftest.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/harness-config-vars.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0

ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); printf 'FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1 (want=$2 got=$3)"; fi; }

# ---------------------------------------------------------------- fixtures
# The example carries: a number, a data-keyed map (placeholder key is NOT a plain identifier),
# an array of scalars, an array of objects, and an empty-in-practice array whose one element
# exists only to declare the element type.
cat > "$T/example.json" <<'JSON'
{
  "user": { "email": "you@example.com" },
  "core": { "name": "placeholder", "port": 1234 },
  "list": ["<type-only>"],
  "people": [ { "name": "P", "tags": ["<type-only>"] } ],
  "greet": { "first.recipient@example.com": "Name" }
}
JSON

cat > "$T/cfg.json" <<'JSON'
{
  "user": { "email": "real.person@example.net" },
  "core": { "name": "live — em dash and ünïcode", "port": 27018 },
  "list": ["a", "b", "c"],
  "people": [
    { "name": "One", "tags": [] },
    { "name": "Two", "tags": ["x", "y"] }
  ],
  "greet": { "Daniel.McNamara@example.com": "Dan", "other.person@example.com": "Oth" }
}
JSON

# ---------------------------------------------------------------- flatten
python "$V" flatten "$T/cfg.json" "$T/example.json" > "$T/vars.json" 2> "$T/err.txt"
check "flatten exits clean" 0 $?

python - "$T/vars.json" > "$T/names.txt" <<'PY'
import json, io, sys
for v in json.load(io.open(sys.argv[1], encoding="utf-8")):
    print(v["Name"] + "\t" + v["Value"])
PY

# The user block is per-person and must never reach the org store.
c=$(grep -c 'HarnessConfig:user' "$T/names.txt" || true)
check "user block is not flattened" 0 "$c"
# Colon-separated path, array indices as plain numeric segments.
c=$(grep -c '^HarnessConfig:list:1	b$' "$T/names.txt" || true)
check "array element -> indexed name" 1 "$c"
c=$(grep -c '^HarnessConfig:people:1:tags:0	x$' "$T/names.txt" || true)
check "nested array inside an object element" 1 "$c"
# A data-keyed map key contains dots -- the whole point of using ':' as the separator.
c=$(grep -c '^HarnessConfig:greet:Daniel.McNamara@example.com	Dan$' "$T/names.txt" || true)
check "dotted map key survives verbatim" 1 "$c"
# An empty array contributes nothing at all; the skeleton is what brings it back.
c=$(grep -c 'people:0:tags' "$T/names.txt" || true)
check "empty array contributes no variables" 0 "$c"

# ---------------------------------------------------------------- unflatten
python "$V" unflatten "$T/vars.json" "$T/example.json" > "$T/rebuilt.json" 2>/dev/null
check "unflatten exits clean" 0 $?

python - "$T/cfg.json" "$T/rebuilt.json" > "$T/rt.txt" <<'PY'
import json, io, sys, collections
a = json.load(io.open(sys.argv[1], encoding="utf-8"), object_pairs_hook=collections.OrderedDict)
a.pop("user", None)
b = json.load(io.open(sys.argv[2], encoding="utf-8"), object_pairs_hook=collections.OrderedDict)
sa = json.dumps(a, indent=2, ensure_ascii=False)
sb = json.dumps(b, indent=2, ensure_ascii=False)
print("identical" if sa == sb else "differs")
if sa != sb:
    import difflib
    sys.stderr.write("\n".join(list(difflib.unified_diff(sa.splitlines(), sb.splitlines(), lineterm=""))[:25]) + "\n")
PY
check "round-trip is byte-identical, key order included" identical "$(cat "$T/rt.txt")"

# Types come from the example, never from the value's shape.
got=$(python -c "import json,io,sys;print(type(json.load(io.open(sys.argv[1],encoding='utf-8'))['core']['port']).__name__)" "$T/rebuilt.json")
check "a number stays a number" int "$got"
# Compared INSIDE python and reduced to an ASCII verdict. Shuttling the value out through a
# `python -c` stdout mangles it on this platform (that stream is not UTF-8 unless reconfigured),
# so a bash-side string compare fails on the harness, not on the code under test -- which is
# exactly what happened the first time this test ran.
got=$(python - "$T/rebuilt.json" <<'PY'
import json, io, sys
d = json.load(io.open(sys.argv[1], encoding="utf-8"))
print("ok" if d["core"]["name"] == u"live — em dash and ünïcode" else "mangled")
PY
)
check "non-ASCII survives both directions" ok "$got"
got=$(python -c "import json,io,sys;print(json.load(io.open(sys.argv[1],encoding='utf-8')).get('user','ABSENT'))" "$T/rebuilt.json")
check "rebuilt config carries no user block" ABSENT "$got"

# A digits-only STRING must not be turned into a number -- the example says it is a string.
python - "$T" <<'PY'
import json, io, collections, os
T = os.sys.argv[1]
ex = {"core": {"code": "0042"}}
cf = {"core": {"code": "0777"}}
io.open(T + "/ex2.json", "w", encoding="utf-8").write(json.dumps(ex))
io.open(T + "/cf2.json", "w", encoding="utf-8").write(json.dumps(cf))
PY
python "$V" flatten "$T/cf2.json" "$T/ex2.json" > "$T/v2.json" 2>/dev/null
python "$V" unflatten "$T/v2.json" "$T/ex2.json" > "$T/r2.json" 2>/dev/null
got=$(python -c "import json,io,sys;d=json.load(io.open(sys.argv[1],encoding='utf-8'));print(repr(d['core']['code']))" "$T/r2.json")
check "a digits-only string stays a string" "'0777'" "$got"

# ---------------------------------------------------------------- refusals
# A live key with no example counterpart must BLOCK the push: the org store would carry a value
# a fetch could never place, so it would vanish silently on the next machine.
python - "$T" <<'PY'
import json, io, os
T = os.sys.argv[1]
cfg = json.load(io.open(T + "/cfg.json", encoding="utf-8"))
cfg["brandNew"] = {"key": "v"}
io.open(T + "/cfg-unknown.json", "w", encoding="utf-8").write(json.dumps(cfg))
PY
python "$V" flatten "$T/cfg-unknown.json" "$T/example.json" > /dev/null 2> "$T/err2.txt"
check "unknown key refuses the push" 3 $?
c=$(grep -c 'brandNew:key' "$T/err2.txt" || true)
check "the refusal names the offending key" 1 "$c"

# A wildcard must NOT be inferred for a plain object: an unknown key beside known ones is an
# error, not a new map entry.
python - "$T" <<'PY'
import json, io, os
T = os.sys.argv[1]
cfg = json.load(io.open(T + "/cfg.json", encoding="utf-8"))
cfg["core"]["unexpected"] = "v"
io.open(T + "/cfg-extra.json", "w", encoding="utf-8").write(json.dumps(cfg))
PY
python "$V" flatten "$T/cfg-extra.json" "$T/example.json" > /dev/null 2>&1
check "an extra key in a plain object refuses" 3 $?

# Fresh-org bootstrap: an empty variable set must still yield a parseable config from the
# example's own values, with no placeholder ARRAY contents leaking in.
echo '[]' > "$T/none.json"
python "$V" unflatten "$T/none.json" "$T/example.json" > "$T/boot.json" 2>/dev/null
check "empty variable set still rebuilds" 0 $?
got=$(python -c "import json,io,sys;d=json.load(io.open(sys.argv[1],encoding='utf-8'));print(json.dumps(d['list']))" "$T/boot.json")
check "example array contents never leak" "[]" "$got"

printf '\nharness-config-vars-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
