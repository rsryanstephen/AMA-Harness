#!/usr/bin/env bash
# PreToolUse hook (Write). Blocks a Write into Claude Code's native, per-project auto-
# memory store (~/.claude/projects/<cwd-slug>/memory/*.md) -- gitignored and scoped to
# one directory's hash, so it's invisible on other machines and invisible in other
# sessions on this machine if cwd differs. This harness replaces that store entirely
# with a git-tracked, cross-machine one at ~/.claude/memory/ (see harness-memory skill).
# The skill's own trigger already covers the moment the system prompt's native memory
# instructions would normally fire, but nothing previously caught the mistake at the
# tool-call level -- same "prose alone isn't enough" lesson as symlink-write-gate.sh,
# same shape: deny with the redirect handed straight back, not a bare refusal.
set -u

payload="$(cat)"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[ -n "$file_path" ] || exit 0

case "$(printf '%s' "$file_path" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')" in
  */.claude/projects/*/memory/*) : ;;
  *) exit 0 ;;
esac

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "This is Claude Code'"'"'s native per-project auto-memory -- gitignored, invisible on other machines, invisible in other sessions if cwd differs. This harness replaces it entirely: write durable memory to ~/.claude/memory/<name>.md instead (see harness-memory skill for the file format)."
  }
}'
