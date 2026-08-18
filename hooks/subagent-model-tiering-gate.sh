#!/usr/bin/env bash
# PreToolUse hook (Agent). Warn-only reminder to tier the `model` param per
# skills/resource-efficiency's easy->haiku / medium->sonnet / hard->omit mapping --
# self-recognition-only was confirmed unreliable (CLAUDE.md's "Mechanical Triggers
# Over Self-Recognition"), same gap library-version-sync-reminder.sh already fixed for
# a different rule. Never denies: omitting `model` is the CORRECT choice for
# hard/high-stakes work per that mapping, so a deny here would punish the right call.
# Honors SUBAGENT_MODEL_TIERING=off (the documented escape hatch) by staying silent.
set -u

[ "${SUBAGENT_MODEL_TIERING:-}" = "off" ] && exit 0

payload="$(cat)"
model="$(printf '%s' "$payload" | jq -r '.tool_input.model // empty')"

[ -z "$model" ] || exit 0

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "No model set on this Agent call -- per resource-efficiency: easy/mechanical work -> model:\"haiku\", bounded/moderate synthesis -> model:\"sonnet\", hard/high-stakes/ambiguous -> omit (inherit parent), which is likely already the right call here. Not a mandate, just check before spawning."
  }
}'
