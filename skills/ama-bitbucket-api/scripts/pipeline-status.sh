#!/usr/bin/env bash
# What did a branch's pipeline do? Usage:
#   pipeline-status.sh <repo> <branch>                   # newest pipeline on that branch
#   pipeline-status.sh <repo> <branch> --sha <commit>    # the pipeline for EXACTLY that commit
#   pipeline-status.sh <repo> <branch> --wait [--max-minutes N]   # poll newest to terminal
# Prints: build=<n> state=<COMPLETED|IN_PROGRESS|...> result=<SUCCESSFUL|FAILED|...> sha=<hash> created=<ts>
# Exit 0 = COMPLETED/SUCCESSFUL, 1 = anything else (incl. no pipeline), 2 = wait timed out,
#      3 = could not reach the API at all (DNS/transport) -- NOT a verdict about the build.
#
# --sha is the check ama-deploy-release makes before a Production deploy: "prove the exact
# release-branch tip master merged has a SUCCESSFUL pipeline" -- its own text says a miss
# means STOP. It was a hand-assembled curl with a pasted SHA; the highest-consequence check
# in the release path deserved better than that.
#
# False-negative trap, handled here: a pipeline can be missing from the API for a short
# while after the push. "Not found" is retried a few times before it is believed.
set -uo pipefail
. "$(dirname "$0")/lib-bitbucket.sh"

REPO="${1:?usage: pipeline-status.sh <repo> <branch> [--sha <hash>] [--wait] [--max-minutes N]}"
BRANCH="${2:?usage: pipeline-status.sh <repo> <branch> [--sha <hash>] [--wait] [--max-minutes N]}"
shift 2
SHA=""; WAIT=0; MAX_MIN=60
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) SHA="${2:?}"; shift 2 ;;
    --wait) WAIT=1; shift ;;
    --max-minutes) MAX_MIN="${2:?}"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done
SLUG="$(bb_slug "$REPO")"
ENC_BRANCH="$(printf '%s' "$BRANCH" | sed 's#/#%2F#g')"

# prints the chosen pipeline's JSON or nothing.
# Exit 0 = the API answered (empty output then genuinely means "no such pipeline").
# Exit 2 = could NOT ask -- transport/DNS/garbage body. Not the same thing, and telling the
#          two apart is the whole reason this returns a status.
# Exit 4 = the API answered with an error document (bad token/slug). Not transient.
#
# Confirmed live 2026-09-26: a VPN resolver blip made curl exit 6 mid-wait, fetch returned
# empty, and this script announced "pipeline vanished from the API" for build 197 -- which
# was running fine and went on to succeed. A session trusting that would re-push or re-run a
# build already in flight. "I could not ask" must never read as "the answer is no"; every
# caller (deploy, hotfix, release-cut, version-sync) was exposed to it.
fetch() {
  local j rc
  j="$(bb_get "$BB_API/$SLUG/pipelines/?target.ref_name=$ENC_BRANCH&sort=-created_on&pagelen=20" 2>/dev/null)"
  rc=$?
  [ "$rc" -ne 0 ] && return 2
  if printf '%s' "$j" | jq -e 'objects | .type? == "error"' >/dev/null 2>&1; then
    printf '%s' "$j" | jq -r '"API ERROR: \(.error.message // "unknown")"' >&2
    return 4
  fi
  printf '%s' "$j" | jq -e 'objects | has("values")' >/dev/null 2>&1 || return 2
  if [ -n "$SHA" ]; then
    printf '%s' "$j" | jq -c --arg s "$SHA" '[.values[]? | select(.target.commit.hash | startswith($s))] | first // empty'
  else
    printf '%s' "$j" | jq -c '.values[0] // empty'
  fi
}

show() {
  printf '%s' "$1" | jq -r '"build=\(.build_number) state=\(.state.name) result=\(.state.result.name // .state.stage.name // "-") sha=\(.target.commit.hash[0:12]) created=\(.created_on)"'
}

p=""; frc=0
for i in 1 2 3 4; do
  p="$(fetch)"; frc=$?
  [ "$frc" -eq 4 ] && exit 1
  [ "$frc" -eq 0 ] && [ -n "$p" ] && break
  [ "$i" -lt 4 ] && sleep 15
done
if [ -z "$p" ]; then
  if [ "$frc" -eq 2 ]; then
    # Deliberately NOT "no pipeline": we never got an answer, so we know nothing about
    # whether one exists. Saying otherwise is what sent a session chasing a phantom.
    echo "COULD NOT REACH api.bitbucket.org for $SLUG $BRANCH${SHA:+ at $SHA} (4 tries over 45s) -- transport/DNS, NOT a missing pipeline. Re-check once the network is back; see commit-ticket's DNS section."
    exit 3
  fi
  echo "NO PIPELINE for $SLUG $BRANCH${SHA:+ at $SHA} (after 4 tries over 45s)"; exit 1
fi

deadline=$(( $(date +%s) + MAX_MIN*60 ))
while :; do
  state="$(printf '%s' "$p" | jq -r '.state.name')"
  if [ "$state" = "COMPLETED" ] || [ "$WAIT" = "0" ]; then
    show "$p"
    [ "$(printf '%s' "$p" | jq -r '.state.result.name // ""')" = "SUCCESSFUL" ] && exit 0
    exit 1
  fi
  [ "$(date +%s)" -ge "$deadline" ] && { echo "TIMED OUT: $(show "$p")"; exit 2; }
  echo "[$(date -u +%H:%M:%SZ)] $(show "$p")"
  sleep 30
  np="$(fetch)"; frc=$?
  if [ "$frc" -ne 0 ]; then
    # Unreachable, or an API error. Either way we did not learn anything new -- hold the
    # last known state and keep waiting. The deadline above still bounds the whole wait, so
    # a genuinely dead network ends as TIMED OUT rather than as a false "vanished".
    unreachable=$((${unreachable:-0} + 1))
    echo "[$(date -u +%H:%M:%SZ)] could not reach api.bitbucket.org (attempt $unreachable) -- last known: $(show "$p")"
    continue
  fi
  [ -n "$np" ] || { echo "pipeline vanished from the API"; exit 1; }
  p="$np"
done
