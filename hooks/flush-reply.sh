#!/usr/bin/env bash
# Usage: flush-reply.sh "<chat file path>"
# Manually flushes any not-yet-mirrored reply text into the chat file RIGHT NOW,
# instead of waiting for the Stop hook (which only fires once, at the very end of
# the whole continuous turn). Needed when processing a prompt queue: without this,
# calling dequeue-prompt.sh multiple times in one turn writes several prompts to
# the file up front, while all their replies land in one lump at the true end --
# confirmed via a real incident (two dequeued prompts back-to-back, zero replies
# in between). Call this BEFORE each dequeue to flush the just-finished reply into
# its correct chronological position first.
# Same mechanism as on-stop.sh's mirror_reply: extracts only "text" content blocks
# from the transcript since the last mirrored offset, verbatim, zero LLM tokens.
# Silent no-op if there's nothing new to flush.
CHAT="$1"
[ -n "$CHAT" ] || { echo "usage: flush-reply.sh <chat file path>" >&2; exit 1; }
[ -f "$CHAT" ] || { echo "no such file: $CHAT" >&2; exit 1; }

STATED="$HOME/.claude/.session-chatfiles"

# Reverse-lookup: find the session whose state file currently points at this chat file.
# Fork-free iteration copied from on-prompt.sh's claimed_paths loop -- the previous
# $(cat)-per-file version forked ~300 times against this machine's real 380-file
# directory at ~60ms/fork (~18s). Skip is "any dotted suffix": real sid statefiles
# never contain a dot, every bookkeeping suffix (.stopoffset, .ticket, .aititle, ...)
# does -- enumerating suffixes drifts as new ones get added (confirmed: the old list
# here knew only .stopoffset, six suffixes behind reality).
sid=""
for f in "$STATED"/*; do
  case "${f##*/}" in *.*) continue ;; esac
  [ -f "$f" ] || continue
  # `read` exits 1 on EOF-with-no-trailing-newline -- and every statefile IS written
  # that way -- so test the VARIABLE, never read's exit status (on-prompt.sh:91 gotcha).
  stored=""
  IFS= read -r stored < "$f" 2>/dev/null || true
  if [ -n "$stored" ] && [ "$stored" = "$CHAT" ]; then sid="${f##*/}"; break; fi
done
[ -n "$sid" ] || { echo "no session state points at: $CHAT" >&2; exit 1; }

tr_path="$(find "$HOME/.claude/projects" -name "$sid.jsonl" -not -path "*/subagents/*" 2>/dev/null | head -1)"
[ -n "$tr_path" ] && [ -f "$tr_path" ] || { echo "no transcript found for session: $sid" >&2; exit 1; }

OFF="$STATED/$sid.stopoffset"

total="$(wc -l < "$tr_path" | tr -d ' ')"
last="0"; [ -f "$OFF" ] && last="$(cat "$OFF")"
[ "$last" -lt "$total" ] || exit 0

slice="$(tail -n +"$((last + 1))" "$tr_path")"
# tr -d '\r' strips CRLF-translation jq.exe applies to embedded newlines on Windows --
# left in, it corrupts "---" dividers built from jq's own join() (found via local
# testing: two recaps in one batch got an unmatchable "---\r" divider between them).
reply_text="$(printf '%s' "$slice" | jq -s -r '
  [.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text]
  | join("\n\n")
' 2>/dev/null | tr -d '\r')"

# Also mirror the two Claude-Code-generated recap types (away_summary + isCompactSummary)
# -- prefixed "recap:", joined with a REAL "---" divider (own block) so on-prompt.sh's
# next-prompt cleanup can strip it -- fusing it into the reply block made it unstrippable
# (confirmed via a real incident). Same mechanism as on-stop.sh's mirror_reply.
recap_text="$(printf '%s' "$slice" | jq -s -r '
  [.[] |
    if (.type=="system" and .subtype=="away_summary") then ("recap:\n\n" + (.content // ""))
    elif (.type=="user" and .isCompactSummary==true) then ("recap:\n\n" + (.message.content // ""))
    else empty end
  ] | join("\n\n---\n\n")
' 2>/dev/null | tr -d '\r')"

if [ -n "$reply_text" ] && [ -n "$recap_text" ]; then
  text="$reply_text
---

$recap_text"
elif [ -n "$recap_text" ]; then
  text="$recap_text"
else
  text="$reply_text"
fi

printf '%s' "$total" > "$OFF"
[ -n "$text" ] || exit 0

if [ -s "$CHAT" ]; then printf '\n---\n\n%s\n' "$text" >> "$CHAT"; else printf '%s\n' "$text" >> "$CHAT"; fi
exit 0
