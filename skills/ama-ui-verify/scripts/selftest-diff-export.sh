#!/usr/bin/env bash
# Standing regression test for diff-export-vs-grid.mjs. No network, no browser, no AWS --
# pure fixtures, so it is safe to run any time and in CI.
#
# It must PASS a faithful export (including one with preamble rows before the header) and
# FAIL a reordered one, a missing-column one, and one whose values never occur in the grid.
# The reorder case is the important one: a set-comparison implementation passes it, which
# is exactly the bug this test exists to catch.
#
# Usage: bash selftest-diff-export.sh     (exit 0 = all cases behaved)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$SCRIPT_DIR/diff-export-vs-grid.mjs"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

cat > "$D/grid.json" <<'JSON'
{
  "reportUrl": "x", "exportName": "y",
  "grid": {
    "headers": [
      {"colId":"c1","left":0,"text":"Agency"},
      {"colId":"c2","left":100,"text":"SUM Original Loan Amt"},
      {"colId":"c3","left":200,"text":"# Loans"},
      {"colId":"c4","left":300,"text":"AVG Original FICO"}
    ],
    "searchResponses": [
      {"path":"/search/x","status":200,"fromCache":false,"rowCount":2,
       "columns":["a","b","c"],
       "results":[{"a":"196642453000.000000","b":"582523","c":"694"},
                  {"a":"442089069000.000000","b":"1282279","c":"726"}]}
    ]
  }
}
JSON

cat > "$D/good.csv" <<'CSV'
Agency,SUM Original Loan Amt,# Loans,AVG Original FICO
GNM,"196,642,453,000.00",582523,694
FNM,"442,089,069,000.00",1282279,726
CSV

cat > "$D/preamble.csv" <<'CSV'
Some Query Description,,,
Generated for testing,,,
Agency,SUM Original Loan Amt,# Loans,AVG Original FICO
GNM,"196,642,453,000.00",582523,694
CSV

cat > "$D/reordered.csv" <<'CSV'
Agency,# Loans,SUM Original Loan Amt,AVG Original FICO
GNM,582523,"196,642,453,000.00",694
CSV

cat > "$D/missing.csv" <<'CSV'
Agency,SUM Original Loan Amt,# Loans
GNM,"196,642,453,000.00",582523
CSV

cat > "$D/badvalues.csv" <<'CSV'
Agency,SUM Original Loan Amt,# Loans,AVG Original FICO
GNM,111.11,222.22,333.33
FNM,444.44,555.55,666.66
CSV

rc_total=0
check() { # $1 label  $2 expected-exit  $3 fixture
  out="$(node "$S" "$D/grid.json" "$D/$3" 2>&1)"; rc=$?
  if [ "$rc" = "$2" ]; then
    echo "  OK   $1 (exit $rc)"
  else
    echo "  FAIL $1 (exit $rc, wanted $2)"
    echo "$out" | sed 's/^/       /'
    rc_total=1
  fi
}

echo "expect PASS (0):"
check "faithful export"          0 good.csv
check "preamble before header"   0 preamble.csv
echo "expect FAIL (6):"
check "columns reordered"        6 reordered.csv
check "column missing"           6 missing.csv
check "values not from grid"     6 badvalues.csv

# The reorder case must name the offending position, not just say "differs".
if ! node "$S" "$D/grid.json" "$D/reordered.csv" 2>&1 | grep -q 'ORDER diverges at position 1'; then
  echo "  FAIL reorder message does not name the diverging position"
  rc_total=1
else
  echo "  OK   reorder message names the diverging position"
fi

[ "$rc_total" = 0 ] && echo "ALL CASES BEHAVED" || echo "SELFTEST FAILED"
exit "$rc_total"
