#!/usr/bin/env bash
# When did the last FLEET release finish deploying to Production, and what is the next
# working day? Usage: last-prod-deploy-date.sh [release/N.0.0]
# Prints:  deployed=YYYY-MM-DD   next_working_day=YYYY-MM-DD   plus the per-day histogram.
#
# ama-release-notes Step 3 and ama-cut-release-branch Step 1 both need this date and both
# said "walk the Octopus deployment history, don't guess from Jira's releaseDate field" --
# a lookup plus weekday arithmetic redone by hand every release.
#
# WHY A HISTOGRAM AND NOT "LATEST". Octopus releases are 2.0.0.<build> per project; it does
# not know "release/130.0.0". Hotfixes reach Production through the same Master channel as
# releases, so the single most recent Production completion is usually a HOTFIX touching one
# or two projects (first version of this script answered 2026-09-10 for release/129.0.0,
# which shipped 2026-08-17). A fleet release is the day on which MANY projects completed a
# Production deploy together -- so take each project's Production completions, bucket by
# day, and report the most recent day with a fleet-sized count. Public holidays are NOT
# accounted for; say so if the result lands right after one.
set -uo pipefail
VERSION="${1:-}"
. "$HOME/.claude/hooks/lib-harness-repos.sh"
S="$(hr_config_required '.octopus.serverUrl')" || exit 1
SPACE="$(hr_config_required '.octopus.spaceId')" || exit 1
PROD="$(hr_config '.octopus.environmentIds.production' '<production>')"
H="X-Octopus-ApiKey: ${OCTOPUS_API_KEY:?OCTOPUS_API_KEY not set}"
MIN_PROJECTS="${MIN_PROJECTS:-8}"   # a release touches ~17 deployable projects; a hotfix 1-3

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# tr -d '\r': jq on this box emits CRLF, and a lone `read -r PID` keeps the CR -- curl then
# rejects the URL as malformed (msys-command-traps-nudge.sh's jq trap, hit live here).
curl -sS -H "$H" "$S/api/$SPACE/projects/all" \
  | jq -r '.[] | select(.Name | startswith("YourProduct_Exporter_")) | .Id' | tr -d '\r' > "$TMP/projects.txt"

# One line per (project, prod-completion-day), Release/Master channels only.
: > "$TMP/days.txt"
while read -r PID; do
  [ -n "$PID" ] || continue
  curl -sS -H "$H" "$S/api/$SPACE/projects/$PID/progression" \
    | jq -r --arg e "$PROD" --arg p "$PID" '.Releases[]
        | select(.Channel.Name == "Release" or .Channel.Name == "Master")
        | .Deployments[$e][]? | select(.State == "Success")
        | "\($p)\t\(.Created)"' | tr -d '\r' >> "$TMP/stamps.txt"
done < "$TMP/projects.txt"

# Octopus stamps are UTC. Releases go out in the US evening, which is the NEXT UTC day, and
# Jira's releaseDate is the ET calendar day -- so convert to America/New_York before
# bucketing. python zoneinfo, never a hardcoded offset (lib-et-now.sh has the EDT/EST trap).
python - "$TMP/stamps.txt" > "$TMP/days.txt" <<'PY'
import sys
from datetime import datetime
from zoneinfo import ZoneInfo
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\r\n")
    if not line: continue
    pid, ts = line.split("\t", 1)
    ts = ts.replace("Z", "+00:00")
    try:
        d = datetime.fromisoformat(ts[:26] + ts[26:] if "." in ts else ts)
    except ValueError:
        d = datetime.fromisoformat(ts.split(".")[0] + ts[-6:])
    print(pid + "\t" + d.astimezone(ZoneInfo("America/New_York")).strftime("%Y-%m-%d"))
PY

echo "--- Production completions per day (distinct projects) ---"
sort -u "$TMP/days.txt" | cut -f2 | sort | uniq -c | sort -k2 -r | awk '{printf "  %s  %2d project(s)\n", $2, $1}' | head -12

day="$(sort -u "$TMP/days.txt" | cut -f2 | sort | uniq -c | awk -v m="$MIN_PROJECTS" '$1 >= m {print $2}' | sort -r | head -1)"
[ -n "$day" ] || { echo "no day with >= $MIN_PROJECTS projects deploying to Production (MIN_PROJECTS=$MIN_PROJECTS)" >&2; exit 1; }
next="$(date -u -d "$day + 1 day" +%Y-%m-%d)"
while [ "$(date -u -d "$next" +%u)" -gt 5 ]; do next="$(date -u -d "$next + 1 day" +%Y-%m-%d)"; done
echo "deployed=$day"
echo "next_working_day=$next"
[ -n "$VERSION" ] && echo "  (most recent fleet-sized Production day; confirm it is $VERSION's, not a later release's)" >&2
exit 0
