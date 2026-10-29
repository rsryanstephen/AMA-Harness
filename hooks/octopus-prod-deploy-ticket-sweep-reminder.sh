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
# commit-ticket-jira/SKILL.md's "Deployed to production" line, no fresh "ask the
# user" step needed there anymore.
#
# Also nudges marking the deployed release/hotfix Jira VERSION as Released -- this was
# previously self-recognition only (ama-hotfix/ama-release-notes SKILL.md text), and
# hotfix/128.0.7, 129.0.1, 129.0.3, 129.0.5 sat unreleased in Jira despite shipping to
# prod as a result (confirmed live 2026-08-20). Same trigger as the ticket sweep --
# both are "once this prod deploy is verified" actions.
#
# Hooks have no live Jira read access (same limitation git-push-ticket-reminder.sh
# documents) -- this can only nudge Claude to run the real JQL sweep itself, never do
# it directly.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh).
# BOTH needles are required: a wrapper script that POSTs from inside itself never puts the
# word "deployments" in the command text, so a `*deployments*`-only prefilter exited before
# detection ran -- see the deploy-form note below.
case "$payload" in *deployments*|*octo-deploy*|*deploy-lambda*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"

[ -n "$command" ] || exit 0

# Heredoc bodies are DATA. Measure only the region before the first `<<` -- the same scoping
# prod-deploy-business-hours-gate.sh and inplace-edit-gate.sh use. Needed here as soon as the
# detection below stopped requiring the JSON-key form: the very commit that broadened it
# fired this reminder on its OWN commit message, whose heredoc body names
# octo-deploy-release.sh and <production> while describing the fix. A false "you just
# deployed to production" nudge is the same self-denial trap, one severity down.
. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
command="$(command_scan_region "$command")"

# Must be an actual deploy call, not just the word appearing in unrelated text (a comment, a
# different API's JSON, etc). TWO accepted forms -- a direct POST to Octopus's deployments
# endpoint, OR the octo-deploy wrapper script, which issues the POST from inside itself and
# so matches none of the curl signals. Missing the wrapper form meant this reminder never
# fired for any script-driven production deploy. Detection is lib-octopus-deploy-detect.sh's
# -- this file kept its own "in sync" copy of the matcher, and when the two deploy gates'
# copies were fixed on 2026-09-15 (verb and endpoint joined by `.*`, which grep -P cannot
# span across a newline) this third copy was missed. One predicate, one place.
. "$HOME/.claude/hooks/lib-octopus-deploy-detect.sh" 2>/dev/null || exit 0
octo_is_deploy_post "$command" || exit 0

CONFIG="$HOME/.claude/harness-config.json"
prod_env="<production>"
[ -f "$CONFIG" ] && prod_env="$(jq -r '.octopus.environmentIds.production // "<production>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
[ -n "$prod_env" ] || prod_env="<production>"

# The JSON body is normally embedded inside a double-quoted bash -d argument, so its
# literal quotes are backslash-escaped in the command text (\"EnvironmentId\":\"...\") --
# confirmed live, this is exactly how the deploy call in this session was written.
# Strip those backslashes before matching so both escaped and unescaped forms hit.
normalized="$(printf '%s' "$command" | sed 's/\\"/"/g')"

# Match the BARE environment literal anywhere, not only the "EnvironmentId":"..." JSON key
# form. The key-only match was a real miss, not a theoretical one: octo-deploy-release.sh
# takes the env id as a POSITIONAL argument and writes the request body to a file, so
# `octo-deploy-release.sh Releases-X <production>` contains no JSON key at all -- this
# reminder therefore never fired for any script-driven production deploy, which is how
# every deploy in the 2026-09 cohort-cleanup work was issued. Found while building
# prod-deploy-business-hours-gate.sh, which needs the identical detection.
printf '%s' "$normalized" | grep -qF "$prod_env" || exit 0

# Shape is not a deployment -- require Octopus's own Deployments-N / ServerTasks-N in the
# tool response (see octopus-prod-cache-update-reminder.sh for the 2026-09-18 misfire).
octo_response_shows_deploy "$payload" || exit 0

# Remaining known gap, same class as bare-cd-gate.sh's quote-blind trap: a call whose
# environment is named only through a variable (`-d "$body"`, or `"$PRODENV"`) still has no
# literal to match, so no nudge fires. Accepted tradeoff here -- this hook only nudges.
# prod-deploy-business-hours-gate.sh, which BLOCKS, fails closed on that same opaque case
# instead of waving it through.

ticket=""
if [ -n "$sid" ]; then
  TF="$HOME/.claude/.session-chatfiles/$sid.ticket"
  [ -f "$TF" ] && ticket="$(cat "$TF")"
fi

ticket_hint=""
[ -n "$ticket" ] && ticket_hint=" (this session's resolved ticket is $ticket, but the sweep is Fix-Version-scoped, not limited to it)"

# Post-prod-deploy action ledger: one free-text line per owed follow-up ("after release/X reaches
# Production: ..."), added by whichever session promised it (2026-09-26: redeploy a hotfix to Staging once
# the release ships). Surfaced on EVERY prod deploy; the acting session deletes a line once done or
# not applicable to what was deployed. Seam: POST_PROD_ACTIONS_FILE.
. "$HOME/.claude/hooks/lib-claude-paths.sh" 2>/dev/null
actions_file="${POST_PROD_ACTIONS_FILE:-$(hstate tickets post-prod-deploy-actions 2>/dev/null)}"
if [ -s "$actions_file" ]; then
  pending="$(grep -v '^[[:space:]]*$' "$actions_file" | sed 's/^/ * /' | tr '\n' ' ')"
  [ -n "$pending" ] && ticket_hint="$ticket_hint. ALSO owed follow-ups from $actions_file (do each that applies to this deploy, then delete its line):$pending"
fi

jq -cn --arg hint "$ticket_hint" '{decision:"block", reason:("Production deployment just triggered via Octopus. Once you have verified it actually landed -- the ECS task-definition IMAGE TAG matches the deployed version, never inferred from health alone -- do THREE things, all unconditionally automatic, do not wait for the user to ask: (1) run the mandatory Fix-Version ticket sweep to Done, per ama-deploy-release Step 7a (reused as-is by ama-hotfix Step 4): `project = PROJ AND fixVersion = \"<release/hotfix branch just deployed>\" AND status in (Done, \"Test Complete\")`, transition only the Test Complete subset via jira-transition-issue.sh (jira-get-transitions.sh first, do not hardcode the id); (2) mark that same release/hotfix Jira VERSION as Released via `jira-version.sh release <name> <production deploy date>` -- verify with a fresh `jira-version.sh show`, not the write response; (3) schedule two durable re-checks for errors that only appear when a client opens an affected report hours later (PROJ-15801 reached a client first): `bash ~/.claude/scripts/reminder.sh add <sid> \"<deploy + 4h, local>\" \"error-signature-diff.sh production <deploy time ISO UTC>\"` and the same at deploy + 24h -- the claiming session runs `bash ~/.claude/skills/ama-graylog-search/scripts/error-signature-diff.sh production <deploy time>` and tickets any NEW untagged signature" + $hint + ".")}'
