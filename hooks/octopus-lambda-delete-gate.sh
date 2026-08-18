#!/usr/bin/env bash
# Two wirings, one file:
#   PreToolUse  (Bash|PowerShell)            -- gate an Octopus deployment-creation call
#   PostToolUse (Bash|PowerShell) --record   -- remember that a lambda was just deleted
#
# Why this exists. ama-octopus-deploy/SKILL.md says to `aws lambda delete-function`
# BEFORE every Octopus Lambda deploy, because deploying over an existing function can
# leave the OLD code running while Octopus reports Success and LastModified/CodeSize
# both move. Prose alone did not hold: confirmed live 2026-08-17, a hotfix for
# PROJ-15297 was deployed to Staging, reported Success, updated LastModified --
# and the function kept running a 2025-03-18 build. The regression looked unfixed, an
# All cache update still wedged the chain, and ~40 minutes went into re-diagnosing a
# fix that was already correct. Deleting the function first and redeploying the SAME
# release immediately produced a same-day artifact. Per CLAUDE.md's "Mechanical
# Triggers Over Self-Recognition" rule, that gotcha needs a hook, not a paragraph.
#
# Deliberately gates the DEPLOY, not the delete: the deploy is the irreversible half,
# and it is the only point where "did I delete first?" is still answerable cheaply.
#
# Fails open on anything it cannot parse (same tradeoff as master-push-direct-gate.sh)
# -- a hook must never be the reason a deploy cannot happen at all.
set -u

MODE="${1:-gate}"

IFS= read -r -d '' payload || true

# --- PostToolUse: record a lambda deletion for this session -------------------------
if [ "$MODE" = "--record" ]; then
  case "$payload" in *delete-function*) ;; *) exit 0 ;; esac
  command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
  sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
  [ -n "$command" ] && [ -n "$sid" ] || exit 0
  printf '%s' "$command" | grep -qP 'aws\s+lambda\s+delete-function' || exit 0
  date +%s > "$HOME/.claude/.lambda-deleted-$sid" 2>/dev/null || true
  exit 0
fi

# --- PreToolUse: gate the Octopus deployment call -----------------------------------
# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh).
case "$payload" in *deployments*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
[ -n "$command" ] || exit 0

# Must be a real POST creating an Octopus deployment, not the word appearing in prose
# or in some other API's JSON. Same anchored match as
# octopus-prod-deploy-ticket-sweep-reminder.sh.
printf '%s' "$command" \
  | grep -qP '(-X\s*POST|--request\s*POST).*api/Spaces-[0-9]+/deployments|api/Spaces-[0-9]+/deployments.*(-X\s*POST|--request\s*POST)' \
  || exit 0

# Escape hatch: the project genuinely isn't a Lambda (ECS service, S3 site, API gateway
# definition, state machine). Set this in the command to assert that and move on.
case "$command" in *OCTOPUS_TARGET_NOT_LAMBDA=1*) exit 0 ;; esac

# The delete and the deploy in ONE command (`aws lambda delete-function ... && curl -X POST
# ...`) is the natural shape and satisfies the rule -- but PreToolUse runs BEFORE the command,
# so the PostToolUse recorder hasn't fired yet and the marker check below would deny it.
# Confirmed by hitting it live the first time this gate ran for real.
case "$command" in *delete-function*) exit 0 ;; esac

# A delete recorded earlier in this session satisfies the rule. 2h window -- long enough
# to cover delete -> poll -> deploy, short enough that a delete from unrelated work
# earlier in a long session doesn't silently license a later deploy.
marker="$HOME/.claude/.lambda-deleted-${sid:-none}"
if [ -f "$marker" ]; then
  then_ts="$(cat "$marker" 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"
  case "$then_ts" in ''|*[!0-9]*) then_ts=0 ;; esac
  if [ "$then_ts" -gt 0 ] && [ $((now_ts - then_ts)) -lt 7200 ]; then
    exit 0
  fi
fi

cat >&2 <<'EOF'
Octopus deployment blocked: no `aws lambda delete-function` recorded in this session.

Deploying over an EXISTING Lambda can leave the old code running while Octopus reports
Success and LastModified/CodeSize both move -- confirmed live (PROJ-15297 hotfix
shipped to Staging and kept running a build from months earlier). ama-octopus-deploy's
"Deploying a Lambda" section requires deleting the function first.

Pick one:

1. Lambda project -> delete first, then re-run this deploy:
     aws lambda delete-function --function-name <env>-v1-<name>
   Then AFTER the deploy, verify the ARTIFACT, not the task state -- pull
   Code.Location and check the DLL dates are today's build. A green Octopus task is
   not evidence.

2. Not a Lambda project (ECS service, S3 site, API gateway, state machine) -> assert it
   by prefixing the command:
     OCTOPUS_TARGET_NOT_LAMBDA=1 curl -sS -X POST ...
EOF
exit 2
