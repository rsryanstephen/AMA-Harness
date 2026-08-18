#!/usr/bin/env bash
# SessionStart hook (startup sessions only do work):
#   1. Record this session's initial chat-log path in the state dir so the
#      UserPromptSubmit hook (on-prompt.sh) can find/rename it. Initial name is
#      "<cwd>/<session_id> Chat.md"; on-prompt renames it to "<folder>-<topic> Chat.md"
#      after the first prompt and updates this state file.
#   2. Does NOT append to ~/.claude/sessions.txt here -- a session opened and closed
#      with zero prompts used to still get a line the instant it started. on-prompt.sh
#      already self-heals a missing entry the first time a real prompt lands (see its
#      own "Missing entirely" branch), so deferring entirely to that path means a
#      session with no interaction just never gets a line at all, which is correct.
#   3. Retroactive fallback-rename sweep: an abrupt exit (crash, killed terminal) skips
#      SessionEnd entirely, so a session can get permanently stuck on its bare shortid
#      fallback name with nothing to catch it (documented in on-session-end.sh). Use
#      every later session's own startup as an opportunistic repair point instead of
#      relying solely on that session's own clean exit.
# On resume/clear/compact we do nothing, so an already-renamed session keeps its file.
payload="$(cat)"
src="$(printf '%s' "$payload" | jq -r '.source // empty')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
# Normalize to forward slashes so "$cwd/<name>" never mixes separators
# (payload cwd is Windows-style backslash; joining with "/" produced e.g.
# "C:\Users\...\repo/name Chat.md").
cwd="$(printf '%s' "$cwd" | tr '\134' '/')"
# .session-chatfiles is internal bookkeeping, never a legitimate session cwd -- if it
# shows up here, a stray `cd` (in an earlier tool call) leaked into Claude Code's own
# reported cwd. Confirmed twice; fall back to the parent dir rather than corrupt paths.
case "$cwd" in */.session-chatfiles) cwd="${cwd%/.session-chatfiles}" ;; esac

[ "$src" = "startup" ] || exit 0
[ -n "$sid" ] || exit 0

# Initialize the per-session chat-log path to the fallback name (short session id only;
# no folder prefix). on-prompt.sh overrides this the moment a "See ... prompt in
# <name> Chat.md" pointer names a file, and creates the sessions.txt line itself on
# the first real prompt (see that hook's own comment) -- nothing to do here for either.
STATED="$HOME/.claude/.session-chatfiles"
mkdir -p "$STATED" 2>/dev/null
chat_path="$cwd/${sid%%-*} Chat.md"
printf '%s' "$chat_path" > "$STATED/$sid"

# Centralize: cwd keeps this exact path (statefile above is unchanged), but it's a
# symlink into <harness>/Chat files/ -- see lib-chatfile-link.sh. Dangling is fine, the
# first on-prompt.sh append materializes the real file at the link's target (confirmed
# real in a scratchpad test: `>>` through a dangling Windows symlink creates the
# target). Best-effort: a harness repo that can't be resolved just leaves the chat file
# in cwd as before, never blocks session start.
source "$(dirname "${BASH_SOURCE[0]}")/lib-chatfile-link.sh"
chatfile_ensure_link "$chat_path" "${sid%%-*}" >/dev/null 2>&1 || true

# Retroactive fallback-rename sweep for OTHER sessions (never this one -- it just
# started, has no chat file yet). Only touch a stale entry whose transcript hasn't
# been touched in 10+ minutes -- a genuinely live concurrent session keeps writing to
# its own transcript continuously, so this avoids racing an in-progress session's own
# clean-exit rename. Bounded to the first 20 stale lines found so a large sessions.txt
# doesn't slow every startup down.
SESS="$HOME/.claude/sessions.txt"
if [ -f "$SESS" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib-fallback-rename.sh"
  now_epoch="$(date +%s)"
  swept=0
  while IFS= read -r line; do
    [ "$swept" -lt 20 ] || break
    other_short="$(printf '%s' "$line" | awk '{print $1}')"
    other_sid="$(printf '%s' "$line" | grep -oP -- 'claude -r \K\S+')"
    [ -n "$other_sid" ] || continue
    [ "$other_sid" = "$sid" ] && continue
    [ "$other_short" = "${other_sid%%-*}" ] || continue
    swept=$((swept + 1))

    other_sf="$STATED/$other_sid"
    [ -f "$other_sf" ] || continue
    other_chat="$(cat "$other_sf")"
    [ -f "$other_chat" ] || continue

    tr_path="$(find "$HOME/.claude/projects" -name "$other_sid.jsonl" -not -path "*/subagents/*" 2>/dev/null | head -1)"
    [ -n "$tr_path" ] || continue
    tr_mtime="$(stat -c %Y "$tr_path" 2>/dev/null || echo 0)"
    age=$(( now_epoch - tr_mtime ))
    [ "$age" -gt 600 ] || continue

    # One-time migration for pre-centralization sessions: only under the same
    # 10+-minute-inactive gate above -- a live session's file could be mid-append
    # (open handle) and `mv` on Windows can fail/lock against that.
    chatfile_ensure_link "$other_chat" "${other_sid%%-*}" >/dev/null 2>&1 || true

    attempt_fallback_rename "$other_sid" "$other_chat" "$(dirname "$other_chat")"
  done < "$SESS"
fi
exit 0
