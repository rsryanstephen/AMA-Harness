#!/usr/bin/env bash
# SessionEnd hook: when the CLI session ends (e.g. user types "exit"), append a
# "resume with" line to this session's chat log. Purely mechanical, zero LLM tokens.
# IMPORTANT: the backtick-quoted command is ONLY "claude --resume <id>" -- per
# `claude --help` ("Usage: claude [options] [command] [prompt]"), any trailing
# positional text is treated as an initial prompt and auto-submitted the moment the
# resumed session starts. Extra info (cwd) goes OUTSIDE the backticks as plain text,
# never appended to the runnable command itself.
payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
[ -n "$sid" ] || exit 0
[ -n "$cwd" ] || exit 0
# Normalize to forward slashes so "$cwd/<name>" never mixes separators.
cwd="$(printf '%s' "$cwd" | tr '\134' '/')"
# .session-chatfiles is internal bookkeeping, never a legitimate session cwd -- if it
# shows up here, a stray `cd` (in an earlier tool call) leaked into Claude Code's own
# reported cwd. Confirmed twice; fall back to the parent dir rather than corrupt paths.
case "$cwd" in */.session-chatfiles) cwd="${cwd%/.session-chatfiles}" ;; esac

STATED="$HOME/.claude/.session-chatfiles"; SF="$STATED/$sid"
default="$cwd/${sid%%-*} Chat.md"
if [ -f "$SF" ]; then CHAT="$(cat "$SF")"; else CHAT="$default"; fi

# A session with zero real interaction (opened, exited, never sent a prompt) has no
# chat file yet, or one that's still empty -- don't create one just to hold a resume
# notice nobody will ever use. Confirmed real bug: when this ran anyway, the mechanical
# fallback rename below (nothing to name it from except the notice itself) slugified
# the notice's OWN text into a garbage filename ("resume-session-with-cd-claude-...").
[ -s "$CHAT" ] || exit 0

# Prefer OUR bookkeeping's directory over the payload's own cwd, when we have it --
# confirmed via a real incident: SessionEnd fired a second time reporting a STALE cwd
# (the pre-relocation directory) even though this session had already been correctly
# relocated, producing a second, wrong "resume with" notice pointing at the old location
# after the correct one. relocate-session.sh keeps our state file accurate the moment a
# real /cd happens; a payload field can lag behind that, so trust the state file instead.
resume_dir="$cwd"
[ -f "$SF" ] && resume_dir="$(dirname "$CHAT")"

# Resuming a session needs to happen from its original cwd, so fold a "cd" into the
# copy-pasteable command. Convert cwd to a bash-friendly path: "C:/..." -> "/c/...",
# and shorten the home directory to "~".
slash_cwd="$resume_dir"
if [[ "$slash_cwd" =~ ^([A-Za-z]):(/.*)$ ]]; then
  drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
  unix_cwd="/$drive${BASH_REMATCH[2]}"
else
  unix_cwd="$slash_cwd"
fi
if [[ "$unix_cwd" == "$HOME"* ]]; then
  display_cwd="~${unix_cwd#$HOME}"
else
  display_cwd="$unix_cwd"
fi

line="Resume session with \`cd $display_cwd && claude --resume $sid\`"

# Skip if the file's last block is already this exact notice -- SessionEnd can fire
# more than once for the same exit (confirmed via the incident above); don't stack
# duplicate/stale notices.
already_last="$(awk 'BEGIN{RS="\n---\n"} {b=$0} END{gsub(/^[\n]+|[\n]+$/,"",b); print b}' "$CHAT" 2>/dev/null)"
if [ "$already_last" != "$line" ]; then
  if [ -s "$CHAT" ]; then printf '\n---\n\n%s\n' "$line" >> "$CHAT"; else printf '%s\n' "$line" >> "$CHAT"; fi
fi

# Mechanical fallback rename: CLAUDE.md tells the model to rename an unnamed session
# unprompted, mid-session, once the topic's clear -- but that needs a turn to fire in,
# and a session whose last real action was its final task (then straight to exit) never
# gets one. Confirmed via two real incidents: exited still fallback-named, nothing to
# catch it. A per-turn reminder helps if the user comes back and sends anything first,
# but can't cover this exact shape. This always runs at actual exit, no model needed.
# Shared with log-session-start.sh's retroactive sweep (same logic, different trigger --
# this covers a clean exit, that one covers an abrupt exit that skipped SessionEnd
# entirely).
source "$(dirname "${BASH_SOURCE[0]}")/lib-fallback-rename.sh"
attempt_fallback_rename "$sid" "$CHAT" "$resume_dir"

# Unconditional render at exit -- covers the case where this session's very last turn was
# the one that first captured its explicitname/aititle (on-stop.sh's own change-gated
# render already fired for that, but a session that never gets ANOTHER turn after that
# needs this as a backstop; cheap, one render per exit, sessions.md is gitignored so it's
# not auto-commit churn either way).
bash "$(dirname "${BASH_SOURCE[0]}")/render-sessions-md.sh" 2>/dev/null || true
exit 0
