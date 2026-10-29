#!/usr/bin/env bash
# Every YourProduct_Exporter_* Octopus project: which of its releases reached one
# environment. Usage: verify-octopus-env-deploys.sh <Environments-N> [YYYY-MM-DD]
#   <qa> QA | <staging> Staging | <production> Production
#   optional date = the cut/deploy date. Only releases ASSEMBLED that day are judged.
#
# WHY THIS EXISTS -- a green Bitbucket pipeline does NOT mean the deploy happened.
# The pipeline's last step only CREATES the Octopus release; Octopus then deploys it
# separately and can fail on its own. Hit live on the release/130.0.0 cut (2026-09-15):
# all 17 builds SUCCESSFUL and every ECS service steady on the new image, while
# YourProduct_Exporter_CacheUpdate_UpdateCacheState_Lambda's Staging deploy sat Failed
# (Terraform "timeout while waiting for plugin to start" on the dynamic worker). Staging
# ran 3 cache-update Lambdas on new code and 1 on the previous release's. Nothing in the
# build check or the ECS check can see that -- a Lambda-only project has no service to
# look steady.
#
# LOOK AT EVERY RELEASE FROM THAT DAY, NOT JUST THE NEWEST. The first version of this
# script took .Releases[0] and was wrong in both directions. Within hours of the 130 cut,
# ordinary develop activity had minted newer Testing-channel releases for five projects,
# and the script reported every one of them as a Staging failure -- noise. The dangerous
# half is the other one: a newer Testing release sitting on top would have HIDDEN a failed
# Release-channel deploy underneath it. Filter by assembled date, keep the channel, and
# judge only releases that were actually sent to this environment.
set -uo pipefail

ENVID="${1:?usage: verify-octopus-env-deploys.sh <Environments-N> [YYYY-MM-DD]}"
WHEN="${2:-}"

. "$HOME/.claude/hooks/lib-harness-repos.sh"
S="$(hr_config_required '.octopus.serverUrl')" || exit 1
SPACE="$(hr_config_required '.octopus.spaceId')" || exit 1
H="X-Octopus-ApiKey: ${OCTOPUS_API_KEY:?OCTOPUS_API_KEY not set}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sS -H "$H" "$S/api/$SPACE/projects/all" \
  | jq -r '.[] | select(.Name | startswith("YourProduct_Exporter_")) | "\(.Id)\t\(.Name)"' > "$TMP/projects.txt"

: > "$TMP/sweep.txt"
while IFS=$'\t' read -r PID PNAME; do
  [ -n "$PID" ] || continue
  curl -sS -H "$H" "$S/api/$SPACE/projects/$PID/progression" \
    | jq -r --arg e "$ENVID" --arg p "$PNAME" \
        '.Releases[]? | "\($p)\t\(.Release.Version)\t\(.Channel.Name // "?")\t\(.Release.Assembled)\t\(.Deployments[$e][0].State // "NO_DEPLOYMENT")"' \
    >> "$TMP/sweep.txt"
done < "$TMP/projects.txt"

if [ -z "$WHEN" ]; then
  awk -F'\t' '{printf "%-56s %-10s %-9s %-28s %s\n", $1, $2, $3, $4, $5}' "$TMP/sweep.txt"
  exit 0
fi

BAD="$(awk -F'\t' -v w="$WHEN" '$4 ~ "^"w && $5 != "Success" && $5 != "NO_DEPLOYMENT" {printf "%-56s %-10s %-9s %s\n", $1, $2, $3, $5}' "$TMP/sweep.txt")"

echo "--- releases assembled $WHEN that were deployed to $ENVID ---"
awk -F'\t' -v w="$WHEN" '$4 ~ "^"w && $5 != "NO_DEPLOYMENT" {printf "%-56s %-10s %-9s %s\n", $1, $2, $3, $5}' "$TMP/sweep.txt"

echo "--- NOT Success (the bucket that matters) ---"
if [ -n "$BAD" ]; then printf '%s\n' "$BAD"; else echo "(none)"; fi

# Assembled that day but never sent to this environment. Expected for a channel that does
# not target it -- a Testing-channel release during a Staging sweep is develop work headed
# for QA. Information, not a failure. Still worth scanning: a RELEASE-channel row here
# means the deploy was never even attempted, which no other check would show you.
echo "--- assembled $WHEN, no deployment to $ENVID (normal for Testing; investigate a Release row) ---"
awk -F'\t' -v w="$WHEN" '$4 ~ "^"w && $5 == "NO_DEPLOYMENT" {printf "%-56s %-10s %-9s\n", $1, $2, $3}' "$TMP/sweep.txt"

[ -n "$BAD" ] && exit 1
exit 0
