#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell). Fires right after Claude issues a production
# deployment via the Octopus REST API (POST .../deployments with EnvironmentId matching
# the configured production environment) -- nudges the mandatory Fix-Version ticket
# sweep to Done. Mechanical backstop for PROJ-15294 (hotfix/128.0.2 + 128.0.3):
# that ticket only reached Done because the user asked for it explicitly after the
# fact, even though ama-deploy-release's Step 7a (reused as-is by ama-hotfix Step 4)
# already makes this sweep mandatory, not an offer -- self-recognition alone missed it.
# Per explicit user instruction (2026-08-11), the sweep is now unconditionally
# automatic once Claude's OWN deploy verification confirms the version landed -- see
# commit-ticket/SKILL.md's updated "Deployed to production" line, no fresh "ask the
# user" step needed there anymore.
#
# Hooks have no live Jira read access (same limitation git-push-ticket-reminder.sh
# documents) -- this can only nudge Claude to run the real JQL sweep itself, never do
# it directly.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh)
# -- detection below needs the literal substring "deployments", so a payload without it
# can exit on zero forks.
case "$payload" in *deployments*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"

[ -n "$command" ] || exit 0

# Must be an actual POST to Octopus's deployments endpoint, not just the word appearing
# in unrelated text (a comment, a different API's JSON, etc).
printf '%s' "$command" | grep -qP '(-X\s*POST|--request\s*POST).*api/Spaces-[0-9]+/deployments|api/Spaces-[0-9]+/deployments.*(-X\s*POST|--request\s*POST)' || exit 0

CONFIG="$HOME/.claude/harness-config.json"
prod_env="<production>"
[ -f "$CONFIG" ] && prod_env="$(jq -r '.octopus.environmentIds.production // "<production>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
[ -n "$prod_env" ] || prod_env="<production>"

# The JSON body is normally embedded inside a double-quoted bash -d argument, so its
# literal quotes are backslash-escaped in the command text (\"EnvironmentId\":\"...\") --
# confirmed live, this is exactly how the deploy call in this session was written.
# Strip those backslashes before matching so both escaped and unescaped forms hit.
normalized="$(printf '%s' "$command" | sed 's/\\"/"/g')"

# Known gap, same class as bare-cd-gate.sh's quote-blind trap: only catches the
# EnvironmentId literal actually appearing in the command text. A deploy call built via
# a variable (e.g. -d "$body" where $body was assembled elsewhere) or a heredoc/file
# payload won't match -- no nudge fires. Accepted tradeoff, not silently "handled".
printf '%s' "$normalized" | grep -qF "\"EnvironmentId\":\"$prod_env\"" || \
printf '%s' "$normalized" | grep -qF "\"EnvironmentId\": \"$prod_env\"" || exit 0

ticket=""
if [ -n "$sid" ]; then
  TF="$HOME/.claude/.session-chatfiles/$sid.ticket"
  [ -f "$TF" ] && ticket="$(cat "$TF")"
fi

ticket_hint=""
[ -n "$ticket" ] && ticket_hint=" (this session's resolved ticket is $ticket, but the sweep is Fix-Version-scoped, not limited to it)"

jq -cn --arg hint "$ticket_hint" '{decision:"block", reason:("Production deployment just triggered via Octopus. Once you have verified it actually landed -- the ECS task-definition IMAGE TAG matches the deployed version, never inferred from health alone -- run the mandatory Fix-Version ticket sweep to Done, per ama-deploy-release Step 7a (reused as-is by ama-hotfix Step 4): `project = PROJ AND fixVersion = \"<release/hotfix branch just deployed>\" AND status in (Done, \"Test Complete\")`, transition only the Test Complete subset via jira-transition-issue.sh (jira-get-transitions.sh first, do not hardcode the id). This is now UNCONDITIONALLY AUTOMATIC once your own verification confirms the deploy -- do not wait for the user to ask" + $hint + ".")}'
