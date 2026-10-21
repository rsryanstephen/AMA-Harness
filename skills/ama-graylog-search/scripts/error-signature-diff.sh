#!/usr/bin/env bash
# Compare error SIGNATURES since a deploy against the same span one week earlier.
# Usage: error-signature-diff.sh <qa|staging|production> <since> [--baseline-days N] [--limit N]
#   <since> = ISO-8601 UTC (2026-10-14T05:30:00Z) or hours ago (e.g. 24)
# Prints NEW signatures (absent from the baseline) and GROWN ones (>2x and >=10); known_issue-tagged
# ones are listed after, as "(tagged)", and never fail the check on their own.
# Exit 0 nothing new | 1 NEW/GROWN found | 2 usage / Graylog unreachable.
#
# Signature = application + known_issue tag, or for an untagged error application + the first
# 90 chars of the message with numbers/GUIDs/hex/quoted literals normalised away.
#
# Why (PROJ-15801, 2026-10-14): release 130 raised untagged Production errors 4 -> 115 over
# two days, and a client support mail was the first signal. A one-shot sweep right after the
# deploy cannot see an error a report only throws when someone opens it hours later. Run this
# at +4h and +24h after every Production deploy (octopus-prod-deploy-ticket-sweep-reminder.sh
# names the reminder.sh calls), and on Staging since the cut inside release-preflight.sh.
set -uo pipefail
G="$(dirname "$0")/graylog-search.sh"
ENV="${1:?usage: error-signature-diff.sh <env> <since> [--baseline-days N] [--limit N]}"
SINCE="${2:?usage: error-signature-diff.sh <env> <since> [--baseline-days N] [--limit N]}"
shift 2; BD=7; LIMIT=5000
while [ $# -gt 0 ]; do
  case "$1" in --baseline-days) BD="$2"; shift 2 ;; --limit) LIMIT="$2"; shift 2 ;; *) echo "unknown arg $1" >&2; exit 2 ;; esac
done
export GRAYLOG_NO_SUPPRESS=1
now=$(date -u +%s)
case "$SINCE" in
  *T*) from=$(date -u -d "$SINCE" +%s) || exit 2 ;;
  *[!0-9]*|'') echo "error-signature-diff: <since> must be hours (digits) or ISO-8601, got '$SINCE'" >&2; exit 2 ;;
  *) from=$(( now - SINCE*3600 )) ;;
esac
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
shift_s=$(( BD*86400 ))
NOWW="$(iso "$from")..$(iso "$now")"
BASEW="$(iso $(( from - shift_s )))..$(iso $(( now - shift_s )))"
Q="environment:$ENV AND level:<=3"

# sig <window> -> "<count>\t<signature>" lines, plus a "#total <n>" line
sig() {
  local raw
  raw="$(bash "$G" "$Q" "$1" "" "$LIMIT" "application,known_issue,message" 2>/dev/null)"
  printf '%s' "$raw" | jq -e '.messages' >/dev/null 2>&1 || { echo "graylog unreachable: $(printf '%s' "$raw" | head -c 200)" >&2; return 2; }
  printf '%s' "$raw" | jq -r '"#total \(.total_results)", (.messages[] |
      (.application // "-") + "\t" +
      (if (.known_issue // "") != "" and .known_issue != "Suppress non prod alerts" then "[" + .known_issue + "]"
       else ((.message // "") | gsub("\\s+"; " ") | .[0:90]
             | gsub("[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}"; "<guid>") | gsub("\\b[0-9a-fA-F]{16,}\\b"; "<hex>")
             | gsub("\"[^\"]*\""; "<s>")) end))' \
    | tr -d '\r' \
    | perl -pe 'unless (/^#total/) { s/\b([0-9]{2}[0-9A-Z]{3}:)|[0-9]+/defined $1 ? $1 : "N"/ge }' \
    | awk '/^#total/ { print; next } { c[$0]++ } END { for (k in c) printf "%d\t%s\n", c[k], k }'
}

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
sig "$NOWW" > "$W/now" || exit 2
sig "$BASEW" > "$W/base" || exit 2
tn="$(sed -n 's/^#total //p' "$W/now")"; tb="$(sed -n 's/^#total //p' "$W/base")"
echo "env=$ENV  now=$NOWW ($tn errors)  baseline=$BASEW ($tb errors)$([ "${tn:-0}" -gt "$LIMIT" ] && echo "  [sampled $LIMIT]")"

awk -F'\t' 'FNR==NR { if ($1 !~ /^#/) b[$2 "\t" $3] = $1; next }
  $1 ~ /^#/ { next }
  { k = $2 "\t" $3; n = $1; o = (k in b) ? b[k] : 0
    # A known_issue tag = someone already triaged it -- EXCEPT the non-prod catch-all, which
    # tags every QA/Staging error and would hide all of them (release-preflight.sh, 2026-10-14).
    t = ($3 ~ /^\[/ && $3 != "[Suppress non prod alerts]") ? "known-" : ""
    if (o == 0) printf "%sNEW    %6d  %s\n", t, n, k
    else if (n >= 10 && n > 2*o) printf "%sGROWN  %6d  (was %d)  %s\n", t, n, o, k }' "$W/base" "$W/now" \
  | sort -k2,2nr > "$W/out"
grep -v '^known-' "$W/out"
grep '^known-' "$W/out" | sed 's/^known-/  (tagged) /'
# Only UNTAGGED new/grown signatures fail the check -- a tagged one is a known, triaged issue.
if grep -qv '^known-' "$W/out"; then exit 1; fi
echo "no new or grown untagged error signatures"
exit 0
