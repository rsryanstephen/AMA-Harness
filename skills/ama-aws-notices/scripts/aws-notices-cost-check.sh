#!/usr/bin/env bash
# Cost leg of the AWS notice sweep. Answers ONE question the Health API cannot: are we
# already paying a late-upgrade premium?
#
# NO magnitude threshold, deliberately. The reference miss -- ElastiCache Redis OSS
# extended support -- ran at ~$625/mo inside a much larger ElastiCache bill (measured:
# $537.24 + $87.38 for 2026-05). Any threshold big enough not to cry wolf on normal
# growth is bigger than the signal. So the detector is instead:
#   1. usage-type keys matching Support|Extended|ExtSupp|EOL, at ANY magnitude
#   2. usage-type keys that are NEW this month vs the prior two
# Matching is client-side rather than a server-side Dimensions filter, so the result
# doesn't depend on MatchOptions=CONTAINS semantics.
#
# This leg detects "we STARTED paying". Priority-2 risk is mostly "we WILL start paying",
# which only comes from *_PLANNED_LIFECYCLE_EVENT prose -- see SKILL.md. Both legs, both
# needed.
#
# Calibration (SKILL.md gate 2, the one that isn't fakeable): this must return
# USE1-ExtendedSupportYr1_Yr2-NodeUsage for 2026-05/06/07 at ~$625/mo, with August
# pro-rated to the mid-August redis 6.2 upgrade. ZERO ROWS MEANS THE QUERY SHAPE BROKE,
# not that we stopped paying.
#
# Usage: aws-notices-cost-check.sh [months-back] [new-key-floor-usd]   (default 4, 25)
# Output: one JSON object on stdout.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"

MONTHS="${1:-4}"
NEWKEY_FLOOR="${2:-$(hr_config '.awsNotices.newKeyFloorUsd' 25)}"
case "$NEWKEY_FLOOR" in ''|*[!0-9.]*) printf 'new-key-floor-usd must be numeric\n' >&2; exit 1 ;; esac
case "$MONTHS" in ''|*[!0-9]*) printf 'months-back must be a positive integer\n' >&2; exit 1 ;; esac
[ "$MONTHS" -ge 2 ] || { printf 'months-back must be >= 2 (new-key detection needs history)\n' >&2; exit 1; }

# End is EXCLUSIVE in the CE API, so the first of next month captures all of this one.
start="$(date -d "$(date +%Y-%m-01) -$((MONTHS - 1)) months" +%Y-%m-01 2>/dev/null)" || start=""
end="$(date -d "$(date +%Y-%m-01) +1 month" +%Y-%m-01 2>/dev/null)" || end=""
if [ -z "$start" ] || [ -z "$end" ]; then
  printf 'aws-notices-cost-check.sh: date arithmetic failed (need GNU date)\n' >&2
  exit 1
fi

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

# Two GroupBy dimensions is the API cap -- USAGE_TYPE carries the extended-support string,
# SERVICE attributes it. One call covers the whole window.
if ! MSYS_NO_PATHCONV=1 aws ce get-cost-and-usage \
      --time-period "Start=$start,End=$end" \
      --granularity MONTHLY --metrics UnblendedCost \
      --group-by Type=DIMENSION,Key=USAGE_TYPE Type=DIMENSION,Key=SERVICE \
      --output json > "$tmpd/ce.json" 2>"$tmpd/ce.err"; then
  printf 'aws ce get-cost-and-usage failed:\n' >&2
  cat "$tmpd/ce.err" >&2
  exit 1
fi

# NB: `end` is a jq keyword (if/then/else/end), and this build (jq-1.5rc1) rejects it BOTH
# as a variable (`$end`) and as an unquoted object key (`end:`) -- newer jq allows the
# latter. Either one fails with a bare "syntax error, unexpected end" pointing at the wrong
# line entirely. Hence `$winEnd` and the quoted `"end":` below. Don't reintroduce it.
jq -c --arg winStart "$start" --arg winEnd "$end" --argjson floor "$NEWKEY_FLOOR" '
  # Per-month usage-type key sets, oldest first.
  [ .ResultsByTime[]
    | { month: .TimePeriod.Start,
        rows: [ .Groups[]
                | { usageType: .Keys[0], service: .Keys[1],
                    amount: (.Metrics.UnblendedCost.Amount | tonumber) }
                | select(.amount > 0) ] } ] as $months

  | ($months | map(.rows | map(.usageType)) ) as $keysets
  | ($keysets | length) as $n

  # New-key detection: present in the latest month, absent from EVERY prior month in the
  # window. Measured on the real account: comparing against only the prior two months
  # returned 25 "new" keys in one run -- per-region request tiers (AP-Requests-Tier1,
  # ZA-Requests-Tier2-HTTPS, JP-DataTransfer-Out-OBytes ...) that appear and vanish with
  # sporadic traffic. 25 false positives a month gets the whole report muted, which is the
  # failure this skill exists to prevent.
  | ( if $n >= 2
      then ($keysets[$n-1] - ($keysets[0:$n-1] | add // []))
      else [] end ) as $absentBefore

  # ...and the ONE place a magnitude floor is right. The premium leg below stays
  # thresholdless on purpose (the reference miss was ~$625/mo inside a much larger
  # ElastiCache bill). But a brand-new usage type is only news if it costs something: a
  # new key at $0.01 is traffic noise, a new key at $50 is a service we started paying
  # for. Asymmetric on purpose -- a known-bad string needs no floor, an unknown string
  # does.
  | ( [ $months[$n-1].rows[]?
        | select(.usageType as $u | $absentBefore | index($u))
        | select(.amount >= $floor) ] ) as $newRows

  | { window: { start: $winStart, "end": $winEnd, exclusiveEnd: true },
      lateUpgradePremium:
        [ $months[] | { month: .month,
            rows: [ .rows[]
                    | select(.usageType | test("Support|Extended|ExtSupp|EOL"; "i")) ] }
          | select(.rows | length > 0) ],
      newUsageTypes: ($newRows | sort_by(-.amount)),
      newUsageTypeCount: ($newRows | length),
      newKeyFloorUsd: $floor,
      newKeysBelowFloorSuppressed: (($absentBefore | length) - ($newRows | length)),
      monthsScanned: $n,
      note: "Premium leg has NO magnitude threshold by design -- any row matching the extended-support pattern is a finding. Zero premium rows in a month we know we were paying means the query shape broke, not that the charge stopped. The new-key leg DOES have a floor (newKeyFloorUsd); suppressed-below-floor is reported so the suppression is never silent."
    }' < "$tmpd/ce.json" | sed 's/\r$//'
