#!/usr/bin/env bash
# usage: ai-query.sh <env: qa|staging|production> <kql-file>   -> TSV (header + rows)
# Auth: az CLI login (az account get-access-token) by default; if APPINSIGHTS_API_KEY is set,
# uses that instead (x-api-key header, read-telemetry key from the resource's "API Access" blade).
# appId per env comes from harness-config.json .azure.appInsights.<env>.appId (not secret).
set -uo pipefail
env_="${1:?usage: ai-query.sh <qa|staging|production> <kql-file>}"; q="${2:?kql file}"
CFG="$HOME/.claude/harness-config.json"
app=$(jq -r --arg e "$env_" '.azure.appInsights[$e].appId // empty' "$CFG")
[ -n "$app" ] || { echo "no .azure.appInsights.$env_.appId in harness-config.json" >&2; exit 1; }
[ -f "$q" ] || { echo "kql file not found: $q" >&2; exit 1; }
body=$(mktemp); jq -Rs '{query: .}' "$q" > "$body"
hdr=$(mktemp)
if [ -n "${APPINSIGHTS_API_KEY:-}" ]; then
  printf 'x-api-key: %s\n' "$APPINSIGHTS_API_KEY" > "$hdr"
else
  tok=$(az account get-access-token --resource https://api.applicationinsights.io --query accessToken -o tsv 2>/dev/null)
  [ -n "$tok" ] || { echo "az not logged in: run 'az login --use-device-code' (or set APPINSIGHTS_API_KEY)" >&2; rm -f "$body" "$hdr"; exit 1; }
  printf 'Authorization: Bearer %s\n' "$tok" > "$hdr"
fi
curl -sS -H @"$hdr" -H "Content-Type: application/json" -d @"$body" \
  "https://api.applicationinsights.io/v1/apps/$app/query" \
  | jq -r 'if .error then "ERROR: \(.error.message) \(.error.innererror.message // "")" else (.tables[0].columns|map(.name)|@tsv), (.tables[0].rows[]|@tsv) end'
rc=$?; rm -f "$body" "$hdr"; exit $rc
