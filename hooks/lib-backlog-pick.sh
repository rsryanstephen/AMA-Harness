#!/usr/bin/env bash
# Shared "is this turn a backlog pick?" detection. Sourced by advisor-standard-process-gate.sh
# and backlog-pick-no-ask-gate.sh so the phrase list lives once -- two copies drifted
# ("backlog task" matched in neither until 2026-10-27).
#
# backlog_last_prompt <transcript> <tail_n>  -> prints the newest real user prompt (string
#   content, or the text blocks of array content; tool_result-only turns skipped).
# backlog_pick_prompt <text>                -> exit 0 when the text asks for a backlog item.

backlog_last_prompt() {
  tail -n "$2" "$1" 2>/dev/null \
    | jq -r 'select(.type=="user") | .message.content
             | if type=="string" then .
               else ([.[]? | select(.type=="text") | .text] | join(" ")) end' 2>/dev/null \
    | grep -v '^[[:space:]]*$' | tail -1
}

backlog_pick_prompt() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *"next backlog"*|*"backlog task"*|*"backlog item"*|*"backlog ticket"*|*"in the backlog"*|*"from the backlog"*|*"off the backlog"*| \
    *"pick up the next"*|*"pick up next"*|*"pick up a ticket"*|*"next ticket"*)
      return 0 ;;
  esac
  return 1
}
