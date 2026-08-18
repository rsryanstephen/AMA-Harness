#!/usr/bin/env bash
# Usage: rename-topic.sh <cwd> <current chat filename> <new topic text> [user]
#
# The optional 4th arg is literally the word "user" and means "the USER supplied this
# name" (they said "rename this topic to X"). It writes a .session-chatfiles/<sid>.usertopic
# marker, which render-sessions-md.sh's bold field treats as an override -- that row keeps
# this name instead of showing Claude Code's own session name (see that script's priority
# list). OMIT it for any rename the user didn't name themselves -- Claude picking a name
# itself ("rename topic", no name given), or lib-fallback-rename.sh's mechanical rename.
# Omitting it REMOVES the marker, not just skips it: whatever the user had named is being
# replaced by a Claude-chosen name, so the topic is no longer user-assigned.
# Invoked by the model (not an automatic hook) when the user says "rename this
# topic to X". Does the full rename mechanically: renames the .md file, repoints
# that session's state file, and sets/replaces the topic field on its
# sessions.txt line -- all in one atomic-ish operation instead of 3 hand-done steps.
set -e
cwd="$1"; old_name="$2"; new_topic_raw="$3"; named_by="${4:-}"
if [ -z "$cwd" ] || [ -z "$old_name" ] || [ -z "$new_topic_raw" ]; then
  echo "usage: rename-topic.sh <cwd> <current chat filename> <new topic text> [user]" >&2
  exit 1
fi

STATED="$HOME/.claude/.session-chatfiles"
SESS="$HOME/.claude/sessions.txt"

# Match by BASENAME, not exact path string: the cwd Claude Code passes to hooks
# (Windows backslash form) can differ in style from what's actually stored in a
# state file (e.g. after a manual/bash-native fix), so exact "$cwd/$old_name"
# string equality is fragile. If more than one session's file has this exact
# basename, require the stored directory to match cwd (slash-normalized) to
# disambiguate; otherwise error rather than guess.
# Fork-free iteration copied from on-prompt.sh's claimed_paths loop (see
# flush-reply.sh's sibling comment for the full why: ~300 x $(cat) at ~60ms/fork).
# Dotted-suffix skip: real sid statefiles never contain a dot, bookkeeping ones do.
norm_cwd="${cwd//\\//}"
sid=""; OLD_PATH=""
for f in "$STATED"/*; do
  case "${f##*/}" in *.*) continue ;; esac
  [ -f "$f" ] || continue
  # Test the VARIABLE, never read's exit status (on-prompt.sh:91 gotcha); || true
  # additionally required here -- this script runs under set -e.
  stored=""
  IFS= read -r stored < "$f" 2>/dev/null || true
  [ -n "$stored" ] || continue
  [ "${stored##*/}" = "$old_name" ] || continue
  stored_dir="${stored%/*}"; stored_dir="${stored_dir//\\//}"
  if [ -z "$sid" ]; then
    sid="${f##*/}"; OLD_PATH="$stored"
  elif [ "$stored_dir" = "$norm_cwd" ]; then
    sid="${f##*/}"; OLD_PATH="$stored"  # exact dir match wins on ambiguity
  fi
done
if [ -z "$sid" ]; then
  echo "no session state points at a file named: $old_name" >&2
  exit 1
fi

new_name="$new_topic_raw Chat.md"
NEW_PATH="$(dirname "$OLD_PATH")/$new_name"
topic_slug="$(printf '%s' "$new_topic_raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"

# OLD_PATH is a symlink into <harness>/Chat files/ for a centralized session (see
# lib-chatfile-link.sh) -- a plain `mv` would move the LINK and leave the real file
# under its stale name. chatfile_relink_renamed renames the central file too and
# re-creates the link; it falls back to a plain mv + migrate for a pre-centralization
# session (OLD_PATH not yet a symlink).
source "$(dirname "${BASH_SOURCE[0]}")/lib-chatfile-link.sh"
chatfile_relink_renamed "$OLD_PATH" "$NEW_PATH" "${sid%%-*}" || {
  echo "chatfile_relink_renamed failed for $OLD_PATH -> $NEW_PATH" >&2
  exit 1
}
printf '%s' "$NEW_PATH" > "$STATED/$sid"

# User-assigned-topic marker (see this script's usage comment). Set when the user supplied
# the name, REMOVED otherwise -- a Claude-chosen or mechanical rename replaces whatever the
# user had named, so the topic stops being user-assigned and Claude Code's own session name
# takes the bold field back in sessions.md.
if [ "$named_by" = "user" ]; then
  : > "$STATED/$sid.usertopic" 2>/dev/null || true
else
  rm -f "$STATED/$sid.usertopic" 2>/dev/null || true
fi

if [ -f "$SESS" ] && [ -n "$topic_slug" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib-sessions-lock.sh"
  sessions_lock
  tmp="$(mktemp)"
  # Locate "-r <sid>" by position (not a fixed line prefix) to confirm this is
  # the right line, then replace field 1 (the name) with the new topic.
  awk -v s="$sid" -v t="$topic_slug" '
    {
      matched = 0
      for (i = 1; i <= NF; i++) if ($i == "-r" && $(i+1) == s) { matched = 1; break }
      if (matched) { $1 = t }
      print
    }
  ' "$SESS" > "$tmp" && sessions_write_through "$tmp" "$SESS"
  sessions_unlock
  bash "$(dirname "${BASH_SOURCE[0]}")/render-sessions-md.sh" 2>/dev/null || true
fi

echo "renamed: $OLD_PATH -> $NEW_PATH (session $sid)"
echo "NOTE: this does not rename the Claude Code session itself (the terminal-header title / claude --resume picker entry) -- that's a separate, client-side-only mechanism. Tell the user to run: /rename ${new_topic_raw}"
