#!/usr/bin/env bash
# Usage: rename-topic.sh <cwd> <current chat filename> <new topic text>
#
# INTERNAL now -- one-name-per-session means the chat filename must always match
# Claude Code's own session name, so the harness cannot let a model or the user set a
# topic independently of that (see skills/rename-topic/SKILL.md: the user-facing path
# is "run /rename X yourself", not this script). Callers: lib-fallback-rename.sh's
# sync_session_name (every turn a live session's CC name changes) and
# attempt_fallback_rename (once, for a session still on its bare shortid).
# Does the full rename mechanically: renames the .md file, repoints that session's
# state file, and sets/replaces the topic field on its sessions.txt line -- all in one
# atomic-ish operation instead of 3 hand-done steps.
set -e
cwd="$1"; old_name="$2"; new_topic_raw="$3"
if [ -z "$cwd" ] || [ -z "$old_name" ] || [ -z "$new_topic_raw" ]; then
  echo "usage: rename-topic.sh <cwd> <current chat filename> <new topic text>" >&2
  exit 1
fi

STATED="$HOME/.claude/.session-chatfiles"
SESS="$HOME/.claude/sessions.txt"
source "$(dirname "${BASH_SOURCE[0]}")/lib-chatfile-link.sh"

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
  stored_dir="$(chatfile_session_cwd "$stored")"; stored_dir="${stored_dir//\\//}"
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
# session (OLD_PATH not yet a symlink). Already sourced above (needed earlier, for
# chatfile_session_cwd in the disambiguation loop).
# Persist the path it PRINTS: a name another session holds comes back own-suffixed.
linked="$(chatfile_relink_renamed "$OLD_PATH" "$NEW_PATH" "${sid%%-*}")" || {
  echo "chatfile_relink_renamed failed for $OLD_PATH -> $NEW_PATH" >&2
  exit 1
}
[ -n "$linked" ] && NEW_PATH="$linked"
printf '%s' "$NEW_PATH" > "$STATED/$sid"

# Superseded-name alias log -- one-name-per-session means an old name stops appearing
# ANYWHERE once renamed (unlike the old two-name display), so a session that drifted
# through several auto-titles is only greppable by its LATEST name. This is the single
# choke point every rename (mechanical or CC-name-follow) passes through, so one append
# here covers all of them. Per-machine runtime state, gitignored alongside sessions.txt.
printf '%s %s\n' "$topic_slug" "$sid" >> "$HOME/.claude/session-names.txt" 2>/dev/null || true

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
