#!/usr/bin/env bash
# PreToolUse nudge (Edit|Write, additionalContext only, once per session per key).
# PROJ-15362: just-in-time pointers -- the reference doc for the thing being edited
# loads at the moment it's relevant instead of living in every session's context (the
# AGENTS.md-diet follow-up: guidance moved to on-demand files needs a route back in).
# Pointers only, NEVER document bodies. No permissionDecision -- an explicit allow can
# override a sibling deny gate (GATES-AND-HOOKS.md).
set -u

IFS= read -r -d '' payload || true
case "$payload" in *hooks*|*memory*|*run-hidden*|*register-hidden*|*fleet-health*|*octopus-config*) ;; *) exit 0 ;; esac

sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' | tr -d '\r')"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' | tr -d '\r' | tr '\134' '/')"
[ -n "$sid" ] && [ -n "$path" ] || exit 0

key=""; note=""
case "$path" in
  */hooks/*.sh)
    key="hooks"
    note="Editing a harness hook: GATES-AND-HOOKS.md has the authoring/wiring/testing conventions -- fork budget (needle-test before any jq), additionalContext vs permissionDecision, a rewired hook does NOT fire until restart (test by piping a payload), check-gates.sh + mutate-gates.sh after gate changes -- ALWAYS filtered, `bash scripts/check-gates.sh --gate <gate.sh>` (~10s; an unfiltered run is ~10min over 74 gates)." ;;
  */memory/*.md)
    key="memory"
    note="Editing a durable memory file: the harness-memory skill has the format/scope rules (frontmatter name/description/type, global vs cwd scope, one fact per file)." ;;
  */run-hidden*|*/register-hidden*|*/fleet-health*|*/octopus-config*)
    key="portability"
    note="Editing scheduled-task/config-sync infrastructure: PORTABILITY.md has the mechanism detail (hidden-console vbs mechanism, the three silently-skipping Task Scheduler defaults, catch-up/network traps, config-sync internals)." ;;
esac
[ -n "$key" ] || exit 0

STATED="$HOME/.claude/.session-chatfiles"
NF="$STATED/$sid.jitnudge"
grep -qx "$key" "$NF" 2>/dev/null && exit 0
mkdir -p "$STATED" 2>/dev/null
printf '%s\n' "$key" >> "$NF" 2>/dev/null

jq -cn --arg n "$note" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: ("Just-in-time pointer (once per session): " + $n)
  }
}'
