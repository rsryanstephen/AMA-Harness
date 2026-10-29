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
source "$(dirname "${BASH_SOURCE[0]}")/lib-chatfile-link.sh"
chat_path="$(chatfile_default_path "$cwd" "$sid")"
printf '%s' "$chat_path" > "$STATED/$sid"

# Centralize: cwd keeps this exact path (statefile above is unchanged), but it's a
# symlink into <harness>/Chat files/ -- see lib-chatfile-link.sh. Dangling is fine, the
# first on-prompt.sh append materializes the real file at the link's target (confirmed
# real in a scratchpad test: `>>` through a dangling Windows symlink creates the
# target). Best-effort: a harness repo that can't be resolved just leaves the chat file
# in cwd as before, never blocks session start.
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
  source "$(dirname "${BASH_SOURCE[0]}")/lib-session-kind.sh"
  source "$(dirname "${BASH_SOURCE[0]}")/lib-sessions-lock.sh"
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
    # NOT `[ -f "$other_chat" ]` -- a recorded path that has gone missing (its symlink
    # deleted, or migrated to a different location the statefile never got updated for)
    # is exactly the case chatfile_ensure_link below exists to repair, not a reason to
    # skip. Confirmed real: session 69f0122c's real chat content already lived in
    # `Chat files/`, but its recorded "Local Chat Files/" symlink was gone, and this
    # exact `-f` guard silently skipped it forever instead of letting the repair below
    # run. Only bail if nothing was ever recorded at all.
    [ -n "$other_chat" ] || continue

    tr_path="$(find "$HOME/.claude/projects" -name "$other_sid.jsonl" -not -path "*/subagents/*" 2>/dev/null | head -1)"
    [ -n "$tr_path" ] || continue
    # Never rename, relocate or re-row a headless run's leftovers -- this sweep would
    # otherwise re-materialize the very trace on-prompt.sh deleted the moment it knew the
    # session was headless. scripts/prune-headless-sessions.sh removes them instead.
    session_is_headless "$tr_path" && continue
    tr_mtime="$(stat -c %Y "$tr_path" 2>/dev/null || echo 0)"
    age=$(( now_epoch - tr_mtime ))
    [ "$age" -gt 600 ] || continue

    # Migration for pre-centralization AND pre-"Local Chat Files/"-subfolder sessions:
    # only under the same 10+-minute-inactive gate above -- a live session's file could
    # be mid-append (open handle) and `mv`/relocate on Windows can fail/lock against
    # that. Capture + persist: chatfile_ensure_link can relocate an already-centralized
    # link down into the subfolder, which stale $other_chat/$other_sf must reflect.
    ensured="$(chatfile_ensure_link "$other_chat" "${other_sid%%-*}" 2>/dev/null)"
    if [ -n "$ensured" ] && [ "$ensured" != "$other_chat" ]; then
      other_chat="$ensured"
      printf '%s' "$other_chat" > "$other_sf"
    fi

    attempt_fallback_rename "$other_sid" "$other_chat" "$(chatfile_session_cwd "$other_chat")"

    # Reconcile sessions.txt field 1 to the chat file's ACTUAL basename when it's
    # fallen behind -- distinct from the repair above. Confirmed real: 69f0122c's chat
    # file already carried a real name ("ama-claude-harness-17"), but sessions.txt
    # field 1 still showed the bare shortid, because nothing reconciles that field for
    # a dead session that never prompts again (on-prompt.sh only backfills it on that
    # SAME session's own next prompt). Same one-line pattern as on-prompt.sh's own
    # backfill (:356), applied here for OTHER sessions this sweep already touched.
    other_topic="$(basename "$other_chat")"; other_topic="${other_topic% Chat.md}"
    if [ "$other_topic" != "$other_short" ]; then
      sessions_lock
      matched_line="$(awk -v s="$other_sid" '{ for (i=1;i<=NF;i++) if ($i=="-r" && $(i+1)==s) { print; exit } }' "$SESS")"
      cur_name="${matched_line%% *}"
      if [ -n "$matched_line" ] && [ "$cur_name" = "$other_short" ]; then
        new_line="$other_topic ${matched_line#* }"
        tmp="$(mktemp)"
        awk -v s="$other_sid" -v nl="$new_line" '{ matched=0; for (i=1;i<=NF;i++) if ($i=="-r" && $(i+1)==s) { matched=1; break }; if (matched) print nl; else print }' "$SESS" > "$tmp" \
          && sessions_write_through "$tmp" "$SESS"
      fi
      sessions_unlock
    fi
  done < "$SESS"
fi
exit 0
