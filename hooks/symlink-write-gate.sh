#!/usr/bin/env bash
# PreToolUse hook (Edit/Write). Confirmed real, repeated pattern (session
# 8e0b62b6, ~10 occurrences in one sitting): a prose instruction to "resolve the
# real target first" before editing a harness file under ~/.claude (CLAUDE.md,
# README.md, AGENTS.md, skills/, hooks/, memory/, harness-gaps.md are symlinks/junctions into
# ama-claude-harness) didn't stop repeated direct attempts, each one wasting a
# call on the tool's own generic "Refusing to write through symlink" error, then
# a manual readlink to find the real path. This hook replaced that prose
# instruction entirely (removed from CLAUDE.md) -- same "self-recognition is
# unreliable" lesson CLAUDE.md already draws for library-version-sync.
#
# This fires BEFORE that generic refusal: resolve file_path with readlink -f (also
# canonicalizes a not-yet-existing Write target via its parent dir) and compare to
# the given path. Mismatch -> deny with the resolved real path handed straight
# back, so the next attempt goes right first try instead of guessing.
set -u

payload="$(cat)"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[ -n "$file_path" ] || exit 0

case "$(printf '%s' "$file_path" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')" in
  */.claude/*) : ;;
  *) exit 0 ;;
esac

real="$(readlink -f "$file_path" 2>/dev/null)"
[ -n "$real" ] || exit 0

# Normalize both to forward slashes for comparison -- readlink emits /c/... form.
given_norm="$(printf '%s' "$file_path" | tr '\134' '/')"
real_norm="$(printf '%s' "$real" | sed -E 's#^/([a-zA-Z])/#\U\1:/#')"

[ "$given_norm" != "$real_norm" ] || exit 0

jq -cn --arg real "$real_norm" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("This path is a symlink/junction into the ama-claude-harness repo -- Edit/Write cannot write through it. Use the resolved real path instead: " + $real)
  }
}'
