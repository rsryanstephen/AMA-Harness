#!/usr/bin/env bash
# Which Lambda does each cache-update step REALLY run? Read it from the state machine, not
# from the step name. Usage: resolve-cacheupdate-lambda.sh <env> [step]
#   env: qa | staging | production      step: e.g. Search, SqlTemplates (omit for all)
#
# The failing component is almost never the Lambda whose name matches the step -- "Search"
# runs selenium-crawlers-cacheupdate, "SqlTemplates" runs export-cacheupdate. That mapping
# used to be a hand-maintained table in CACHE-UPDATE-DEBUGGING.md next to a recipe that
# wrote the definition to /tmp/def.json and grepped it. The definition is the source of
# truth; this derives the table from it every time, so it cannot go stale.
set -uo pipefail
export MSYS_NO_PATHCONV=1
ENV="${1:?usage: resolve-cacheupdate-lambda.sh <env> [step]}"
STEP="${2:-}"
. "$HOME/.claude/hooks/lib-harness-repos.sh"
ACCT="$(hr_config_required '.aws.accountNumber')" || exit 1
REGION="$(hr_config '.aws.region' 'us-east-1')"
ARN="arn:aws:states:$REGION:$ACCT:stateMachine:${ENV}-v1-cacheupdate-statemachine"

def="$(PYTHONUTF8=1 aws stepfunctions describe-state-machine --state-machine-arn "$ARN" --query definition --output text 2>&1)" \
  || { echo "describe-state-machine failed: $def" >&2; exit 1; }

# Walk every state (including nested Branches/Iterators); print task states that invoke a
# Lambda, as "<state name>\t<function name>". FunctionName may sit in Parameters (optimized
# lambda:invoke integration) or be the Resource ARN itself (direct invoke).
printf '%s' "$def" | jq -r --arg step "$STEP" '
  def states: .. | objects | select(has("States")) | .States | to_entries[];
  [states
    | .key as $name
    | .value
    | select(.Type == "Task")
    | select((.Resource // "") | test("lambda"))
    | ((if ((.Resource // "") | startswith("arn:aws:lambda:")) then .Resource else (.Parameters.FunctionName // "") end)) as $fn
    | select($fn != "")
    | {name: $name, fn: ($fn | sub("^arn:aws:lambda:[^:]*:[0-9]*:function:"; "") | sub(":\\$LATEST$"; "")),
       mode: (if ((.Resource // "") | test("waitForTaskToken")) then " (waits for task token)" else "" end)}]
  | (if $step == "" then . else map(select(.name | test($step; "i"))) end)
  | .[] | "\(.name)\t\(.fn)\(.mode)"' | sort -u | awk -F'\t' '{printf "%-40s -> %s\n", $1, $2}'
