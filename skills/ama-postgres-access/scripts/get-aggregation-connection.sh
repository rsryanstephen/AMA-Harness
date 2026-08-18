#!/usr/bin/env bash
# Resolve the aggregation-db (Redshift) connection string for one env from Octopus's
# library variable set, and print `export PG*=...` lines for `eval`. Password never
# printed by name/logged -- only inside the export line itself, which the caller must
# not echo back into chat. See ../SKILL.md "aggregation DB (Redshift) via Octopus".
#
# Usage: eval "$(bash get-aggregation-connection.sh <dev|qa|staging|production>)"

set -euo pipefail

env_arg="${1:?usage: get-aggregation-connection.sh <dev|qa|staging|production>}"
[ "$env_arg" = "dev" ] && env_arg="development"

lib="$HOME/.claude/hooks/lib-harness-repos.sh"
# shellcheck source=/dev/null
. "$lib"

: "${OCTOPUS_API_KEY:?OCTOPUS_API_KEY not set -- required to read the library variable set}"

server="$(hr_config_required '.octopus.serverUrl')" || exit 1
space="$(hr_config_required '.octopus.spaceId')" || exit 1
env_id="$(hr_config ".octopus.environmentIds.${env_arg}" '')"
if [ -z "$env_id" ]; then
  echo "get-aggregation-connection.sh: unknown env '$env_arg' -- no octopus.environmentIds.$env_arg in harness-config.json" >&2
  exit 1
fi
var_set_id="$(hr_config '.octopus.aggregationDbVariableSetId' 'LibraryVariableSets-21')"

value="$(curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" \
  "$server/api/$space/variables/variableset-$var_set_id" \
  | jq -r --arg env "$env_id" '
      .Variables[] |
      select(.Name == "aggregation-database-connection-string") |
      select(.Scope.Environment[0] == $env) |
      .Value // empty
    ')"

if [ -z "$value" ]; then
  echo "get-aggregation-connection.sh: no value for env '$env_arg' ($env_id) in $var_set_id -- confirm the variable set id and scope" >&2
  exit 1
fi

# Trim whitespace around keys/values -- dev scope's value has a space after every ';'.
kv() {
  printf '%s' "$value" | tr ';' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -i "^$1=" | head -1 | sed "s/^[^=]*=//"
}

printf 'export PGHOST=%q\n' "$(kv Server)"
printf 'export PGPORT=%q\n' "$(kv Port)"
printf 'export PGDATABASE=%q\n' "$(kv Database)"
printf 'export PGUSER=%q\n' "$(kv UID)"
printf 'export PGPASSWORD=%q\n' "$(kv PWD)"
printf 'export PGSSLMODE=require\n'
