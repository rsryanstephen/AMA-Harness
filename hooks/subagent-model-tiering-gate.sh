#!/usr/bin/env bash
# PreToolUse hook (Agent). Warn-only. One check: the prompt should state an explicit word
# cap. The parent pays the whole report into context and it stays there for the rest of the
# session. Measured 2026-09-01: unbudgeted Explore agents returned 3-5k-token reports; the
# same tasks with "report in under 400 words" came back at ~400 and lost nothing.
#
# Model tiering is NOT checked here any more (2026-09-14). settings.json's env sets
# CLAUDE_CODE_SUBAGENT_MODEL=sonnet, so an omitted `model` lands on Sonnet mechanically --
# transcripts showed the old nudge honored ~1/3 of the time (118 Explore + 25 general-purpose
# spawns inherited Fable in 3 weeks). Opt UP with model:"opus" only when a spawn needs real
# judgment; opt down with model:"haiku" for mechanical work. See resource-efficiency.
#
# NEVER denies -- a genuinely open-ended audit legitimately has no word cap.
# Honors SUBAGENT_MODEL_TIERING=off (kept for the toggle's existing callers).
set -u

[ "${SUBAGENT_MODEL_TIERING:-}" = "off" ] && exit 0

payload="$(cat | tr -d '\r')"

# Cheap pure-bash prefilter before any jq fork (GATES-AND-HOOKS.md fork-budget convention).
case "$payload" in *'"prompt"'*) ;; *) exit 0 ;; esac

prompt="$(printf '%s' "$payload" | jq -r '.tool_input.prompt // empty')"

printf '%s' "$prompt" | grep -qiE \
  'under [0-9]+ ?words|[0-9]+ ?words or (fewer|less)|no more than [0-9]+ ?words|at most [0-9]+ ?words|max(imum)? [0-9]+ ?words|[0-9]+[ -]?word (cap|limit|budget|max)|word (budget|cap|limit)|output budget|≤ ?[0-9]+ ?words|<= ?[0-9]+ ?words' \
  && exit 0

reason='No output budget in the prompt -- add an explicit cap (e.g. "report in under 400 words; bullets, file:line, no preamble"). You pay the whole report into context and it stays for the session; unbudgeted Explore/Plan agents routinely return 3-5k tokens. Rough defaults: lookup <=200, scoped investigation <=400, broad audit <=800. Not a mandate -- this never blocks.'

jq -cn --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: $r
  }
}'
