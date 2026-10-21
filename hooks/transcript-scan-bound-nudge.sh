#!/usr/bin/env bash
# PreToolUse nudge (Edit|Write -- never denies, additionalContext only). A hooks/*.sh
# change whose NEW text reads the session transcript with grep/jq and shows no tail/head
# bound gets a reminder: transcripts only grow (96MB seen on one session) and an unbounded
# scan blew notify-sound.sh's whole hook timeout silently, killing every tone
# (PROJ-15356; remaining pre-existing sites tracked in PROJ-15357). Rule was
# prose-only in AGENTS.md ("a hook that greps the transcript MUST bound the read to a
# tail window") until PROJ-15361's hookability audit.
#
# Coarse by design (warn-only): it looks at the new_string/content being written, not the
# whole file -- an edit that adds an unbounded scan while a bound exists elsewhere in the
# file for a DIFFERENT read will still warn; that costs one advisory line, never a deny.
set -u

IFS= read -r -d '' payload || true
case "$payload" in *transcript*) ;; *) exit 0 ;; esac

path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' | tr -d '\r' | tr '\134' '/')"
case "$path" in */hooks/*.sh) ;; *) exit 0 ;; esac

new="$(printf '%s' "$payload" | jq -r '(.tool_input.new_string // .tool_input.content) // empty')"
[ -n "$new" ] || exit 0

printf '%s' "$new" | grep -q 'transcript_path\|transcript' || exit 0
printf '%s' "$new" | grep -qE '\b(grep|jq)\b' || exit 0
printf '%s' "$new" | grep -qE '\b(tail|head)\b' && exit 0

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: "This hook edit reads the session transcript with grep/jq and the new text shows no tail/head bound. Transcripts only grow (96MB seen) -- an unbounded scan blew a hook'\''s whole timeout silently (PROJ-15356, killed every notification tone). Bound the read: tail -n <window> \"$tr\" | grep ..., window sized to \"any turn in which this could still be true\" (notify-sound.sh uses 3000 lines). Warn-only -- ignore if the read is genuinely bounded elsewhere in the pipeline."
  }
}'
