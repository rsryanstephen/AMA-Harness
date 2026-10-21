#!/usr/bin/env bash
# dispatch: fail-closed-on-timeout -- a dispatcher timeout DENIES instead of skipping (hooks/dispatch.sh, 2026-10-15).
# PreToolUse hook (Bash|PowerShell, dispatched). Denies a PRODUCTION Octopus deployment
# unless skills/ama-deploy-release/scripts/release-preflight.sh recorded a run in the last
# 12h (Staging API tests + Graylog/CloudWatch error sweep), and turns a run that found
# anything into a user decision.
#
# User instruction 2026-10-12: asking to deploy the release must FIRST run the Staging tests
# and the error sweep, and warn before proceeding. Both were prose steps (deploy-release
# Step 0 / 3a, the tests only after the master merge) -- per "Mechanical Triggers Over
# Self-Recognition" the precondition sits on the deploy itself.
#
# Detection is lib-octopus-deploy-detect.sh's, same as prod-deploy-business-hours-gate.sh.
# Only an EXPLICIT production environment id fires here; an opaque target is already denied
# by the business-hours gate (fails closed there, no need to double up).
#
# Escape hatch: AMA_PREFLIGHT_ACK=1 -- ONLY after the user, shown the findings, explicitly
# says deploy anyway. Test seams: PREFLIGHT_STAMP_FILE, PREFLIGHT_NOW.
set -u

payload="$(cat)"
case "$payload" in *deployments*|*octo-deploy*|*deploy-lambda*) : ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0

. "$HOME/.claude/hooks/lib-octopus-deploy-detect.sh" 2>/dev/null || exit 0
head_region="$(octo_scan_region "$command")"
octo_is_deploy_post "$head_region" || exit 0

CONFIG="$HOME/.claude/harness-config.json"
prod_env="<production>"
[ -f "$CONFIG" ] && prod_env="$(jq -r '.octopus.environmentIds.production // "<production>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
printf '%s' "$head_region" | sed 's/\\"/"/g' | grep -qF "${prod_env:-<production>}" || exit 0

[ "${AMA_PREFLIGHT_ACK:-}" = "1" ] && exit 0

deny() {
  jq -cn --arg reason "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

if [ -n "${PREFLIGHT_STAMP_FILE:-}" ]; then STAMP="$PREFLIGHT_STAMP_FILE"
else . "$HOME/.claude/hooks/lib-claude-paths.sh"; STAMP="$(hstate tickets release-preflight)"; fi
now="${PREFLIGHT_NOW:-$(date +%s)}"
RUN='bash ~/.claude/skills/ama-deploy-release/scripts/release-preflight.sh <version> --hours <hours since the release was cut>   (hotfix: add --hotfix)'

line="$( [ -s "$STAMP" ] && tail -n 1 "$STAMP" | tr -d '\r')"
if [ -z "$line" ]; then
  deny "Production deploy blocked: no release preflight on record. Before ANY Production deploy, run the Staging API tests and the Graylog/CloudWatch error sweep (user instruction 2026-10-12): $RUN -- then report its result to the user. A clean run unblocks this; a run with findings needs the user's explicit go-ahead."
fi
IFS=$'\t' read -r ts label tests errors summary report <<< "$line"
age=$(( now - ${ts:-0} ))
if [ "$age" -gt 43200 ] || [ "$age" -lt 0 ]; then
  deny "Production deploy blocked: the last release preflight ($label) is $((age / 3600))h old -- older than 12h, so it no longer describes Staging. Re-run it now: $RUN"
fi
[ "$errors" = "CLEAN" ] && exit 0
deny "Production deploy blocked: the release preflight for $label ($((age / 60)) min ago) found problems -- tests: $tests; $summary. Report: $report. WARN THE USER with these findings before deploying. Only if the user explicitly says deploy anyway, the USER sets AMA_PREFLIGHT_ACK=1 in the shell Claude Code was LAUNCHED from (or settings.json env) -- an inline AMA_PREFLIGHT_ACK=1 prefix in the Bash tool never reaches this gate, which reads its own process env. If the findings are fixed or turn out to be noise, re-run the preflight instead."
