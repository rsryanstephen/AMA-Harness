#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell). Nudges Claude to check/transition the session's
# resolved ticket right after a push to a branch that implies a status change --
# PROJ-15231 was fixed and deployed but its ticket sat stale, nothing prompted the
# transition. Hooks have no live Jira read access (no API token/REST setup for Jira,
# unlike Bitbucket) -- this can only nudge, not verify; Claude checks the real status
# itself via its own MCP access. No de-dupe: fires on every matching push, same
# philosophy as on-prompt.sh's queued-item reminder.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- the push-matching regex below requires the literal
# substring "push", so a payload without it can exit on zero forks. ~60ms/fork.
case "$payload" in *push*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"

[ -n "$command" ] || exit 0
[ -n "$sid" ] || exit 0

printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?push\b' || exit 0

target_dir="$(printf '%s' "$command" | grep -oP -- '-C\s+"?\K[^"[:space:]]+' | head -1)"
[ -z "$target_dir" ] && target_dir="$(printf '%s' "$command" | grep -oP '^\s*cd\s+"?\K[^"[:space:];&]+' | head -1)"
[ -z "$target_dir" ] && target_dir="$cwd"
# Confirmed real bug: an extracted `~/...` or literal `$HOME/...` path is just text from
# grep, never shell-expanded -- `git -C` doesn't expand either itself, so it silently
# fails (2>/dev/null swallows it) and the reminder never fires. Expand both forms here.
target_dir="${target_dir/#\~/$HOME}"
target_dir="${target_dir/#\$HOME/$HOME}"
[ -n "$target_dir" ] || exit 0

branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$branch" ] || exit 0

status=""
case "$branch" in
  master) status="Test Complete" ;;
  develop) status="QA" ;;
  release/*|hotfix/*) status="__conditional__" ;;
  *) exit 0 ;;
esac

TF="$HOME/.claude/.session-chatfiles/$sid.ticket"
[ -f "$TF" ] || exit 0
ticket="$(cat "$TF")"
[ -n "$ticket" ] || exit 0

# Harness work (commits against the harness epic directly, per commit-ticket's
# "Harness work" section) has no ticket lifecycle at all -- a status-transition
# reminder here would be actively wrong (ama-claude-harness pushes straight to
# master, which would otherwise read as "move to Test Complete").
harness_epic="<harnessEpicKey>"
CONFIG="$HOME/.claude/harness-config.json"
[ -f "$CONFIG" ] && harness_epic="$(jq -r '.atlassian.harnessEpicKey // "<harnessEpicKey>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
[ -n "$harness_epic" ] || harness_epic="<harnessEpicKey>"
[ "$ticket" != "$harness_epic" ] || exit 0
# The session ticket is not the whole story: a harness commit made DURING a product-ticket
# session leaves $ticket at the product key, so the check above passes and the nudge fires
# on a harness push anyway (seen live 2026-08-18: session ticket PROJ-15307, commit
# <harnessEpicKey>, nudge said to move 15307 to Test Complete -- it was mid-investigation).
# The pushed commit's own ref is the authority on what was actually pushed.
pushed_ticket="$(git -C "$target_dir" log -1 --pretty=%s 2>/dev/null | grep -oP 'PROJ-\d+' | head -1)"
[ "$pushed_ticket" != "$harness_epic" ] || exit 0

if [ "$status" = "__conditional__" ]; then
  jq -cn --arg t "$ticket" --arg b "$branch" '{decision:"block", reason:("Just pushed to " + $b + " -- release/hotfix branch. Watch for this Staging deploy to land stable and follow up AUTOMATICALLY, do not wait to be asked -- ticket bookkeeping, not a deploy action. Once stable: board blocks a direct In Progress -> Ready to Test/Test Complete hop -- hop " + $t + " through Review -> QA first (confirm each hop via getTransitionsForJiraIssue, do not assume). Then: is its fix manually testable? If yes -> transition to Ready to Test (a distinct status, id 10171, NOT the QA status id 10121 despite similar wording) + add a comment with step-by-step testing instructions. If not testable -> Test Complete. See ama-hotfix Step 2a. Also confirm " + $t + "'"'"'s Fix Version includes \"" + $b + "\" (exact match) -- a fix committed straight onto an already-cut release/hotfix branch needs the same tag Step 3a gives tickets included at cut time; editJiraIssue now if it'"'"'s missing.")}'
else
  jq -cn --arg t "$ticket" --arg b "$branch" --arg s "$status" '{decision:"block", reason:("Just pushed to " + $b + " -- per commit-ticket'"'"'s Ticket status transitions table, " + $t + " should move to " + $s + " if it hasn'"'"'t already. Check its current status and transition it now.")}'
fi
