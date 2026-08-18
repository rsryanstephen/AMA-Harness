#!/usr/bin/env bash
# PreToolUse hook (Write). Denies writing a standup-notes-<date>.md whose "Couldn't
# summarize" heading has no real bullet under it (or just "- None.") -- an unearned
# empty section is a false all-clear. Mechanical backstop for the prose rule in
# skills/ama-standup-notes/SKILL.md Step 3.6/5 (omit the heading entirely when empty),
# same pattern as bare-cd-gate.sh.
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

# Grab the "Couldn't summarize" section body: everything after that heading up to the
# next heading line or EOF.
section="$(printf '%s\n' "$content" | awk '
  /^#+[[:space:]]*Couldn.?t summarize/ { found=1; next }
  found && /^#+[[:space:]]/ { exit }
  found { print }
')"

[ -n "$section" ] || exit 0

# Has a real bullet if any line starts with "- " and isn't "None"/"N/A" (case-insensitive).
real_bullet="$(printf '%s\n' "$section" | grep -viP '^\s*-\s*(none|n/a)\.?\s*$' | grep -cP '^\s*-\s+\S')"

[ "$real_bullet" -gt 0 ] 2>/dev/null && exit 0

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "This standup-notes file has a \"Couldn'\''t summarize\" heading with no real entry under it (or just None/N/A) -- an unearned empty section is a false all-clear. Per ama-standup-notes/SKILL.md Step 3.6/5, this heading exists ONLY after an actual sweep found at least one unresolvable session this run -- if the section is empty, omit the heading entirely instead of writing None/N/A/a bare heading."
  }
}'
