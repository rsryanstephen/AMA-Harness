#!/usr/bin/env bash
# Usage: dequeue-prompt.sh "<chat file path>"
# Finds the FIRST block (in file order) whose first line is a queue marker --
# 1-2 hyphens, optional single space, Q or q (accepts "-- Q", "--Q", "-Q", "- Q",
# "-- q", "- q", "-q") -- per the user's convention: pre-write a prompt in the
# chat file marked with a leading marker line. Removes that block from its
# current position, strips the marker line, and appends the remaining content as
# a normal block at the end of the file -- so it reads like a freshly-submitted
# prompt, ready to be worked on next. Leaves any OTHER queued blocks as-is.
# Prints the dequeued prompt text to stdout (so the caller can act on it) and
# exits non-zero with no output if there's nothing queued (file left untouched).
#
# Always flushes any not-yet-mirrored reply text into the file FIRST (see
# flush-reply.sh) -- Stop only fires once, at the true end of the whole turn, so
# calling this repeatedly within one turn would otherwise write several prompts
# back-to-back with all their replies dumped in one lump at the end. Confirmed
# real. Folded in here (not left as a separate manual step) so a single call is
# correct by construction, instead of relying on remembering two steps in order.
FILE="$1"
[ -n "$FILE" ] || { echo "usage: dequeue-prompt.sh <chat file path>" >&2; exit 1; }
[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/flush-reply.sh" "$FILE" 2>/dev/null || true

awk -v outfile="$FILE.new" -v qfile="$FILE.dequeued" '
  function flush() { blocks[++nb] = cur; cur = "" }
  BEGIN { nb = 0; cur = ""; found = 0 }
  /^---[[:space:]]*$/ { flush(); next }
  { cur = (cur == "" ? $0 : cur "\n" $0) }
  END {
    flush()
    for (i = 1; i <= nb; i++) {
      b = blocks[i]
      trimmed = b
      gsub(/^[\n]+/, "", trimmed)
      if (!found && trimmed ~ /^-{1,2}[[:space:]]?[Qq][[:space:]]*\n/) {
        found = i
        # strip the marker line (and one following blank line if present)
        sub(/^[\n]*-{1,2}[[:space:]]?[Qq][[:space:]]*\n[\n]?/, "", trimmed)
        dequeued = trimmed
      }
    }
    if (!found) { exit 7 }
    for (i = 1; i <= nb; i++) {
      if (i == found) continue
      b = blocks[i]
      gsub(/^[\n]+|[\n]+$/, "", b)
      if (b == "") continue
      if (out != "") out = out "\n\n---\n\n" b; else out = b
    }
    gsub(/^[\n]+|[\n]+$/, "", dequeued)
    if (out != "") out = out "\n\n---\n\n" dequeued; else out = dequeued
    print out > outfile
    printf "%s", dequeued > qfile
  }
' "$FILE"
rc=$?
if [ "$rc" != 0 ]; then
  rm -f "$FILE.new" "$FILE.dequeued" 2>/dev/null
  exit 1
fi

printf '\n' >> "$FILE.new"
# $FILE is a symlink into <harness>/Chat files/ for a centralized session (see
# lib-chatfile-link.sh) -- `mv` onto it would replace the LINK ITSELF with a plain
# file (rename() doesn't follow symlinks at the destination), silently detaching it
# from the central copy. Write through the link instead so the target gets updated
# and the link survives. Pre-centralization session (not yet a symlink) keeps the
# original mv.
if [ -L "$FILE" ]; then
  cat "$FILE.new" > "$FILE"
  rm -f "$FILE.new"
else
  mv "$FILE.new" "$FILE"
fi
cat "$FILE.dequeued"
rm -f "$FILE.dequeued"
exit 0
