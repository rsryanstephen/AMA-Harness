#!/usr/bin/env bash
# Deploy ONE Lambda project release via Octopus, safely. Replaces hand-rolled delete+POST.
# Usage: deploy-lambda.sh <Environments-NN> <qa|staging|production> <Releases-N> <function-suffix> [--expect-env NAME]
#   function = <prefix>-v1-<suffix>. Caller sets gate hatches (AMA_PREFLIGHT_ACK etc.); none here.
# Order, each step learned 2026-10-14 (release 130 / hotfix):
#   1. DRY-CHECK before touching anything: target env must be in the release's
#      /releases/<id>/progression .NextDeployments, OR the project's /projects/<id>/progression
#      shows this release already deployed there (.Releases[].Deployments[<env>] -- keyed by
#      environment id; the release-level .Phases[].Deployments is keyed by index, don't use it).
#      Shapes verified live 2026-10-14. These Lambda projects' Hotfix-channel lifecycle ENDS at
#      QA+Staging (no Production phase at all -- 21532 showed NextDeployments [] even after both),
#      so Production is reachable only from the master-channel release. A refused POST AFTER
#      delete-function left two prod Lambdas absent ~10 min. Not reachable -> print why, exit 3,
#      NOTHING deleted.
#   2. record the previous successful release for this env (restore handle), delete-function.
#   3. POST /deployments; a refusal prints .ErrorMessage AND .Errors[] (message alone is generic).
#   4. wait the ServerTask; Failed + raw log matching worker death/contention (package lock,
#      ReadAsync cancelled, plugin load/start timeout) -> re-POST ONCE, wait again.
#   5. after Success: function exists + State Active; --expect-env NAME present (name only, never values).
#   6. any failure after the delete: loud "FUNCTION IS ABSENT" + the release id to redeploy; exit 1.
# ~4 concurrent Lambda deploys is the practical cap (shared Octopus worker; 28 at once broke 2).
# Exit: 0 ok, 1 failed after delete, 2 usage, 3 refused pre-delete (nothing changed).
set -uo pipefail
case "${1:-}" in -h|--help|"") sed -n 2,17p "$0"; [ -n "${1:-}" ] && exit 0 || exit 2;; esac
[ $# -ge 4 ] || { sed -n 2,4p "$0"; exit 2; }
ENV="$1"; PFX="$2"; REL="$3"; FN="$PFX-v1-$4"; shift 4
EXPECT=""; [ "${1:-}" = "--expect-env" ] && EXPECT="${2:-}"
[ -n "${OCTOPUS_API_KEY:-}" ] || { echo "OCTOPUS_API_KEY not set"; exit 2; }
OCT="https://yourorg.octopus.app/api/Spaces-1"; RG=us-east-1
oct() { curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$@"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
DELETED=0; PREV="unknown"

fail_after_delete() {
  echo "FAIL: $1"
  if [ "$DELETED" = 1 ]; then
    echo "!!! $FN IS ABSENT in $PFX. Restore NOW: redeploy previous release $PREV to $ENV (or this one after fixing)."
  fi
  exit 1
}

# 1. reachability dry-check (release progression for NextDeployments; project progression for
#    "already deployed there" -- the only one of the two keyed by environment id)
prog="$(oct "$OCT/releases/$REL/progression" | tr -d '\r')"
if ! printf '%s' "$prog" | jq -e . >/dev/null 2>&1; then echo "REFUSED(no deletes done): cannot read progression for $REL"; exit 3; fi
pid="$(oct "$OCT/releases/$REL" | jq -r '.ProjectId // empty' | tr -d '\r')"
[ -n "$pid" ] || { echo "REFUSED(no deletes done): cannot read $REL"; exit 3; }
pprog="$(oct "$OCT/projects/$pid/progression" | tr -d '\r')"
next="$(printf '%s' "$prog" | jq -r --arg e "$ENV" '[(.NextDeployments // [])[] | select(.==$e)] | length' | tr -d '\r')"
already="$(printf '%s' "$pprog" | jq -r --arg e "$ENV" --arg r "$REL" '[.Releases[]? | select(.Release.Id == $r) | (.Deployments[$e] // [])[]] | length' | tr -d '\r')"
if [ "$(( ${next:-0} + ${already:-0} ))" -lt 1 ]; then
  echo "REFUSED(no deletes done): $REL cannot reach $ENV. NextDeployments: $(printf '%s' "$prog" | jq -r '(.NextDeployments // []) | join(",")' | tr -d '\r')"
  echo "  A hotfix-channel release of these Lambda projects never reaches Production (lifecycle ends at QA+Staging); merge to master and deploy the master-channel release."
  exit 3
fi

# 2. restore handle = newest Success release already on this env (not this one), then delete
PREV="$(printf '%s' "$pprog" | jq -r --arg e "$ENV" --arg r "$REL" \
  '[.Releases[]? | select(.Release.Id != $r) | select([(.Deployments[$e] // [])[] | select(.State=="Success")] | length > 0) | .Release.Id][0] // "unknown"' | tr -d '\r')"
echo "previous successful release on $ENV: $PREV"
if aws lambda delete-function --region $RG --function-name "$FN" 2>"$T/del.err"; then DELETED=1; echo "deleted $FN"
elif grep -q ResourceNotFound "$T/del.err"; then DELETED=1; echo "$FN already absent"
else echo "DELETE-FAIL $(head -c 200 "$T/del.err")"; exit 3; fi

# 3-4. POST + wait, one automatic retry on worker death/contention
post() {
  r="$(oct -X POST -H "Content-Type: application/json" -d "{\"ReleaseId\":\"$REL\",\"EnvironmentId\":\"$ENV\"}" "$OCT/deployments" | tr -d '\r')"
  TASK="$(printf '%s' "$r" | jq -r '.TaskId // empty' | tr -d '\r')"
  if [ -z "$TASK" ]; then
    fail_after_delete "POST refused: $(printf '%s' "$r" | jq -r '"\(.ErrorMessage) | \((.Errors // []) | join(" | ") | .[0:600])"' | tr -d '\r')"
  fi
  echo "deployment $(printf '%s' "$r" | jq -r .Id | tr -d '\r') task $TASK"
}
wait_task() {
  local i st
  for i in $(seq 1 120); do
    st="$(oct "$OCT/tasks/$TASK" | jq -r 'if .IsCompleted then .State else "running" end' | tr -d '\r')"
    [ "$st" != running ] && { STATE="$st"; return; }
    sleep 15
  done
  STATE=Timeout
}
post; wait_task
if [ "$STATE" = Failed ] && oct "$OCT/tasks/$TASK/raw" | grep -qE 'Failed to release package lock|ReadAsync operation was cancelled|Could not load plugin|timeout while waiting for plugin to start'; then
  echo "worker death/contention detected -- re-POST once"; post; wait_task
fi
[ "$STATE" = Success ] || fail_after_delete "task $TASK ended $STATE"

# 5. artifact exists + Active (+ env var name)
for i in $(seq 1 12); do
  cfg="$(aws lambda get-function-configuration --region $RG --function-name "$FN" 2>/dev/null | tr -d '\r')"
  [ "$(printf '%s' "$cfg" | jq -r '.State // empty' | tr -d '\r')" = Active ] && break
  sleep 5
done
[ "$(printf '%s' "$cfg" | jq -r '.State // empty' | tr -d '\r')" = Active ] || fail_after_delete "$FN missing or not Active after Success"
if [ -n "$EXPECT" ]; then
  printf '%s' "$cfg" | jq -e --arg n "$EXPECT" '(.Environment.Variables // {}) | has($n)' >/dev/null || fail_after_delete "$FN lacks env var name $EXPECT"
fi
echo "OK $REL -> $ENV: $FN Active${EXPECT:+, env var $EXPECT present}. Run verify-lambda-artifact.sh next."
