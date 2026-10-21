#!/usr/bin/env bash
# Read-only investigation entry point for the <amaSupportChannelName>-notices unattended run.
#
# WHY THIS EXISTS AS ONE SCRIPT: the unattended triage leg is deliberately denied Bash
# (support-notices-unattended-run.sh's header -- Phase 1's "propose only" guarantee is
# enforced by --allowedTools, not by asking nicely). That also denied it every
# investigation capability in the harness, since all of them are bash scripts, so every
# item in every DM read "Investigated: no, no tool to investigate from here" -- a
# hardcoded constant, not a finding (<harnessEpicKey>, 2026-08-31).
#
# The fix is not "grant Bash back": raw Bash can curl Slack and commit code, so it
# reopens exactly the hole the tool list was closing. Instead the investigation leg gets
# Bash scoped to THIS SCRIPT ONLY, which is read-only by construction -- GET requests,
# no writes, no repo access, no Slack, no Jira. Adding a subcommand that mutates
# anything defeats the entire point of the split.
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"

usage() {
  cat >&2 <<'USAGE'
usage:
  support-notices-investigate.sh graylog <lucene-query> <range-seconds> [limit]
      Count + sample matching Graylog messages on the alert stream. Use the error's own
      verbatim text (or a distinctive fragment) as the query.
  support-notices-investigate.sh pipeline <iso8601-utc>
      Any <repository>-api-testing pipeline run overlapping that instant. A hit means
      the error is probably test-caused, not a live app fault.
  support-notices-investigate.sh triage <iso8601-utc> <lucene-query> [range-seconds]
      BOTH of the above in ONE invocation. Prefer this: the expensive part of a check is
      the agent's tool round-trip (measured at 2-3 min each on this machine under
      contention, harness-gaps.md), not the curl, so two subcommands per mail is what
      blew two successive leg-A timeouts. One call per mail is the difference between
      finishing and not.
  support-notices-investigate.sh triage-batch <iso8601-utc> <lucene-query> [<iso> <query> ...]
      `triage` for EVERY candidate mail in ONE invocation, args given as pairs. Prefer
      this over N separate `triage` calls in an unattended run: N calls cost N tool
      round-trips and that, not the curl, is what exhausted leg A's timeout twice.
USAGE
  exit 2
}

cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
  graylog)
    query="${1:-}"; range="${2:-}"; limit="${3:-8}"
    [ -n "$query" ] && [ -n "$range" ] || usage
    [ -n "${GRAYLOG_PAT:-}" ] || { echo "GRAYLOG_PAT not set -- cannot query Graylog" >&2; exit 1; }
    stream="$(hr_config '.graylog.alertStreamId' '')"
    # Say WHY it failed, not just that it did. graylog-search.sh uses `curl -s` and exits 1
    # with an empty body, so a bare "graylog query failed" is what an unreachable host
    # looks like -- and the unattended leg then writes "Investigated: no" naming an error
    # that explains nothing. Confirmed 2026-09-03: the Graylog host is on the corporate
    # network, so with the VPN down every query times out (curl 28) and only this reachability
    # probe distinguishes that from a bad token or a malformed query.
    gl_err="$(mktemp)"
    raw="$(bash "$HOME/.claude/skills/ama-graylog-search/scripts/graylog-search.sh" \
      "$query" "$range" "$stream" "$limit" 2>"$gl_err")" || {
      why="$(tr -d '\r' < "$gl_err" | grep -v '^$' | tail -2 | tr '\n' ' ')"
      if [ -z "$why" ]; then
        host="$(hr_config '.graylog.host' '')"
        probe="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "$host/api/system/lbstatus" 2>&1)"
        case "$probe" in
          000*|*"timed out"*|*"Could not resolve"*|*"Connection refused"*)
            why="cannot reach the Graylog host ($host) -- VPN down or host offline: $probe" ;;
          *) why="empty response from Graylog (host reachable, probe returned $probe) -- check the token or the query" ;;
        esac
      fi
      rm -f "$gl_err"
      echo "graylog query failed: $why" >&2; exit 1; }
    rm -f "$gl_err"
    # Trim hard -- this output goes straight into a headless run's context.
    #
    # Two response shapes, both real on this Graylog: WITH a `fields` argument each row is
    # nested as {message:{timestamp,source,message,...}}; WITHOUT one the row is FLAT and
    # `.message` is the log text itself. Normalise before reading any field -- assuming
    # the nested shape cost the timestamps off every sampled row, and assuming the flat
    # one aborts the whole listing (and its match count) with "Cannot index string".
    # Newlines collapse to spaces rather than truncating at the first line: the useful
    # part of a .NET exception dump is on line 2, not line 1.
    printf '%s' "$raw" | jq -r '
      def flat: if (.message|type) == "object" then .message else . end;
      "total_matches: \(.total_results // 0)",
      "sampled: \(.messages | length)",
      (.messages[]? | flat as $m
        | "  \($m.timestamp // "?") \($m.source // "?") \(($m.message // "" | tostring) | split(([10]|implode)) | join(" ") | .[0:240])")
    '
    ;;
  pipeline)
    at="${1:-}"
    [ -n "$at" ] || usage
    [ -n "${BITBUCKET_API_KEY:-}" ] || { echo "BITBUCKET_API_KEY not set -- cannot check pipelines" >&2; exit 1; }
    org="$(hr_config_required '.bitbucket.org')" || exit 1
    email="$(hr_config_required '.user.email')" || exit 1
    at_s="$(date -u -d "$at" +%s 2>/dev/null)" || { echo "unparseable timestamp: $at" >&2; exit 1; }
    body="$(curl -sS -m 30 -u "${email}:${BITBUCKET_API_KEY}" \
      "https://api.bitbucket.org/2.0/repositories/${org}/<repository>-api-testing/pipelines/?sort=-created_on&pagelen=30")" || {
      echo "bitbucket query failed" >&2; exit 1; }
    # jq on this machine is built WITHOUT the date builtins (fromdateiso8601/todate are
    # "not defined") -- do the overlap arithmetic in bash instead of jq. Also note `$end`
    # is unusable as a jq variable name (reserved word), hence `$stop` naming elsewhere.
    hits=0
    oldest=''
    while IFS=$'\t' read -r created dur build trig state; do
      [ -n "$created" ] || continue
      st="$(date -u -d "${created%%.*}Z" +%s 2>/dev/null)" || continue
      if [ -z "$oldest" ] || [ "$st" -lt "$oldest" ]; then oldest="$st"; fi
      stop=$(( st + ${dur:-0} + 120 ))
      if [ "$at_s" -ge "$st" ] && [ "$at_s" -le "$stop" ]; then
        echo "OVERLAPS: build #$build trigger=$trig state=$state started=$created duration=${dur}s"
        hits=$((hits+1))
      fi
    done < <(printf '%s' "$body" | jq -r '.values[]? | [.created_on, (.duration_in_seconds // 0), .build_number, (.trigger.name // "?"), (.state.result.name // .state.name // "?")] | @tsv')
    if [ "$hits" -gt 0 ]; then :
    elif [ -z "$oldest" ]; then
      echo "INCONCLUSIVE: bitbucket returned no pipeline runs to check"
    elif [ "$at_s" -lt "$oldest" ]; then
      # The 30 most recent runs all START AFTER the instant asked about, so this window
      # never covered it -- absence of an overlap here proves nothing. Reporting it as a
      # clean "no overlap" would let a genuinely test-caused error be triaged as a live
      # app fault.
      echo "INCONCLUSIVE: the 30 most recent runs all start after $at -- window does not reach back that far"
    else
      echo "no api-testing pipeline run overlaps $at (checked the 30 most recent)"
    fi
    ;;
  triage)
    at="${1:-}"; query="${2:-}"; range="${3:-604800}"; glimit="${SN_GRAYLOG_LIMIT:-8}"
    [ -n "$at" ] && [ -n "$query" ] || usage
    self="${BASH_SOURCE[0]}"
    echo "== pipeline =="
    bash "$self" pipeline "$at" || echo "(pipeline check failed -- treat as INCONCLUSIVE)"
    echo "== graylog (last ${range}s) =="
    bash "$self" graylog "$query" "$range" "$glimit" || echo "(graylog check failed)"
    ;;
  triage-batch)
    # ONE round-trip for the WHOLE run. The expensive part of a check is the agent's tool
    # round-trip (2-3 min each on this machine under contention, harness-gaps.md), not the
    # curl -- so N mails via N `triage` calls costs N*3 min, and that is what blew leg A's
    # 900s and then 1500s ceilings with only 3 candidates (<harnessEpicKey>, 2026-09-01).
    # Looping HERE costs one round-trip total, whatever N is.
    #
    # Args are (iso8601-utc, lucene-query) PAIRS, quoted. Range is fixed at the `triage`
    # default rather than taken as a trailing arg: a trailing odd arg is ambiguous with a
    # dropped query, and silently investigating the wrong window is worse than not
    # offering the knob. Per-mail sampling stays small on purpose -- N mails of Graylog
    # rows all land in one headless leg's context.
    [ "$#" -ge 2 ] || usage
    export SN_GRAYLOG_LIMIT="${SN_GRAYLOG_LIMIT:-5}"
    n=0
    while [ "$#" -ge 2 ]; do
      n=$((n+1))
      echo "===== mail $n: $1 ====="
      bash "${BASH_SOURCE[0]}" triage "$1" "$2" || echo "(triage failed for mail $n -- treat as INCONCLUSIVE)"
      shift 2
    done
    [ "$#" -eq 0 ] || echo "WARNING: trailing unpaired argument ignored -- one mail was NOT investigated"
    ;;
  *) usage ;;
esac
