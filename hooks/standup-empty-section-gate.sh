#!/usr/bin/env bash
# PreToolUse hook (Write). Denies writing a standup-notes-<date>.md whose "Couldn't
# summarize" or "Action items" heading has no real bullet under it (or just "- None.") --
# an unearned empty section is a false all-clear. Mechanical backstop for the prose rule in
# skills/ama-standup-notes/SKILL.md Step 3.6/5 (omit the heading entirely when empty),
# same pattern as bare-cd-gate.sh.
#
# "Action items" is the worse of the two: empty, it reads as "no outstanding commitments"
# when the truth is nobody looked. Step 3b carries those forward until addressed, so a
# blank one means the Zoom fetch or the ledger read failed, not that the list is clear.
#
# The unattended 9:00 path only reaches this hook because standup-unattended-run.sh grants
# `Write`. It used to grant `Bash` but not `Write`, so the run wrote the file by redirect
# and this gate never fired on the one path that runs every morning. Don't drop `Write`
# from that allowlist.
#
# "Client mail" and "Decisions" added 2026-08-25 (<harnessEpicKey>) alongside the same
# risk as "Action items": both carry forward / accumulate rather than reset daily, so an
# empty one reads as "nothing outstanding" when the truth could be a failed sweep.
set -u

payload="$(cat)"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
content="$(printf '%s' "$payload" | jq -r '.tool_input.content // empty')"

[ -n "$path" ] || exit 0
case "$path" in
  *standup-notes-*.md) : ;;
  *) exit 0 ;;
esac
[ -n "$content" ] || exit 0

# Each guarded heading is checked SEPARATELY. Concatenating them would let a populated
# "Couldn't summarize" mask an empty "Action items" -- and the awk below stops at the next
# heading anyway, so a single pass only ever sees whichever comes first.
# Note "Couldn't" carries an apostrophe -- `Couldn.?t` matches that and the bare spelling.
empty=""
for heading in "Couldn.?t summarize" "Client mail" "Decisions" "Action items"; do
  section="$(printf '%s\n' "$content" | awk -v h="^#+[[:space:]]*$heading" '
    $0 ~ h { found=1; next }
    found && /^#+[[:space:]]/ { exit }
    found { print }
  ')"
  # Heading absent entirely -- fine, omitting it is the correct behaviour.
  printf '%s\n' "$content" | grep -qE "^#+[[:space:]]*$heading" || continue

  # Has a real bullet if any line starts with "- " and isn't "None"/"N/A" (case-insensitive).
  real_bullet="$(printf '%s\n' "$section" | grep -viP '^\s*-\s*(none|n/a)\.?\s*$' | grep -cP '^\s*-\s+\S')"
  [ "$real_bullet" -gt 0 ] 2>/dev/null && continue

  # Report the human spelling, not the regex.
  case "$heading" in
    "Action items") empty="Action items" ;;
    "Client mail") empty="Client mail" ;;
    "Decisions") empty="Decisions" ;;
    *) empty="Couldn't summarize" ;;
  esac
  break
done

# Bare movement bullet (2026-08-21, third bare-label defect in this skill): `- **PROJ-N**
# ...` with no indented prose before the next bullet/heading tells the reader only that a
# number moved. Step 4a says fall back to the Jira summary -- enforce it here.
bare_key="$(printf '%s\n' "$content" | awk '
  /^[[:space:]]*-[[:space:]]+\*\*PROJ-[0-9]+\*\*/ { if (pend) print pend; pend=$0; next }
  pend && /^[[:space:]]{2,}[^[:space:]]/ { pend=""; next }
  pend && (/^[[:space:]]*-[[:space:]]/ || /^#+[[:space:]]/) { print pend; pend="" }
  END { if (pend) print pend }' | head -1)"
if [ -z "$empty" ] && [ -n "$bare_key" ]; then
  jq -cn --arg l "$bare_key" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
    permissionDecisionReason:("Bare movement bullet with nothing under it: " + $l + " -- the reader learns only that a number moved. Per ama-standup-notes Step 4a, indent one line of explanation beneath it (fall back to the ticket'"'"'s Jira summary, already fetched in Step 2).")}}'
  exit 0
fi

[ -n "$empty" ] || exit 0

jq -cn --arg h "$empty" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("This standup-notes file has a \"" + $h + "\" heading with no real entry under it (or just None/N/A) -- an unearned empty section is a false all-clear. Per ama-standup-notes/SKILL.md, a guarded heading exists ONLY when this run produced at least one real entry for it: \"Couldn'"'"'t summarize\" needs a session an actual sweep could not resolve (Step 3.6/5); \"Client mail\" needs an in-window client thread (Step 3a); \"Decisions\"/\"Action items\" need a standing ledger entry of that kind (Step 3b), and empty reads as \"nothing outstanding\" when the truth is the sweep or ledger read failed. Omit the heading entirely instead of writing None/N/A/a bare heading.")
  }
}'
