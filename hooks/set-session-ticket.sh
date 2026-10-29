#!/usr/bin/env bash
# Usage: set-session-ticket.sh <cwd> <current chat filename> <TICKET-REF>
# Invoked by the model every time it resolves a PROJ ticket per the commit-ticket
# skill's "record the resolved ticket" step -- ANY repo, not just ~/.claude. Two jobs:
#   1. For harness work, this ALSO satisfies on-stop.sh's auto_commit_push_harness gate
#      (requires a ticket set before it'll commit any staged harness change).
#   2. Everywhere, it's the mechanical half of [[context-hygiene]]'s task-switch
#      detection -- diffs old vs new ticket, prints a TOKEN-SAVINGS HINT on a real
#      switch. Confirmed real gap: when this was only called for ~/.claude work, the
#      hint never fired for ordinary AMA_APP ticket work (the vast majority of
#      sessions) -- fixed by calling it universally, not just for the harness repo.
# Resolves the session id the same way rename-topic.sh does: by matching the chat
# filename recorded in this session's state file, not a raw session id the model
# doesn't have direct access to.
set -e
cwd="$1"; chat_name="${2##*[/\\]}"; ticket="$3"   # full path accepted, basename used
if [ -z "$cwd" ] || [ -z "$chat_name" ] || [ -z "$ticket" ]; then
  echo "usage: set-session-ticket.sh <cwd> <current chat filename> <TICKET-REF>" >&2
  exit 1
fi

STATED="$HOME/.claude/.session-chatfiles"
source "$(dirname "${BASH_SOURCE[0]}")/lib-chatfile-link.sh"

# Fork-free iteration copied from on-prompt.sh's claimed_paths loop (see
# flush-reply.sh's sibling comment for the full why: ~300 x $(cat) at ~60ms/fork).
# Dotted-suffix skip: real sid statefiles never contain a dot, bookkeeping ones do.
norm_cwd="${cwd//\\//}"
sid=""
all_matches=()
cwd_matches=()
for f in "$STATED"/*; do
  case "${f##*/}" in *.*) continue ;; esac
  [ -f "$f" ] || continue
  # Test the VARIABLE, never read's exit status (on-prompt.sh:91 gotcha); || true
  # additionally required here -- this script runs under set -e.
  stored=""
  IFS= read -r stored < "$f" 2>/dev/null || true
  [ -n "$stored" ] || continue
  [ "${stored##*/}" = "$chat_name" ] || continue
  stored_dir="$(chatfile_session_cwd "$stored")"; stored_dir="${stored_dir//\\//}"
  all_matches+=("${f##*/}")
  [ "$stored_dir" = "$norm_cwd" ] && cwd_matches+=("${f##*/}")
done
# Chat filenames are NOT unique across live sessions, and this used to silently keep the
# last match and OVERWRITE that session's .ticket. Real damage, 2026-09-21: two sessions
# shared "Next backlog task Chat.md", so a call from 7197a546 retied be743623 to the
# wrong key and left the caller with no .ticket at all -- which gates ~/.claude
# auto-commits and feeds git-push-ticket-reminder.sh. Same cwd narrows it (that case
# still resolves as before); still ambiguous -> refuse, never guess.
candidates=()
if [ "${#cwd_matches[@]}" -gt 0 ]; then
  candidates=("${cwd_matches[@]}")
elif [ "${#all_matches[@]}" -gt 0 ]; then
  candidates=("${all_matches[@]}")
fi
if [ "${#candidates[@]}" -eq 1 ]; then
  sid="${candidates[0]}"
elif [ "${#candidates[@]}" -gt 1 ]; then
  {
    echo "ambiguous: $((${#candidates[@]})) live sessions record a chat file named: $chat_name"
    echo "refusing to guess -- re-run with the SESSION ID in place of the filename:"
    for c in "${candidates[@]}"; do
      cand_stored=""
      IFS= read -r cand_stored < "$STATED/$c" 2>/dev/null || true
      cand_ticket="(none)"
      [ -f "$STATED/$c.ticket" ] && cand_ticket="$(cat "$STATED/$c.ticket")"
      echo "  $c  ticket=$cand_ticket  cwd=$(chatfile_session_cwd "$cand_stored")"
    done
  } >&2
  exit 1
fi
# Shortid alias: the harness itself can hand the model a STALE chat filename (the log
# is auto-renamed mid-session), and a brand-new session's statefile can be empty. The
# session shortid never goes stale, so accept it (or "<shortid> Chat.md") as an
# alternate key -- unique statefile-name prefix match, dot-suffixed bookkeeping skipped.
if [ -z "$sid" ]; then
  alias_key="${chat_name% Chat.md}"; alias_key="${alias_key%.md}"
  if printf '%s' "$alias_key" | grep -qE '^[0-9a-f-]{8,36}$'; then
    for f in "$STATED"/*; do
      case "${f##*/}" in *.*) continue ;; esac
      [ -f "$f" ] || continue
      case "${f##*/}" in
        "$alias_key"*) if [ -z "$sid" ]; then sid="${f##*/}"; else sid=""; break; fi ;;
      esac
    done
  fi
fi
if [ -z "$sid" ]; then
  # Print the names actually on record, so the retry is one step instead of a guess.
  # Claude Code auto-renames the session chat log mid-session, so the name the caller
  # holds goes stale routinely -- and a bare "no match" error got this deferred rather
  # than retried (PROJ-15330: deferred ~35min, past every push in the session,
  # which left git-push-ticket-reminder.sh with no .ticket file to fire on).
  {
    echo "no session state points at a file named: $chat_name"
    echo "chat filenames currently on record (retry with whichever is this session's):"
    for f in "$STATED"/*; do
      case "${f##*/}" in *.*) continue ;; esac
      [ -f "$f" ] || continue
      stored=""
      IFS= read -r stored < "$f" 2>/dev/null || true
      [ -n "$stored" ] || continue
      echo "  ${stored##*/}"
    done | sort -u
  } >&2
  exit 1
fi

old_ticket=""
[ -f "$STATED/$sid.ticket" ] && old_ticket="$(cat "$STATED/$sid.ticket")"

printf '%s' "$ticket" > "$STATED/$sid.ticket"
echo "session $sid now tied to $ticket (enables ~/.claude auto-commits if this is a harness change; also feeds context-hygiene's task-switch detection regardless of repo)"

if [ -n "$old_ticket" ] && [ "$old_ticket" != "$ticket" ]; then
  echo "TOKEN-SAVINGS HINT: this session was previously tied to $old_ticket, now $ticket -- looks like a task switch. Recommend the user run /clear now (or /compact if this new task still needs earlier context) before continuing, to avoid carrying unrelated history forward."
fi
