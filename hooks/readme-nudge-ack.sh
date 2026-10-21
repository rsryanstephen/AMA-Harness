#!/usr/bin/env bash
# Usage: readme-nudge-ack.sh <key> [session_id]
# Model-invoked (not a hook), escape hatch for readme-currency-gate.sh's nudge.
# Call ONLY after actually checking AGENTS.md's mention of <key> and confirming its
# description still matches -- not to silence the nudge without looking. <key> is the
# same string the gate reasons about (hook basename, or skill dir name for skills/*/*).
# session_id defaults to $CLAUDE_SESSION_ID if not passed.
set -u
key="${1:?usage: readme-nudge-ack.sh <key> [session_id]}"
sid="${2:-${CLAUDE_SESSION_ID:-}}"
[ -n "$sid" ] || { echo "usage: readme-nudge-ack.sh <key> <session_id>" >&2; exit 1; }

NUDGEFILE="$HOME/.claude/.session-chatfiles/$sid.readmenudge"
[ -f "$NUDGEFILE" ] || { echo "no outstanding nudge for session $sid"; exit 0; }

prev_line="$(grep -P "^\Q$key\E\t" "$NUDGEFILE" 2>/dev/null | tail -1)"
[ -n "$prev_line" ] || { echo "no outstanding nudge for key '$key'"; exit 0; }
total="$(printf '%s' "$prev_line" | cut -f2)"

grep -vP "^\Q$key\E\t" "$NUDGEFILE" > "$NUDGEFILE.tmp" 2>/dev/null || : > "$NUDGEFILE.tmp"
printf '%s\t%s\t0\n' "$key" "$total" >> "$NUDGEFILE.tmp"
mv "$NUDGEFILE.tmp" "$NUDGEFILE"
echo "acked: AGENTS.md nudge for '$key' cleared (checked, no change needed)"
