#!/usr/bin/env bash
# PostToolUse hook (Edit|Write). Records the content hash of a harness file THIS session
# just wrote, so on-stop.sh's auto_commit_push_harness can tell "my own edit" apart from
# "another session's later edit to the same path" -- own_paths there is a path allowlist,
# and a path a session legitimately edited earlier stays in that allowlist even after a
# DIFFERENT session overwrites it before this one's Stop fires -- a Stop once committed
# 3 files a concurrent session had just edited, under its own message, because path
# alone can't distinguish the two. This sidecar adds the missing content check.
#
# Rejected: comparing mtime against this session's transcript timestamps instead of a
# hash. A permission prompt can delay the actual write past the assistant-message
# timestamp -- the file gets skipped, and the NEXT Stop re-reads the same stale
# timestamp and skips it again, permanently dropping the session's own work. A hash has
# no clock in it at all.
set -u

payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[ -n "$sid" ] && [ -n "$file_path" ] || exit 0
[ -f "$file_path" ] || exit 0

harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$harness" ] || exit 0
claude_root="$(git -C "$HOME/.claude" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$claude_root" ] || claude_root="$HOME/.claude"

# Same translation on-stop.sh's auto_commit_push_harness already does for own_paths --
# must stay identical so a path recorded here matches what that function looks up.
norm() { printf '%s' "$1" | tr '\134' '/' | tr '[:upper:]' '[:lower:]'; }
harness_lc="$(norm "$harness")"
skills_lc="$(norm "$claude_root/skills")"
hooks_lc="$(norm "$claude_root/hooks")"
claudemd_lc="$(norm "$claude_root/CLAUDE.md")"
config_lc="$(norm "$claude_root/harness-config.json")"
f_lc="$(norm "$file_path")"

case "$f_lc" in
  "$skills_lc"/*) rel="skills${f_lc#"$skills_lc"}" ;;
  "$hooks_lc"/*) rel="hooks${f_lc#"$hooks_lc"}" ;;
  "$claudemd_lc") rel="claude.md" ;;
  "$config_lc") rel="harness-config.json" ;;
  "$harness_lc"/*) rel="${f_lc#"$harness_lc"/}" ;;
  *) exit 0 ;;
esac

hash="$(sha256sum "$file_path" 2>/dev/null | cut -d' ' -f1)"
# sha256sum prefixes the whole line with `\` when the input path contains a backslash
# (its own filename-escaping convention) -- Windows-style file_path values from the
# payload always do. Strip it, or every hash here permanently mismatches on-stop.sh's
# cur_hash (computed from a forward-slash git-relative path, never escaped).
hash="${hash#\\}"
[ -n "$hash" ] || exit 0

STATED="$HOME/.claude/.session-chatfiles"
mkdir -p "$STATED" 2>/dev/null
FILE="$STATED/$sid.harnesshashes"
touch "$FILE"
# Last write wins for this rel -- drop any prior line for it, then append the new one.
grep -vP "^\Q$rel\E\t" "$FILE" > "$FILE.tmp" 2>/dev/null || : > "$FILE.tmp"
printf '%s\t%s\n' "$rel" "$hash" >> "$FILE.tmp"
mv "$FILE.tmp" "$FILE"
