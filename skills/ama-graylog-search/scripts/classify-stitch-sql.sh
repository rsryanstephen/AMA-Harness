#!/usr/bin/env bash
# Classify recent staging search-api SQL by servicer-stitch shape.
# usage: classify-stitch-sql.sh [n=12] [range-seconds=900] [environment=staging]
# Per logged ExecuteAsync::SQL line: which template family it carries, whether the CteRow_Ids
# CTE exists, whether the grouped servicer was swapped to the period servicer, whether a
# per-period table (_periods_/_moneyness_/_cprn_) is joined, and the GROUP BY column.
# Stitched detail rows => cte=1 swapToPeriodServicer=1 GROUP BY row_ids_stitch_... (outer SELECT
#                         aliases the segment `servicer` as loanperiodic_servicer)
# Stitched TOP ROW     => cte=0 whereOnServicer=1 (criterion rewritten to `servicer`; no GROUP BY)
# Unstitched           => cte=0 swapToPeriodServicer=0 whereOnServicer=0 GROUP BY ...__loanperiodic_servicer
# whereOnServicer=1 on a stitched top row = it filters on the segment servicer (same population
# as the detail rows); whereOnServicer=0 there = the PROJ-15411 build (rewrite removed).
# Which shape is wanted is PROJ-14772's call, not this legend's. The CPR FIGURE either
# produces is separate -- see ama-architecture-notes/CPRN-STITCH-ARITHMETIC.md.
# swapToPeriodServicer = the SELECT alias, never the top-row signal.
# Recipe + body shape: ama-architecture-notes/SEARCH-SQL-PIPELINE.md ("Testing whether a family is stitched").
set -uo pipefail
n="${1:-12}"; range="${2:-900}"; env="${3:-staging}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
bash "$HOME/.claude/skills/ama-graylog-search/scripts/graylog-search.sh" \
  "environment:$env AND application:product-service-search-api AND \"ExecuteAsync::SQL\"" \
  "$range" "" "$n" "timestamp,full_message,message" > "$W/raw.json"
cnt=$(jq '.messages|length' "$W/raw.json")
echo "messages: $cnt (env=$env, last ${range}s)"
i=0
while [ "$i" -lt "$cnt" ]; do
  jq -r --argjson i "$i" '.messages[$i] | (.full_message // .message)' "$W/raw.json" > "$W/$i.sql"
  ts=$(jq -r --argjson i "$i" '.messages[$i].timestamp' "$W/raw.json")
  fam=$(grep -oE 'AS (template_(smm|rpb|cdr1|moneyness|cpr1|paydowns|pct_gnm|pct_conv|m[0-9]+cpr1|ct[0-9]+cpr1)[a-z0-9_+]*|sum__loan_by_servicer_transfer_periods_source__f[0-9]+_isinactive)' "$W/$i.sql" | sed 's/^AS //' | sort -u | head -3 | tr '\n' ',')
  cte=$(grep -c 'CteRow_Ids AS' "$W/$i.sql" || true)
  grp=$(grep -oE 'GROUP BY [a-z_]+' "$W/$i.sql" | head -1)
  swap=$(grep -oE '\.servicer AS loan_by_servicer_transfer_non_periods_source__loanperiodic_servicer' "$W/$i.sql" | wc -l)
  periods=$(grep -cE 'loanbyservicertransferview_(periods|moneyness|cprn)' "$W/$i.sql" || true)
  whereServ=$(grep -oE 'WHERE.*' "$W/$i.sql" | grep -oE '\.servicer\)? (IN|=|NOT IN|<>) ' | wc -l)
  echo "[$i] $ts fam=${fam:-?} cte=$cte swapToPeriodServicer=$swap whereOnServicer=$whereServ periodsJoined=$periods ${grp}"
  i=$((i+1))
done
