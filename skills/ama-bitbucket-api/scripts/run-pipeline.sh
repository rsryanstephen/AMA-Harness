#!/usr/bin/env bash
# Trigger a Bitbucket custom pipeline, poll it to a terminal state, summarise its junit
# results. Usage: run-pipeline.sh <repo> <custom-pattern> [ref=master] [--no-wait] [--max-minutes N] [KEY=VALUE ...]
#   e.g. run-pipeline.sh api-testing qa            # the pre-cut QA gate
#        run-pipeline.sh api-testing staging       # before a Production deploy
#        run-pipeline.sh api-testing production    # Step 5a (business-hours gate applies)
#        run-pipeline.sh pipelines build-image master IMAGE_VERSION=35   # pipeline with `variables:`
# Trailing KEY=VALUE args become the POST's `variables` array -- a custom pipeline declared
# with `- variables: [...]` otherwise runs with every value empty and fails its own guards
# (PROJ-15425, 2026-09-17).
# Exit 0 = COMPLETED/SUCCESSFUL with zero failed/errored tests; 1 = failed; 2 = timed out.
#
# This loop -- trigger, poll, read the junit report -- was written out in prose at five
# sites across ama-cut-release-branch and ama-deploy-release in four different shapes, and
# hand-executed every time. The test-report numbers come from Bitbucket's test_reports
# endpoint, not from downloading junit.xml.
#
# The business-hours gate on the `production*` selectors is NOT this script's job; it fires
# on the POST inside this script exactly as it would on an inline curl (the pattern is in
# the command text as an argument), so a production trigger inside the window is still
# denied without AMA_ALLOW_PROD_API_TESTS=1.
set -uo pipefail
. "$(dirname "$0")/lib-bitbucket.sh"

REPO="${1:?usage: run-pipeline.sh <repo> <custom-pattern> [ref] [--no-wait] [--max-minutes N]}"
PATTERN="${2:?usage: run-pipeline.sh <repo> <custom-pattern> [ref] [--no-wait] [--max-minutes N]}"
shift 2
REF="master"; WAIT=1; MAX_MIN=120; VARS='[]'
while [ $# -gt 0 ]; do
  case "$1" in
    --no-wait) WAIT=0; shift ;;
    --max-minutes) MAX_MIN="${2:?}"; shift 2 ;;
    [A-Za-z_]*=*) VARS="$(printf '%s' "$VARS" | jq -c --arg k "${1%%=*}" --arg v "${1#*=}" '. + [{key:$k,value:$v}]')"; shift ;;
    *) REF="$1"; shift ;;
  esac
done
SLUG="$(bb_slug "$REPO")"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
jq -n --arg r "$REF" --arg p "$PATTERN" --argjson vars "$VARS" \
  '{target:{type:"pipeline_ref_target",ref_type:"branch",ref_name:$r,selector:{type:"custom",pattern:$p}}}
   + (if ($vars|length) > 0 then {variables:$vars} else {} end)' > "$TMP/body.json"

resp="$(bb_post "$BB_API/$SLUG/pipelines/" -d "@$TMP/body.json")"
UUID="$(printf '%s' "$resp" | jq -r '.uuid // empty')"
BUILD="$(printf '%s' "$resp" | jq -r '.build_number // empty')"
if [ -z "$UUID" ]; then
  echo "TRIGGER FAILED for $SLUG custom:$PATTERN on $REF:" >&2
  printf '%s\n' "$resp" | jq -r '.error.message // .' >&2 2>/dev/null || printf '%s\n' "$resp" >&2
  exit 1
fi
echo "triggered $SLUG custom:$PATTERN on $REF -> build #$BUILD"
echo "  https://bitbucket.org/$BB_ORG/$SLUG/pipelines/results/$BUILD"
[ "$WAIT" = "1" ] || exit 0

deadline=$(( $(date +%s) + MAX_MIN*60 ))
PU="$(bb_enc_uuid "$UUID")"
while :; do
  j="$(bb_get "$BB_API/$SLUG/pipelines/$PU")"
  state="$(printf '%s' "$j" | jq -r '.state.name // "UNKNOWN"')"
  result="$(printf '%s' "$j" | jq -r '.state.result.name // .state.stage.name // ""')"
  if [ "$state" = "COMPLETED" ]; then
    dur="$(printf '%s' "$j" | jq -r '.duration_in_seconds // 0')"
    echo "build #$BUILD COMPLETED/$result in ${dur}s"
    summary="$(bb_junit "$SLUG" "$UUID")"
    printf '%s\n' "$summary"
    failed="$(printf '%s' "$summary" | tail -1 | sed -n 's/.*failed=\([0-9]*\) errors=\([0-9]*\).*/\1+\2/p')"
    [ "$result" = "SUCCESSFUL" ] && [ "$((failed))" -eq 0 ] && exit 0
    exit 1
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "TIMED OUT after ${MAX_MIN}m -- build #$BUILD still $state/$result"; exit 2
  fi
  echo "[$(date -u +%H:%M:%SZ)] build #$BUILD $state ${result:+/$result}"
  sleep 30
done
