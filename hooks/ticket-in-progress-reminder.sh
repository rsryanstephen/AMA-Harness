#!/usr/bin/env bash
# PostToolUse hook (Bash|PowerShell). Nudges Claude to check/transition a ticket to In
# Progress right after set-session-ticket.sh records it -- that's the exact moment
# commit-ticket/SKILL.md's "Actively working a ticket" rule should apply, but the rule
# is self-recognition-only today -- a session once started substantive work on a
# ticket that sat "Open" the whole time. Same class of miss as
# git-push-ticket-reminder.sh already fixed for pushes (CLAUDE.md's "Mechanical
# Triggers Over Self-Recognition"). Same shape as that hook: nudge only, can't verify
# or transition Jira state itself (no live read/write access from a hook), Claude does
# that via its own MCP access.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- the invocation regex below requires the literal
# script name, so a payload without it can exit on zero forks. ~60ms/fork.
case "$payload" in *set-session-ticket*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0

# Match requires an actual invocation prefix (bash/sh/pwsh/powershell/./), same idiom
# as deploy-verify-confirm-gate.sh -- a bare substring match self-triggered on this
# hook's OWN commit, whose git commit message just mentioned "set-session-ticket.sh" by
# name in prose, no real invocation. Confirmed live, same quote-blind trap bare-cd-
# gate.sh's comments already document.
printf '%s' "$command" | grep -qP '(^|[;&|]\s*)(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*set-session-ticket\.sh|(^|[;&|]\s*)\.[/\\]\S*set-session-ticket\.sh' || exit 0
# Args are <cwd> <chat filename> <TICKET-REF> -- the chat filename can contain spaces
# when quoted, so a positional \S+-per-arg match is quote-blind (confirmed live: missed
# a real "... Chat.md" filename). The ticket ref is always the LAST PROJ-#### token
# in the command instead -- simpler and doesn't need to parse quoting at all.
ticket="$(printf '%s' "$command" | grep -oP 'PROJ-[0-9]+' | tail -1)"
[ -n "$ticket" ] || exit 0

# Harness epic never transitions (see commit-ticket's "Harness work" section) --
# a reminder here would be actively wrong.
harness_epic="<harnessEpicKey>"
CONFIG="$HOME/.claude/harness-config.json"
[ -f "$CONFIG" ] && harness_epic="$(jq -r '.atlassian.harnessEpicKey // "<harnessEpicKey>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
[ -n "$harness_epic" ] || harness_epic="<harnessEpicKey>"
[ "$ticket" != "$harness_epic" ] || exit 0

jq -cn --arg t "$ticket" '{decision:"block", reason:("Just tied this session to " + $t + " -- per commit-ticket'"'"'s \"Actively working a ticket\" rule, check its current Jira status now and transition it to In Progress if it isn'"'"'t already (may take more than one hop, e.g. Open -> To Do -> In Progress -- re-check available transitions after each). Also check its created date and reporter: if this ticket is >2y old or reported by someone else, verify the premise first per commit-ticket'"'"'s \"Old/foreign ticket picked up\" rule before working it.")}'
