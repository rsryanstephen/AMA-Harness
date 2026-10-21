#!/usr/bin/env bash
# dispatch: fail-closed-on-timeout -- a dispatcher timeout DENIES instead of skipping (hooks/dispatch.sh, 2026-10-15).
# PreToolUse hook (Bash|PowerShell). Denies triggering a PRODUCTION Octopus deployment
# inside the prohibited window: Mon-Fri, 9am-5pm Eastern.
#
# Set by explicit user instruction 2026-09-09: "Update the harness to not deploy to
# production during US business hours unless specifically overridden by the user."
#
# WHY A GATE AND NOT PROSE. The same instruction came with a live failure of the prose
# route. Asked whether a Production cohort-cleanup deploy could still make the window, the
# agent asserted "it's about 14:55 UTC now, so you have roughly an hour before U.S.
# business hours" -- inventing a window start of ~16:00 UTC and never resolving ET at all.
# 14:55 UTC was 10:55 ET: an hour and a half INSIDE the window, which had opened before the
# claim was made. Nothing in the harness fed that bad time; the agent did UTC arithmetic in
# its head against a start time it made up. ama-deploy-release carried the correct ET
# recipe, but scoped to Step 5a's api-testing trigger, so it never governed the deploy.
#
# This is the same lesson prod-api-test-window-gate.sh already records for the API-test
# pipelines, one step further along: an unresolved clock plus a rule an agent must remember
# to apply is not a control, and here the thing it fails to stop is a production deploy.
#
# ET is resolved through hooks/lib-et-now.sh (python zoneinfo, real tzdata) -- never `TZ=`
# (git-bash ignores it) and never a hardcoded UTC offset (9:00 ET is 13:00 UTC only under
# EDT; it is 14:00 UTC in winter).
#
# FAILS CLOSED, like prod-api-test-window-gate.sh and unlike the network-dependent gates
# here: the failure mode this gate exists to stop IS a wrong or unreadable clock, so
# treating "I could not read the time" as "go ahead" would reproduce the defect exactly.
#
# Escape hatch: AMA_ALLOW_PROD_DEPLOY=1 in the environment -- deliberately an env var the
# USER sets, and deliberately distinct from AMA_ALLOW_PROD_API_TESTS (clearing one must not
# silently clear the other). Per hotfix-version-claimed-gate.sh's deadlock lesson, a signal
# the skill itself tells the agent to emit is no signal at all.
set -u

payload="$(cat)"

# Cheap needle on the RAW payload before any jq fork (precedent inplace-edit-gate.sh).
# BOTH needles are required: the wrapper-script form (`octo-deploy-release.sh Releases-X
# <production>`) never contains the word "deployments" -- it POSTs from inside the script
# -- so a `*deployments*`-only prefilter exited before detection ever ran and allowed a
# production deploy straight through. Caught by the positional-form test case, not by
# reading the code. `deploy-lambda.sh` likewise (invisible here 2026-10-14 -> 15).
case "$payload" in *deployments*|*octo-deploy*|*deploy-lambda*) : ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0

# Region selection + detection are shared with octopus-lambda-delete-gate.sh. Both gates
# previously carried their own copy of a matcher that joined the POST verb and the
# endpoint with `.*`; grep -P cannot span a newline, so an ordinary multi-line curl
# matched neither alternative and BOTH gates stayed silent through a real deploy
# (release/130.0.0 Staging, 2026-09-15). Heredoc bodies are still DATA by default -- see
# lib-octopus-deploy-detect.sh for why, and for the one exception that shape needed.
. "$HOME/.claude/hooks/lib-octopus-deploy-detect.sh" 2>/dev/null || exit 0
head_region="$(octo_scan_region "$command")"
octo_is_deploy_post "$head_region" || exit 0

CONFIG="$HOME/.claude/harness-config.json"
prod_env="<production>"
[ -f "$CONFIG" ] && prod_env="$(jq -r '.octopus.environmentIds.production // "<production>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
[ -n "$prod_env" ] || prod_env="<production>"

# The JSON body is often embedded in a double-quoted -d argument, so its quotes arrive
# backslash-escaped (\"EnvironmentId\":\"...\"). Strip those before matching.
normalized="$(printf '%s' "$head_region" | sed 's/\\"/"/g')"

# Match the BARE environment literal anywhere, not just the "EnvironmentId":"..." JSON key
# form. octo-deploy-release.sh takes the env id as a POSITIONAL argument and writes the body
# to a file, so `octo-deploy-release.sh Releases-X <production>` contains no JSON key at
# all. octopus-prod-deploy-ticket-sweep-reminder.sh matched only the key form and therefore
# never fired for this session's script-driven deploys.
if printf '%s' "$normalized" | grep -qF "$prod_env"; then
  target="prod"
elif printf '%s' "$normalized" | grep -qE 'Environments-[0-9]+'; then
  # A non-production environment is named explicitly -- QA/Staging are none of this gate's
  # business, deploy them whenever.
  exit 0
else
  # A deployments POST whose target environment is nowhere in the command text: built from
  # a variable, or read from a file. Cannot be cleared as non-production, and an opaque
  # production deploy is precisely what must not slip through, so fail closed.
  target="opaque"
fi

deny() {
  jq -cn --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

if [ "$target" = "opaque" ]; then
  deny "This looks like an Octopus deployment POST, but no environment id appears in the command text, so it cannot be cleared as non-production. Make the environment explicit in the command (pass the literal \"Environments-NN\" rather than building the body from a variable or a pre-written file) and re-run -- then this gate can tell a Staging deploy from a Production one and will only apply the business-hours window to Production. If this genuinely is a Production deploy the user has cleared to run now, re-run with AMA_ALLOW_PROD_DEPLOY=1."
fi

[ "${AMA_ALLOW_PROD_DEPLOY:-}" = "1" ] && exit 0

# shellcheck source=lib-et-now.sh
. "$HOME/.claude/hooks/lib-et-now.sh" 2>/dev/null || \
  deny "Could not load hooks/lib-et-now.sh, so this Production deploy cannot be cleared against the 9am-5pm ET Mon-Fri window. This gate fails CLOSED on purpose. Resolve ET yourself with: python -c \"from datetime import datetime; from zoneinfo import ZoneInfo; print(datetime.now(ZoneInfo('America/New_York')).strftime('ET=%H:%M %a offset=%z %Z'))\" -- and if the printed ET equals UTC the lookup failed, do not act on it. Once confirmed outside the window, re-run with AMA_ALLOW_PROD_DEPLOY=1."

state="$(et_window_state)"

case "$state" in
  unresolved)
    deny "Could not resolve Eastern time (python/zoneinfo unavailable), so this Production deploy cannot be cleared against the 9am-5pm ET Mon-Fri window. This gate fails CLOSED on purpose: the defect it exists to stop is a silently wrong hour. Do NOT use TZ=America/New_York date -- git-bash ignores TZ here and returns UTC while looking like it worked. Resolve ET with python zoneinfo, and if the printed ET equals UTC the lookup failed. Once confirmed outside the window, re-run with AMA_ALLOW_PROD_DEPLOY=1."
    ;;
  utcmatch*)
    deny "Eastern time read back identical to UTC (${state#utcmatch }) -- the zoneinfo lookup failed rather than resolving ET, which is the exact failure mode behind the wrong-time claim this gate was created for. Do not act on that reading. Re-resolve ET, and once genuinely outside the 9am-5pm ET Mon-Fri window re-run with AMA_ALLOW_PROD_DEPLOY=1."
    ;;
  inside*)
    deny "Production deploys must not run during US business hours -- the blocked window is 9am-5pm Eastern, Mon-Fri (standing user instruction, 2026-09-09). It is currently ET=${state#inside }, inside the window. Timeshift the deploy to the next opening: OUTSIDE the window is fine in BOTH directions, so before 9am ET tomorrow morning is just as valid as after 5pm ET today -- do not reflexively defer a whole day to the evening. Deferring = scheduling: set a durable reminder (scripts/reminder.sh add) for the chosen slot, default next weekday 08:00 LOCAL (the PC is off at 17:04 ET) with the full task in the same turn -- deferred-window-reminder-check.sh blocks a deferral that sets none. An emergency/hotfix timeline is NOT an exemption; the override is the user's call, not the schedule's. If the user has explicitly cleared this specific deploy to go now, re-run with AMA_ALLOW_PROD_DEPLOY=1."
    ;;
esac

exit 0
