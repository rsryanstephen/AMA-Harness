#!/usr/bin/env bash
# Pre-Production check for a release (or hotfix): Staging error sweep + Staging API tests +
# infrastructure projects that must deploy with it (section 4) + EXPLAIN of every SQL shape the
# Staging build emitted (section 5) + new Staging error signatures vs a week earlier (section 6).
# Usage: release-preflight.sh <label> [--hours N] [--hotfix]
#   <label>    release/hotfix version, e.g. 130.0.0 (recorded, shown back by the gate)
#   --hours N  error-sweep window, default 24 -- pass "hours since the release was cut"
#   --hotfix   skip the full API test suite (ama-hotfix never runs it); a hotfix that changes
#              report SQL runs the api-testing `staging_shapes` subset instead (~5 min)
#   --shapes-in-business-hours  run that subset even Mon-Fri 9-5 ET -- ONLY on the user's explicit
#              yes for this run: it executes real report queries on the Redshift cluster Production
#              shares. Without it, inside the window the subset is NOT run and that is a finding.
#              Covers the export-content subset below too.
#   --export-tests | --no-export-tests  hotfix only, REQUIRED: the user's answer, asked per hotfix,
#              whether to also run the api-testing `staging_export_content` subset (~2 min: Channel
#              exports downloaded and checked cell by cell). User rule 2026-10-21: a hotfix can break
#              what only an export shows, so the choice is offered every time, never defaulted.
# Exit 0 = tests passed (or skipped) AND no unaddressed errors; 1 = something to warn about.
#
# Why: user instruction 2026-10-12 -- asking to deploy the release must FIRST run the Staging
# tests and the Graylog/CloudWatch sweep, and warn before proceeding. Both existed as prose
# steps (deploy-release Step 0 / 3a), the tests AFTER the master merge. prod-deploy-preflight-
# gate.sh denies a Production Octopus deploy unless this script recorded a run in the last
# 12h, and makes a failed run a user decision (AMA_PREFLIGHT_ACK=1).
set -uo pipefail
. "$HOME/.claude/hooks/lib-claude-paths.sh"

LABEL="${1:?usage: release-preflight.sh <label> [--hours N] [--hotfix --export-tests|--no-export-tests] [--shapes-in-business-hours]}"; shift
HOURS=24; HOTFIX=0; SHAPES_BH=0; EXPORTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="${2:?}"; shift 2 ;;
    --hotfix) HOTFIX=1; shift ;;
    --shapes-in-business-hours) SHAPES_BH=1; shift ;;
    --export-tests) EXPORTS=1; shift ;;
    --no-export-tests) EXPORTS=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
case "$LABEL" in */*) echo "label is the bare version (e.g. 130.0.9), not '$LABEL' -- the script adds release/ or hotfix/ itself" >&2; exit 64 ;; esac
if [ "$HOTFIX" = 1 ] && [ -z "$EXPORTS" ]; then
  echo "ASK THE USER first: run the export-content tests for this hotfix too (api-testing staging_export_content," >&2
  echo "~2 min, exports downloaded and checked)? Then re-run with --export-tests or --no-export-tests." >&2
  exit 64
fi

SK="$HOME/.claude/skills"
TS="$(date +%Y%m%d-%H%M%S)"
REPORT="$(hscratch release-preflight "report-$LABEL-$TS.md")"
STAMP="$(hstate tickets release-preflight)"
issues=()

{
echo "# Release preflight $LABEL ($(date '+%F %T %Z')), window ${HOURS}h"

# --- 0. Staging must be UP before any check below means anything. Asleep, the AWS sweep reports
# "clean" (nothing running) and the API/export tests fail 0/N -- 2026-10-23 export tests at 07:41
# SAST, wake task only ran at 07:45. ensure-awake.sh wakes it (standing rule) and waits.
echo; echo "## Staging awake?"
if ! bash "$SK/ama-env-sleep/scripts/ensure-awake.sh" staging 2>&1; then
  issues+=("Staging is not up -- every check below is meaningless; fix/wake Staging and re-run")
fi

# --- 1. Graylog: untagged errors on Staging (known_issue noise is segregated by the script)
echo; echo "## Graylog -- environment:staging, level<=3, untagged"
gl="$(bash "$SK/ama-graylog-search/scripts/graylog-search.sh" 'environment:staging AND level:<=3' "$((HOURS * 3600))" "" 300 source,message 2>&1)"
gl_total="$(printf '%s' "$gl" | jq -r '.total_results // empty' 2>/dev/null | tr -d '\r')"
if [ -z "$gl_total" ]; then
  echo "QUERY FAILED: $(printf '%s' "$gl" | head -c 300)"; issues+=("Graylog query failed -- errors unknown")
else
  echo "untagged errors: $gl_total  (known-issue suppressed: $(printf '%s' "$gl" | jq -r '.known_issue_suppressed.count // 0' | tr -d '\r'); by tag, of the 200 sampled: $(printf '%s' "$gl" | jq -r '.known_issue_suppressed.tags // {} | to_entries | sort_by(-.value) | map("\(.key)=\(.value)") | join(", ")' | tr -d '\r'))"
  if [ "$gl_total" -gt 0 ]; then
    printf '%s' "$gl" | jq -r '[.messages[].message] | group_by(.source) | map({s: .[0].source, n: length, m: (.[0].message // "" | tostring | .[0:160])}) | sort_by(-.n)[] | "  \(.n)x \(.s): \(.m)"' | tr -d '\r'
    issues+=("Graylog: $gl_total untagged Staging error(s)")
  fi
fi

# --- 1b. The catch-all tag is NOT a known issue. `Suppress non prod alerts` is a Slack-noise
# pipeline rule applied to nearly every Staging error (24h on 2026-10-15: 0 untagged, 1,880
# tagged, 191 of the 200 sampled under this one tag), so the untagged sweep above is blind on
# Staging by construction: it reported 0 while every Staging export was failing on broker
# connect errors (PROJ-15801, 2026-10-14). Report that tag's errors by source, and flag a
# spike against the preceding equal window (second query, 2x the window, count only).
CATCHALL='Suppress non prod alerts'
echo; echo "## Graylog -- environment:staging, level<=3, tagged \"$CATCHALL\" (catch-all, not a known issue)"
caq="environment:staging AND level:<=3 AND known_issue:\"$CATCHALL\""
ca="$(bash "$SK/ama-graylog-search/scripts/graylog-search.sh" "$caq" "$((HOURS * 3600))" "" 300 source,message 2>&1)"
ca_n="$(printf '%s' "$ca" | jq -r '.total_results // empty' 2>/dev/null | tr -d '\r')"
if [ -z "$ca_n" ]; then
  echo "QUERY FAILED: $(printf '%s' "$ca" | head -c 300)"; issues+=("Graylog catch-all query failed -- Staging errors unknown")
else
  # Baseline = the same hours on the previous working day, never "the hours just before":
  # QA/Staging sleep nightly (22:00 SAST) and at weekends (ama-env-sleep), so the preceding
  # window is often a sleeping one and every morning preflight would read as a spike.
  now_s="$(date +%s)"; back=24; [ "$HOURS" -gt 24 ] && back=$(( (HOURS + 23) / 24 * 24 ))
  b_end=$(( now_s - back * 3600 ))
  case "$(date -d "@$b_end" +%u)" in 6) b_end=$(( b_end - 86400 )) ;; 7) b_end=$(( b_end - 172800 )) ;; esac
  b_from="$(date -u -d "@$(( b_end - HOURS * 3600 ))" +%Y-%m-%dT%H:%M:%S.000Z)"; b_to="$(date -u -d "@$b_end" +%Y-%m-%dT%H:%M:%S.000Z)"
  prev="$(bash "$SK/ama-graylog-search/scripts/graylog-search.sh" "$caq" "${b_from}..${b_to}" "" 1 source 2>&1 | jq -r '.total_results // 0' 2>/dev/null | tr -d '\r')"
  prev="${prev:-0}"
  echo "catch-all-tagged errors: $ca_n  (same ${HOURS}h on the previous working day, from ${b_from%:*}Z: $prev); by source, of the $(printf '%s' "$ca" | jq -r '.messages | length' | tr -d '\r') sampled:"
  printf '%s' "$ca" | jq -r '[.messages[]] | group_by(.source) | map({s: .[0].source, n: length, m: (.[0].message // "" | tostring | .[0:160])}) | sort_by(-.n) | .[0:6] | .[] | "  \(.n)x \(.s): \(.m)"' | tr -d '\r'
  if [ "$ca_n" -ge 50 ] && [ "$ca_n" -gt $((prev * 2)) ]; then
    issues+=("Graylog: catch-all-tagged Staging errors SPIKED: $ca_n in ${HOURS}h vs $prev in the same hours on the previous working day -- read the by-source list")
  fi
fi

# --- 2. CloudWatch / ECS: the fixed AWS sweep, flagged sections only
echo; echo "## CloudWatch / ECS -- aws-sweep.sh staging --hours $HOURS"
sw="$(bash "$SK/ama-cloudwatch-search/scripts/aws-sweep.sh" staging --hours "$HOURS" 2>&1)"
# Noise, measured on the first run (130.0.0, 2026-10-12): a sec-6 service header whose only
# body line is the script's own known_noise_suppressed note, and permanently-ALARM alarms --
# AWS TargetTracking scale-in alarms (in ALARM by design) and *-low utilisation alarms.
flags="$(printf '%s\n' "$sw" | tr -d '\r' | awk '
  /^## /{sec=substr($2,1,1); hdr=""; next}
  sec=="2" && NF && $0 !~ /^  none$/                       {print "stopped task: " $0}
  sec=="3" && NF && $0 !~ /all live services steady/        {print "unsteady service: " $0}
  sec=="6" && /^  [^ ].*\):$/                                {hdr=$0; shown=0; next}
  sec=="6" && hdr!="" && /^    / && $0 !~ /known_noise_suppressed/ && !shown {print "crash-class log hits: " hdr; shown=1}
  sec=="7" && NF && $0 !~ /^  none$/ && $0 !~ /^  TargetTracking-|AlarmLow|-low-|utili[sz]ation-low/ {print "alarm: " $0}
  sec=="8" && NF && $0 !~ /none in window/ && $0 ~ /^  /    {print "failed cache update: " $0}')"
if [ -n "$flags" ]; then
  printf '%s\n' "$flags"; issues+=("AWS: $(printf '%s\n' "$flags" | wc -l | tr -d ' ') flagged line(s)")
else
  echo "clean (no stopped tasks, all services steady, no crash-class log hits, no alarms, no failed cache updates)"
fi
echo; echo "<details>full sweep</details>"; printf '%s\n' "$sw" | sed 's/^/    /'

# --- 3. Staging API test suite
echo; echo "## API tests -- api-testing staging"
if [ "$HOTFIX" = 1 ]; then
  # A hotfix skips the full suite (user rule 2026-08-25) but NOT the query-shape subset when it
  # changes report SQL (user rule 2026-10-20, PROJ-15825): the 15801 hotfix shipped 15808 in
  # a shape nothing on Staging ran. Runs BEFORE section 5 so the sweep sees those shapes logged.
  # The subset executes real report queries on the Redshift cluster Production shares, so inside
  # Mon-Fri 9-5 ET (or with ET unresolvable) it runs only on the user's explicit yes for this run
  # (--shapes-in-business-hours, user rule 2026-10-20) -- otherwise it is a finding, not a silent skip.
  . "$HOME/.claude/hooks/lib-et-now.sh"; win="$(et_window_state)"
  case "$win" in outside*) bh=0 ;; *) bh=1 ;; esac
  if ! bash "$SK/ama-deploy-release/scripts/sql-shape-preflight.sh" "hotfix/$LABEL" --changed-only; then
    echo "SKIPPED (--hotfix and no report-SQL change; ama-hotfix never runs the full suite)"; tests="SKIPPED"
  elif [ "$bh" = 1 ] && [ "$SHAPES_BH" != 1 ]; then
    echo "NOT RUN: hotfix changes report SQL, but it is US business hours ($win) and the query-shape"
    echo "subset runs real report queries on the shared Redshift cluster. ASK THE USER: run it now"
    echo "(re-run this preflight with --shapes-in-business-hours) or after 5pm ET."
    tests="SHAPES-NOT-RUN"; issues+=("API query-shape tests (staging_shapes) not run: US business hours ($win) -- ask the user: re-run with --shapes-in-business-hours, or after 5pm ET")
  else
    out="$(bash "$SK/ama-bitbucket-api/scripts/run-pipeline.sh" api-testing staging_shapes 2>&1)"; rc=$?
    printf '%s\n' "$out" | tail -15
    case "$rc" in
      0) tests="SHAPES-PASS" ;;
      2) tests="TIMEOUT"; issues+=("API query-shape tests (staging_shapes): timed out") ;;
      *) tests="FAIL";    issues+=("API query-shape tests (staging_shapes): failed (exit $rc)") ;;
    esac
  fi
  echo; echo "## Export content tests -- api-testing staging_export_content"
  if [ "$EXPORTS" != 1 ]; then
    echo "NOT RUN (--no-export-tests: the user's choice for this hotfix)"; tests="$tests EXPORTS-DECLINED"
  elif [ "$bh" = 1 ] && [ "$SHAPES_BH" != 1 ]; then
    echo "NOT RUN: US business hours ($win); exports run real report queries on the shared Redshift cluster."
    tests="$tests EXPORTS-NOT-RUN"; issues+=("Export content tests (staging_export_content) not run: US business hours ($win) -- ask the user: re-run with --shapes-in-business-hours, or after 5pm ET")
  else
    out="$(bash "$SK/ama-bitbucket-api/scripts/run-pipeline.sh" api-testing staging_export_content 2>&1)"; rc=$?
    printf '%s
' "$out" | tail -15
    case "$rc" in
      0) tests="$tests EXPORTS-PASS" ;;
      2) tests="$tests EXPORTS-TIMEOUT"; issues+=("Export content tests (staging_export_content): timed out") ;;
      *) tests="$tests EXPORTS-FAIL";    issues+=("Export content tests (staging_export_content): failed (exit $rc)") ;;
    esac
  fi
else
  out="$(bash "$SK/ama-bitbucket-api/scripts/run-pipeline.sh" api-testing staging 2>&1)"; rc=$?
  printf '%s\n' "$out" | tail -25
  case "$rc" in
    0) tests="PASS" ;;
    2) tests="TIMEOUT"; issues+=("API tests: timed out") ;;
    *) tests="FAIL";    issues+=("API tests: failed (exit $rc)") ;;
  esac
fi

# --- 4. Infrastructure projects that must ship WITH this release (user rule 2026-10-15): infra
# Octopus projects (YourProduct-Backbone group) are a separate track the release never deploys, so a
# ticket in this release with an un-applied infra commit would ship its app half alone.
echo; echo "## Infrastructure projects paired with this release (infra-paired-check.sh)"
FV="release/$LABEL"; [ "$HOTFIX" = 1 ] && FV="hotfix/$LABEL"
ip="$(bash "$SK/ama-deploy-release/scripts/infra-paired-check.sh" "$FV" 2>&1)"; iprc=$?
printf '%s\n' "$ip"
if [ "$iprc" != 0 ]; then issues+=("Infra pairing check failed (exit $iprc) -- paired infra deploys unknown")
else
  notlive="$(printf '%s\n' "$ip" | grep -vE '^(NONE|ACTION|WARN)' | grep -v ' LIVE (' | awk '{print $1}' | paste -sd, )"
  [ -n "$notlive" ] && issues+=("Infra: not in Production yet, ships with this release or is ruled out by the user: $notlive")
fi

# --- 5. Every query SHAPE the Staging build emits, through the Redshift planner (user rule
# 2026-10-15, PROJ-15801): a change at a shared builder is verified in every shape that
# wraps it, not the one it was written for. EXPLAIN only -- business-hours safe.
echo; echo "## SQL shape sweep (sql-shape-preflight.sh -- ama-debugging-notes/SHARED-CHOKEPOINT-CHANGES.md)"
BR="release/$LABEL"; [ "$HOTFIX" = 1 ] && BR="hotfix/$LABEL"
bash "$SK/ama-deploy-release/scripts/sql-shape-preflight.sh" "$BR" || issues+=("SQL shapes: a query shape FAILED EXPLAIN, was never run on the Staging build, or could not be swept -- read section 5")

# --- 6. New error SIGNATURES on Staging in the window vs the same span a week earlier -- the
# counts above say how many, this says what is new (a report only one client opens).
echo; echo "## New error signatures on Staging (error-signature-diff.sh staging ${HOURS}h vs a week earlier)"
bash "$SK/ama-graylog-search/scripts/error-signature-diff.sh" staging "$HOURS" 2>&1 | head -25
[ "${PIPESTATUS[0]}" = 1 ] && issues+=("Graylog: new or grown untagged error signatures on Staging -- read section 6")
} > "$REPORT" 2>&1

errors="CLEAN"; [ "${#issues[@]}" -gt 0 ] && errors="ISSUES"
summary="$(printf '%s; ' "${issues[@]:-}" | sed 's/; $//')"
# stamp: epoch <TAB> label <TAB> tests <TAB> CLEAN|ISSUES <TAB> summary <TAB> report
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$LABEL" "${tests:-?}" "$errors" "${summary:-none}" "$REPORT" >> "$STAMP"

cat "$REPORT" | sed '/^<details>full sweep<\/details>$/,/^## API tests/{/^## API tests/!d}'
echo
if [ "$errors" = "CLEAN" ]; then
  echo "PREFLIGHT OK: tests $tests, no unaddressed Staging errors in ${HOURS}h. Report: $REPORT"; exit 0
fi
echo "PREFLIGHT WARNING -- tell the user before deploying: $summary"
echo "Report: $REPORT"
echo "Production deploy stays blocked until the user explicitly says proceed (then AMA_PREFLIGHT_ACK=1)."
exit 1
