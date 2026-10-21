#!/usr/bin/env bash
# PreToolUse hook (Edit|Write). Warn-only reminder to tier a SKILL.md's `model:` frontmatter
# per skills/resource-efficiency's "Skill-level model tiering" section -- self-recognition
# alone is unreliable (CLAUDE.md's "Mechanical Triggers Over Self-Recognition"), the same gap
# subagent-model-tiering-gate.sh already fixed for the Agent-tool `model` param.
#
# Never denies: UNTAGGED IS THE CORRECT ANSWER for most skills (anything that can fire
# mid-turn -- nudge-driven, first-reply, mid-task reference), so a deny would punish the
# right call. Same reasoning as subagent-model-tiering-gate.sh's lines 6-7.
#
# Honors SKILL_MODEL_TIERING=off. That toggle silences THIS WARNING ONLY -- it cannot
# disable a `model:` already in frontmatter (the CLI applies that, not Claude).
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
    permissionDecisionReason: ("No `model:` in " + $s + "/SKILL.md -- per resource-efficiency'"'"'s \"Skill-level model tiering\": an INLINE `model:` applies for the REST OF THE TURN, so it is only safe when the skill'"'"'s invocation IS the whole turn. Fails that if it can fire mid-task OR via a hooks/*-check.sh nudge -> leave untagged, or use `context: fork` + `model:` + `background: false`. Otherwise: mechanical -> haiku, bounded synthesis -> sonnet, judgment/high-stakes -> omit. Untagged is CORRECT for most skills -- just check, this is not a mandate.")
  }
}'
