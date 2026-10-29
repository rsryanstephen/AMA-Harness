#!/usr/bin/env bash
# PreToolUse hook (Edit|Write). Warn-only reminder to tier a SKILL.md's `model:` frontmatter
# per skills/resource-efficiency's "Skill-level model tiering" section -- self-recognition
# alone is unreliable (CLAUDE.md's "Mechanical Triggers Over Self-Recognition"), the same gap
# subagent-model-tiering-gate.sh already fixed for the Agent-tool `model` param.
#
# What the tag does (probe-proven 2026-10-22, CLI 2.1.308, 2 trials each): `model:` engages
# ONLY when the USER slash-invokes the skill (`/skill args` -> that whole turn runs on the
# tag); a Skill-tool invocation by Claude IGNORES it. So a tag means "when the user runs
# this by hand, run it on X". Regulation runbooks (deploy, monitor, sync, log check) ->
# `model: sonnet` (user policy 2026-10-22, memory regulation-tasks-on-sonnet); reasoning
# skills -> omit; first-reply/mid-task reference skills -> never slash-run, tag irrelevant.
# `context: fork` + `model:` is the only lever that works for Claude-initiated invocation.
#
# Never denies: untagged is right for every reasoning skill. Honors SKILL_MODEL_TIERING=off
# (silences THIS WARNING ONLY -- it cannot disable a `model:` already in frontmatter).
set -u

[ "${SKILL_MODEL_TIERING:-}" = "off" ] && exit 0

payload="$(cat | tr -d '\r')"

path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[ -n "$path" ] || exit 0

# only skills/<name>/SKILL.md
case "$path" in
  */skills/*/SKILL.md) ;;
  *) exit 0 ;;
esac

# Write: judge the content being written. Edit: judge the file already on disk.
content="$(printf '%s' "$payload" | jq -r '.tool_input.content // empty')"
if [ -n "$content" ]; then
  frontmatter="$(printf '%s\n' "$content" | sed -n '1,20p')"
else
  [ -f "$path" ] || exit 0
  frontmatter="$(sed -n '1,20p' "$path" 2>/dev/null | tr -d '\r')"
fi

# already tiered (or explicitly inheriting) -> silent
printf '%s\n' "$frontmatter" | grep -q '^model:' && exit 0

skill="$(basename "$(dirname "$path")")"

jq -cn --arg s "$skill" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: ("No `model:` in " + $s + "/SKILL.md. A frontmatter `model:` engages ONLY when the user slash-invokes the skill (whole turn on that model); Skill-tool invocation ignores it (probe 2026-10-22, CLI 2.1.308). Regulation runbook the user runs by hand (deploy, monitor, sync, log check, env wake) -> `model: sonnet` per memory regulation-tasks-on-sonnet. Reasoning skill, or never slash-run (first-reply, mid-task reference, nudge-driven) -> leave untagged. Claude-initiated cheap execution needs `context: fork` + `model:` + `background: false` instead. Not a mandate -- this never blocks.")
  }
}'
