#!/usr/bin/env bash
# PreToolUse hook (AskUserQuestion). Denies a "which ticket next?" question during a BACKLOG PICK.
#
# Why (2026-10-27, user instruction). The AMA Backlog pages are already in priority order, so
# "pick up the next backlog task" has exactly one answer: the first offerable row. The prose
# rule existed since 2026-09-21 (memory/ama-backlog-page.md step 4, "DEFAULT = PICK, don't
# ask") and did not hold: session 349268b0 (2026-10-22) met an empty umbrella ticket at the
# top, decided it was unactionable, and asked "Which backlog task next?" with three options
# instead of moving to the next row. CLAUDE.md: mechanical triggers over self-recognition.
#
# Scope -- only the PICK question is barred, not every question in a pickup session:
#   deny when  (a) the newest user prompt asks for a backlog item (lib-backlog-pick.sh),
#          and (b) the question is about WHICH ticket: >=2 distinct PROJ keys across the
#                  question + options, or "which ... task/ticket/item/one/row" wording,
#          and (c) no claim has landed since the last listing: a set-session-ticket.sh /
#                  jira-transition-issue.sh call AFTER the last backlog-candidates.sh run
#                  means the pick is made and later questions are mid-work judgment calls.
# A mid-work question ("fix the twin now or raise a ticket?") carries no competing keys and
# no "which ticket" wording, so it passes. No hatch: a named pick from the user is a prompt,
# not a question, and still overrides.
#
# Fails OPEN everywhere: no transcript, unreadable transcript, no jq.
set -u

payload="$(cat)"

case "$payload" in *'"AskUserQuestion"'*) : ;; *) exit 0 ;; esac
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')"
[ "$tool" = "AskUserQuestion" ] || exit 0

tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')"
[ -n "$tr_path" ] && [ -f "$tr_path" ] || exit 0

# Sibling lib, by own dir: check-gates.sh runs a worktree's copy of this gate before merge.
. "${BASH_SOURCE[0]%/*}/lib-backlog-pick.sh" 2>/dev/null || exit 0

# Bounded window, same as the advisor gate: a pickup turn is long but the pick itself is near
# the top of it, and the claim/listing order is what matters, not the whole file.
tail_n=1200

# (a) the turn is a backlog pick
backlog_pick_prompt "$(backlog_last_prompt "$tr_path" "$tail_n")" || exit 0

# (b) the question is about which ticket
qtext="$(printf '%s' "$payload" | jq -r '
  [.tool_input.questions[]? | (.question // ""), (.options[]? | (.label // ""), (.description // ""))] | join(" ")' 2>/dev/null)"
keys="$(printf '%s' "$qtext" | grep -oE 'PROJ-[0-9]+' | sort -u | wc -l | tr -d ' ')"
which_hit=""
printf '%s' "$qtext" | tr '[:upper:]' '[:lower:]' \
  | grep -qE 'which [^?]*(backlog|task|ticket|item|one|row)|(next|first) (backlog )?(task|ticket|item)' && which_hit=1
[ "${keys:-0}" -ge 2 ] || [ -n "$which_hit" ] || exit 0

# (c) no claim since the last listing
cmds="$(tail -n "$tail_n" "$tr_path" 2>/dev/null \
  | jq -r 'select(.type=="assistant") | (.message.content // [])[]?
           | select(.type=="tool_use" and (.name=="Bash" or .name=="PowerShell"))
           | .input.command // empty | gsub("[\r\n]+"; " ")' 2>/dev/null)"
last_list="$(printf '%s\n' "$cmds" | grep -nF 'backlog-candidates.sh' | tail -1 | cut -d: -f1)"
last_claim="$(printf '%s\n' "$cmds" | grep -nE 'set-session-ticket\.sh|jira-transition-issue\.sh' | tail -1 | cut -d: -f1)"
if [ -n "$last_claim" ] && [ "${last_claim:-0}" -gt "${last_list:-0}" ]; then exit 0; fi

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "AskUserQuestion is barred for a backlog pick: the AMA Backlog pages are already in priority order, so there is nothing to choose (memory/ama-backlog-page.md step 4, user instruction 2026-09-21 and 2026-10-27). Take the FIRST offerable row of backlog-candidates.sh -- the top Open row, or an Epic row'"'"'s rank.1 child -- claim it and start. If that row is unactionable (empty umbrella, premise gone, needs something only the user has), say so in ONE line of the reply, flag it for demotion or closure, and take the NEXT row; never stop to ask. State which key you took and why it was first, and list the next two or three in the reply so the user can redirect -- a named pick from the user always overrides."
  }
}'
