#!/usr/bin/env bash
# Shared detection for "is this Bash command creating an Octopus deployment?"
#
# WHY SHARED. octopus-lambda-delete-gate.sh and prod-deploy-business-hours-gate.sh each
# carried their own copy of the same matcher, and both copies carried the same bug --
# confirmed live 2026-09-15 on the release/130.0.0 Staging verification. Divergent copies
# of one predicate is exactly how a fix lands in one gate and not the other, so there is
# one copy now.
#
# THE BUG BOTH COPIES HAD:
#   grep -qP '(-X\s*POST).*api/Spaces-[0-9]+/deployments|api/Spaces-[0-9]+/deployments.*(-X\s*POST)'
# `grep -P` is line-scoped, so `.*` never crosses a newline. An ordinary multi-line curl
#   curl -sS -H "$H" -X POST \
#     -d "{...}" \
#     "$S/api/Spaces-1/deployments"
# puts the verb and the endpoint on DIFFERENT lines and matched neither alternative. A
# real Staging Lambda deploy went through with no delete-function and no business-hours
# check because of it. Match the two tokens INDEPENDENTLY over a newline-flattened region
# -- never re-join them with `.*`.

# Heredoc-body scoping is lib-command-text.sh's `command_scan_region` -- the same question
# every write gate has, answered once there. Fallback if the lib is missing: scan the whole
# command (errs toward denying, never toward silence).
. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }

# octo_scan_region <command> -- kept as a name for the two existing callers.
octo_scan_region() { command_scan_region "$1"; }

# octo_is_deploy_post <region> -- 0 when the region creates an Octopus deployment.
#
# Two accepted forms:
#   1. a POST to /api/Spaces-N/deployments (verb and endpoint matched independently)
#   2. a wrapper that POSTs from inside the script and so never contains the word
#      "deployments" in the command at all: ama-octopus-deploy/scripts/deploy-lambda.sh (the
#      live one) plus the older octo-deploy[-release].sh name. deploy-lambda.sh was invisible
#      to BOTH production gates from its creation on 2026-10-14 until 2026-10-15 -- a
#      `deploy-lambda.sh <production> ...` call passed the business-hours and preflight
#      gates in silence. Any new deploy wrapper goes HERE and in those gates' prefilters.
octo_is_deploy_post() {
  flat="$(printf '%s' "$1" | tr '\n' ' ')"

  # The wrapper must be INVOKED (command position, optional bash/sh/./ prefix), not merely
  # named -- `grep ... octo-deploy-release.sh` and `sed -n 1,40p .../octo-deploy-release.sh`
  # are reads, and matching the filename anywhere denied both (2026-09-18).
  if printf '%s' "$flat" | grep -qE '(^|[;&|(][[:space:]]*)([A-Z_]+=[^[:space:]]+[[:space:]]+)*(bash[[:space:]]+|sh[[:space:]]+|\./)?"?[^[:space:]"]*(octo-deploy(-release)?|deploy-lambda)\.sh"?([[:space:]]|$)'; then
    return 0
  fi

  printf '%s' "$flat" | grep -qP '(-X\s*POST|--request\s*POST|-Method\s+Post)' || return 1
  printf '%s' "$flat" | grep -qP 'api/Spaces-[0-9]+/deployments' || return 1
  return 0
}

# octo_response_shows_deploy <PostToolUse payload> -- 0 when the tool RESPONSE carries
# evidence a deployment was actually created (Octopus's Deployments-N / ServerTasks-N ids,
# or a TaskId key), or when the payload has no tool_response at all (fail open: a
# reminder that cannot see the result should still nudge). 1 when a response is present
# and shows no deployment -- the call was denied, errored, or never sent anything.
octo_response_shows_deploy() {
  case "$1" in *tool_response*) ;; *) return 0 ;; esac
  case "$1" in *Deployments-[0-9]*|*ServerTasks-[0-9]*|*TaskId*) return 0 ;; esac
  return 1
}
