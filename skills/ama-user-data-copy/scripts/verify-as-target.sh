#!/usr/bin/env bash
# verify-as-target.sh -- log in AS THE TARGET (and as the source) through the real APIs and
# confirm what each account can actually see and open. Complements verify.sh (database truth)
# with the application's own view: lists, folder placement, every copied item opening 200.
# Usage: verify-as-target.sh <manifest.json>
# Needs a password for the target: only harness test users have one (credentials file), so
# in production (target = a real person) this prints SKIP and the check is the admin
# direct-URL open in verify.sh's notes. Read-only: GETs only.
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
M="${1:?usage: verify-as-target.sh <manifest.json>}"
ENV="$(jr .env "$M")"; FROM="$(jr .from.username "$M")"; TO="$(jr .to.username "$M")"
CREDS="$HOME/.claude/.ama-ui-credentials.json"
umask 077; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0; P() { if [ "$1" = 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fail=1; fi; }

known_user() { jq -e --arg e "$ENV" --arg u "$1" '.users[$e] | to_entries[] | select(.value==$u)' "$CREDS" >/dev/null 2>&1; }

check_user() { # $1 username  $2 role: target|source
  local U="$1" role="$2" tok="$TMP/tok-$2.json"
  if ! known_user "$U"; then echo "SKIP  $role $U: no harness credentials (real account) -- use the admin direct-URL open instead"; return; fi
  bash "$HERE/cognito-token.sh" "$ENV" "$U" "$tok" 2>/dev/null || { P 1 "$role $U: login"; return; }
  API() { bash "$HERE/api.sh" "$ENV" "$tok" "$@" 2>/dev/null; }
  local want_reports want_cohorts want_crs want_bands
  # deleted entries exist only in a move manifest (the whole account moves) -- never listed or openable
  if [ "$role" = target ]; then
    want_reports="$(jr '.reports[] | select(.deleted!=true) | .new' "$M")"; want_cohorts="$(jr '.cohorts[] | select(.flipped==true and .deleted!=true) | .new' "$M")"
    want_crs="$(jr '.cohortReports[] | select(.deleted!=true) | .new' "$M")"; want_bands="$(jr '.bands[] | select(.deleted!=true) | .new' "$M")"
  else
    want_reports="$(jr '.reports[] | select(.deleted!=true) | .old' "$M")"; want_cohorts="$(jr '.cohorts[] | select(.deleted!=true) | .old' "$M")"
    want_crs="$(jr '.cohortReports[] | select(.deleted!=true) | .old' "$M")"; want_bands="$(jr '.bands[] | select(.deleted!=true) | .old' "$M")"
  fi
  if [ "$role" = source ] && [ "$(jr '.mode // "copy"' "$M")" = move ]; then
    # after an owner switch the source must see NONE of it: not listed, not openable
    API GET /report/all | jq -r '.[]?.Id' | tr -d '\r' | tr 'A-Z' 'a-z' | sort > "$TMP/$role.reports"
    local left=0 n=0 opens=0; for id in $want_reports; do n=$((n+1)); grep -qx "${id,,}" "$TMP/$role.reports" && left=$((left+1)); API GET "/report/$id" >/dev/null 2>&1 && opens=$((opens+1)); done
    P $(( left > 0 )) "$role $U: none of the $n moved reports listed ($left still listed)"
    # by-id opens are INFO: Admin/UserManagement carry AccessAllReports (every harness test user has UserManagement),
    # so an elevated source opens ANY report by id -- a real account without those roles gets 403
    echo "INFO  $role $U: $opens of $n moved reports still open by id (expected >0 only for an Admin/UserManagement account)"
    API GET '/cohort/summary?pageSize=500&pageNumber=1' | jq -r '.items[]?.id // .items[]?.Id' | tr -d '\r' | tr 'A-Z' 'a-z' | sort > "$TMP/$role.cohorts"
    left=0; n=0; for id in $want_cohorts; do n=$((n+1)); grep -qx "${id,,}" "$TMP/$role.cohorts" && left=$((left+1)); done
    P $(( left > 0 )) "$role $U: none of the $n moved cohorts listed ($left still listed)"
    API GET '/cohort/report/summary?pageSize=500&pageNumber=1&ownership=0' | jq -r '.items[]?.id // .items[]?.Id' | tr -d '\r' | tr 'A-Z' 'a-z' | sort > "$TMP/$role.crs"
    left=0; n=0; for id in $want_crs; do n=$((n+1)); grep -qx "${id,,}" "$TMP/$role.crs" && left=$((left+1)); done
    P $(( left > 0 )) "$role $U: none of the $n moved cohort reports listed ($left still listed)"
    return
  fi
  # reports: listed + each opens
  API GET /report/all | jq -r '.[]?.Id' | tr -d '\r' | tr 'A-Z' 'a-z' | sort > "$TMP/$role.reports"
  local missing=0 n=0 open_fail=0
  for id in $want_reports; do n=$((n+1)); grep -qx "${id,,}" "$TMP/$role.reports" || missing=$((missing+1)); API GET "/report/$id" >/dev/null || open_fail=$((open_fail+1)); done
  P $(( missing + open_fail > 0 )) "$role $U: $n saved reports listed ($missing missing) and open ($open_fail failed)"
  # folders: every listed report reachable through the folder tree
  local home; home="$(API GET /report/user-folder | jr '.Folders[0].Id')"
  local infolder; infolder="$(API GET "/report/folder/$home" | jq -r 'if type=="array" then length else (.items|length) end' 2>/dev/null | tr -d '\r')"
  P $([ -n "$infolder" ] && [ "$infolder" != "null" ] && echo 0 || echo 1) "$role $U: Home folder lists $infolder item(s)"
  # cohorts
  API GET '/cohort/summary?pageSize=500&pageNumber=1' | jq -r '.items[]?.id // .items[]?.Id' | tr -d '\r' | tr 'A-Z' 'a-z' | sort > "$TMP/$role.cohorts"
  missing=0; n=0; local notdone=0
  for id in $want_cohorts; do n=$((n+1)); grep -qx "${id,,}" "$TMP/$role.cohorts" || missing=$((missing+1)); st="$(API GET "/cohort/$id" | jr '.progress.status // "x"')"; [ "$st" = "2" ] || notdone=$((notdone+1)); done
  P $(( missing + notdone > 0 )) "$role $U: $n cohorts listed ($missing missing), generation complete ($notdone not)"
  # cohort reports
  API GET '/cohort/report/summary?pageSize=500&pageNumber=1&ownership=0' | jq -r '.items[]?.id // .items[]?.Id' | tr -d '\r' | tr 'A-Z' 'a-z' | sort > "$TMP/$role.crs"
  missing=0; n=0; open_fail=0
  for id in $want_crs; do n=$((n+1)); grep -qx "${id,,}" "$TMP/$role.crs" || missing=$((missing+1)); API GET "/cohort/report/$id" >/dev/null || open_fail=$((open_fail+1)); done
  P $(( missing + open_fail > 0 )) "$role $U: $n cohort reports listed ($missing missing) and open ($open_fail failed)"
  # bands
  n=0; open_fail=0
  for id in $want_bands; do n=$((n+1)); API GET "/source/dynamic-column/$id" >/dev/null || open_fail=$((open_fail+1)); done
  P $(( open_fail > 0 )) "$role $U: $n bands open ($open_fail failed)"
  # received shares, if the run granted any
  local rs; rs="$(jq -r '(.receivedShares.reports // []) | length' "$M")"
  if [ "$role" = target ] && [ "$rs" != "0" ]; then
    missing=0
    for id in $(jr '.receivedShares.reports[].reportId' "$M"); do grep -qx "${id,,}" "$TMP/$role.reports" || missing=$((missing+1)); done
    P $(( missing > 0 )) "$role $U: $rs received report share(s) visible ($missing missing)"
  fi
}
check_user "$TO" target
check_user "$FROM" source
[ $fail -eq 0 ] && echo "verify-as-target: ALL PASS" || { echo "verify-as-target: FAILURES above" >&2; exit 1; }
