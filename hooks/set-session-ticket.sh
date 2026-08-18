#!/usr/bin/env bash
# Usage: set-session-ticket.sh <cwd> <current chat filename> <TICKET-REF>
# Invoked by the model every time it resolves a PROJ ticket per the commit-ticket
# skill's "record the resolved ticket" step -- ANY repo, not just ~/.claude. Two jobs:
#   1. In ~/.claude specifically, this ALSO satisfies on-stop.sh's auto_commit_push gate
#      (requires a ticket set before it'll commit any staged change touching hooks/skills).
#   2. Everywhere, it's the mechanical half of [[context-hygiene]]'s task-switch
#      detection -- diffs old vs new ticket, prints a TOKEN-SAVINGS HINT on a real
#      switch. Confirmed real gap: when this was only called for ~/.claude work, the
#      hint never fired for ordinary AMA_APP ticket work (the vast majority of
#      sessions) -- fixed by calling it universally, not just for the harness repo.
# Resolves the session id the same way rename-topic.sh does: by matching the chat
# filename recorded in this session's state file, not a raw session id the model
# doesn't have direct access to.
set -e
cwd="$1"; chat_name="$2"; ticket="$3"
if [ -z "$cwd" ] || [ -z "$chat_name" ] || [ -z "$ticket" ]; then
  echo "usage: set-session-ticket.sh <cwd> <current chat filename> <TICKET-REF>" >&2
  exit 1
fi

STATED="$HOME/.claude/.session-chatfiles"

# Fork-free iteration copied from on-prompt.sh's claimed_paths loop (see
# flush-reply.sh's sibling comment for the full why: ~300 x $(cat) at ~60ms/fork).
# Dotted-suffix skip: real sid statefiles never contain a dot, bookkeeping ones do.
norm_cwd="${cwd//\\//}"
sid=""
for f in "$STATED"/*; do
  case "${f##*/}" in *.*) continue ;; esac
  [ -f "$f" ] || continue
  # Test the VARIABLE, never read's exit status (on-prompt.sh:91 gotcha); || true
  # additionally required here -- this script runs under set -e.
  stored=""
  IFS= read -r stored < "$f" 2>/dev/null || true
  [ -n "$stored" ] || continue
  [ "${stored##*/}" = "$chat_name" ] || continue
  stored_dir="${stored%/*}"; stored_dir="${stored_dir//\\//}"
  if [ -z "$sid" ]; then
    sid="${f##*/}"
  elif [ "$stored_dir" = "$norm_cwd" ]; then
    sid="${f##*/}"
  fi
done
if [ -z "$sid" ]; then
  echo "no session state points at a file named: $chat_name" >&2
  exit 1
fi

old_ticket=""
[ -f "$STATED/$sid.ticket" ] && old_ticket="$(cat "$STATED/$sid.ticket")"

printf '%s' "$ticket" > "$STATED/$sid.ticket"
echo "session $sid now tied to $ticket (enables ~/.claude auto-commits if this is a harness change; also feeds context-hygiene's task-switch detection regardless of repo)"

if [ -n "$old_ticket" ] && [ "$old_ticket" != "$ticket" ]; then
  echo "TOKEN-SAVINGS HINT: this session was previously tied to $old_ticket, now $ticket -- looks like a task switch. Recommend the user run /clear now (or /compact if this new task still needs earlier context) before continuing, to avoid carrying unrelated history forward."
fi
