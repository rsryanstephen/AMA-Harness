#!/usr/bin/env bash
# Usage: relocate-session.sh <session_id> <old chat file path> <new cwd>
# Called from on-prompt.sh the moment it notices this session's recorded chat file
# lives in a DIFFERENT directory than the current cwd -- which only happens because
# the user ran Claude Code's own `/cd <dir>` (the officially supported way to move a
# session's transcript; there is no tool to invoke it directly, so the model just tells
# the user to run it). This script follows suit for OUR bookkeeping: moves the chat.md
# file itself, repoints the session's state file, and updates its sessions.txt line --
# so streaming/references match the session's new home. Never touches the actual
# Claude Code transcript/context -- that's already relocated by `/cd` itself.
sid="$1"; old_chat="$2"; new_cwd="$3"
[ -n "$sid" ] && [ -n "$old_chat" ] && [ -n "$new_cwd" ] || { echo "usage: relocate-session.sh <sid> <old chat path> <new cwd>" >&2; exit 1; }

STATED="$HOME/.claude/.session-chatfiles"; SF="$STATED/$sid"

# old_chat is a symlink into <harness>/Chat files/ for a centralized session (see
# lib-chatfile-link.sh) -- basename is unchanged by a relocate (only the directory
# moves), so the central file itself never moves, only the symlink does.
# chatfile_relink_moved falls back to a plain mv + migrate for a pre-centralization
# session (old_chat not yet a symlink) and prints the resolved new path either way.
source "$(dirname "${BASH_SOURCE[0]}")/lib-chatfile-link.sh"
new_chat="$(chatfile_relink_moved "$old_chat" "$new_cwd")"
if [ -z "$new_chat" ]; then
  echo "chatfile_relink_moved failed for $old_chat -> $new_cwd" >&2
  exit 1
fi
mkdir -p "$STATED" 2>/dev/null
printf '%s' "$new_chat" > "$SF"

# Same Windows-drive -> "/c/..." -> "~/..." conversion the other hooks use, so the
# resume command this prints looks identical to the session-start/session-end ones.
if [[ "$new_cwd" =~ ^([A-Za-z]):(/.*)$ ]]; then
  drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
  unix_cwd="/$drive${BASH_REMATCH[2]}"
else
  unix_cwd="$new_cwd"
fi
if [[ "$unix_cwd" == "$HOME"* ]]; then
  display_cwd="~${unix_cwd#$HOME}"
else
  display_cwd="$unix_cwd"
fi
SESS="$HOME/.claude/sessions.txt"
if [ -f "$SESS" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib-sessions-lock.sh"
  sessions_lock
  tmp="$(mktemp)"
  # Line format is "<name> cd <dir> && claude -r <sid>" (no folder field --
  # dropped since it's already inside the cd path; no trailing timestamp -- removed).
  # Keep field 1 (name) and the sid field as-is, swap in the new "cd <dir> &&" prefix.
  awk -v s="$sid" -v newcd="cd $display_cwd" '
    {
      matched = 0
      for (i = 1; i <= NF; i++) if ($i == "-r" && $(i+1) == s) { matched = 1; idx = i; break }
      if (matched) {
        print $1 " " newcd " && " $(idx-1) " " $idx " " $(idx+1)
        next
      }
      print
    }
  ' "$SESS" > "$tmp" && sessions_write_through "$tmp" "$SESS"
  sessions_unlock
  bash "$(dirname "${BASH_SOURCE[0]}")/render-sessions-md.sh" 2>/dev/null || true
fi

printf 'NEWCHAT=%s\n' "$new_chat"
printf 'RESUME=cd %s && claude --resume %s\n' "$display_cwd" "$sid"
exit 0
