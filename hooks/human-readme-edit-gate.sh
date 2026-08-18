#!/usr/bin/env bash
# PostToolUse hook (Edit|Write). README.md is the human-facing doc (AGENTS.md is the
# agent-facing one, see its banner) -- <harnessEpicKey>'s human/agent doc split requires
# README.md update ONLY when a change is human-visible, never swept along by
# readme-currency-gate.sh's per-harness-edit loop the way AGENTS.md is. Reminder-only
# (PostToolUse decision:"block" reaches the model on the next turn -- same channel
# readme-currency-gate.sh already proved, confirmed against a real transcript there),
# never denies the edit itself. Deliberately NOT a PreToolUse warn: PreToolUse warn-only
# in this repo is permissionDecision:"allow" (chrome-verify-nudge.sh,
# subagent-model-tiering-gate.sh), which bypasses the user's own permission prompt --
# the opposite of the intent here.
set -u

payload="$(cat)"

# Fork-budget needle test on the raw payload before any jq, per AGENTS.md's "Hook fork
# budget" convention -- a call touching no README.md path exits on zero forks.
case "$payload" in
  *[Rr][Ee][Aa][Dd][Mm][Ee].[Mm][Dd]*) : ;;
  *) exit 0 ;;
esac

sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[ -n "$sid" ] && [ -n "$file_path" ] || exit 0

harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$harness" ] || exit 0

# Same lowering-normalization convention as readme-currency-gate.sh -- resolved path,
# never a glob, so this never fires on some other fleet repo's own README.md.
norm() { printf '%s' "$1" | tr '\134' '/' | tr '[:upper:]' '[:lower:]'; }
f_lc="$(norm "$file_path")"
harness_readme_lc="$(norm "$harness/README.md")"
claude_readme_lc="$(norm "$HOME/.claude/README.md")"

case "$f_lc" in
  "$harness_readme_lc"|"$claude_readme_lc") : ;;
  *) exit 0 ;;
esac

# One-shot per session.
STATED="$HOME/.claude/.session-chatfiles"
mkdir -p "$STATED" 2>/dev/null
FLAGFILE="$STATED/$sid.humanreadmenudged"
[ -f "$FLAGFILE" ] && exit 0
touch "$FLAGFILE"

jq -cn '{decision:"block", reason:"README.md is the human-facing doc -- confirm a human-visible behavior actually changed before this edit, and revert if not. Agent-facing detail (hooks, gates, skills, failure modes) belongs in AGENTS.md instead."}'
