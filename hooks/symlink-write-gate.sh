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
# the given path. Mismatch -> REWRITE the call to the real path (updatedInput, no
# permissionDecision -- so the normal permission flow and every sibling gate still
# apply; an explicit allow could override a sibling deny).
#
# Was a deny with the real path handed back until 2026-10-21. The deny never stopped the
# first attempt: every skill loads with "Base directory: ~/.claude/skills/<x>", so agents
# edit there by default, and each one paid a wasted call. Worse, in a parallel batch the
# denied Edit's dependants (a pathspec commit of that file) still ran -- session 1dc0f3dd
# committed another session's uncommitted lines under its own message that way.
# Read-before-edit is satisfied across the two spellings (verified live: Read via the
# link, Edit via the real path, accepted). No other Edit|Write hook returns updatedInput;
# two would be undefined (docs: last-writer not specified).
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

real_win="$(printf '%s' "$real_norm" | tr '/' '\134')"
printf '%s' "$payload" | jq -c --arg real "$real_win" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: (.tool_input + {file_path: $real}),
    additionalContext: ("symlink-write-gate: that ~/.claude path is a link into the ama-claude-harness repo, so this call was redirected to the real file " + $real + ". Use the real path for later edits and git commands on it.")
  }
}'
