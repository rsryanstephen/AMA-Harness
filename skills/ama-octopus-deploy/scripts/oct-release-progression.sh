#!/usr/bin/env bash
# Can this Octopus release reach that environment? Prints the release's channel, the
# lifecycle's phases and the release's NextDeployments; with an environment id, exits 0 when
# it is offered (or already deployed there with Success) and 3 when it is not. Run it
# BEFORE any Production POST /deployments.
# Usage: oct-release-progression.sh <Releases-N> [Environments-N]
#   <qa> QA, -23 Staging, -24 Production.
# Why (PROJ-15801, 2026-10-14): a hotfix-channel release's lifecycle often has ONE
# Development phase (Staging auto, QA optional) and no Production phase at all -- the Lambda
# projects AND YourProduct_Exporter_Search_API_ECS (Projects-95, Hotfix = Lifecycles-44).
# Octopus refuses the prod POST ("has not been deployed to the required environments") and
# deploying QA does not unlock it. Production goes via the MASTER-channel release after the
# merge. deploy-lambda.sh runs this same dry-check before its delete-function; this is the
# standalone form for ECS and S3 projects. Exit: 0 reachable, 2 usage, 3 not reachable.
set -uo pipefail
REL="${1:-}"; ENV="${2:-}"
[ -n "$REL" ] || { sed -n 2,7p "$0"; exit 2; }
[ -n "${OCTOPUS_API_KEY:-}" ] || { echo "OCTOPUS_API_KEY not set"; exit 2; }
OCT="https://yourorg.octopus.app/api/Spaces-1"
oct() { curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$@" | tr -d '\r'; }

rel="$(oct "$OCT/releases/$REL")"
pid="$(printf '%s' "$rel" | jq -r '.ProjectId // empty')"
ch="$(printf '%s' "$rel" | jq -r '.ChannelId // empty')"
[ -n "$pid" ] && [ -n "$ch" ] || { echo "cannot read $REL (project/channel missing)"; exit 3; }
chj="$(oct "$OCT/channels/$ch")"
echo "release $(printf '%s' "$rel" | jq -r '.Version') project $pid $(oct "$OCT/projects/$pid" | jq -r '.Name') channel $ch $(printf '%s' "$chj" | jq -r '.Name')"
lc="$(printf '%s' "$chj" | jq -r '.LifecycleId // empty')"
[ -n "$lc" ] && [ "$lc" != null ] || lc="$(oct "$OCT/projects/$pid" | jq -r '.LifecycleId')"   # channel inherits the project lifecycle
oct "$OCT/lifecycles/$lc" | jq -r '"lifecycle \(.Name) (\(.Id))", (.Phases[] | "  phase \(.Name): auto=\((.AutomaticDeploymentTargets // []) | join(",")) optional=\((.OptionalDeploymentTargets // []) | join(","))")'
prog="$(oct "$OCT/releases/$REL/progression")"
next="$(printf '%s' "$prog" | jq -r '(.NextDeployments // []) | join(",")')"
echo "NextDeployments: ${next:-(none)}"
[ -n "$ENV" ] || exit 0

case ",$next," in *",$ENV,"*) echo "OK: $REL can be deployed to $ENV"; exit 0 ;; esac
# "Already deployed there" lives on the PROJECT progression, keyed by environment id.
already="$(oct "$OCT/projects/$pid/progression" | jq -r --arg e "$ENV" --arg r "$REL" \
  '[.Releases[]? | select(.Release.Id == $r) | (.Deployments[$e] // [])[] | select(.State == "Success")] | length')"
[ "${already:-0}" -gt 0 ] && { echo "OK: $REL already deployed to $ENV (Success)"; exit 0; }
echo "REFUSED: $REL cannot reach $ENV from channel $(printf '%s' "$chj" | jq -r '.Name') -- no such phase in its lifecycle."
echo "  Production route: merge to master, deploy the MASTER-channel release (ama-hotfix Step 4)."
exit 3
