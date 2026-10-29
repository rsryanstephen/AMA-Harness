#!/usr/bin/env bash
# PreToolUse hook (Agent). Warn-only. Two nudges, one fork budget (the only Agent hook):
#
# 1. Output budget: the prompt should state an explicit word cap. The parent pays the whole
#    report into context and it stays there for the rest of the session. Measured
#    2026-09-01: unbudgeted Explore agents returned 3-5k-token reports; the same tasks with
#    "report in under 400 words" came back at ~400 and lost nothing. -> allow + reason.
#
# 2. Model opt-up (2026-10-22, user policy [[regulation-tasks-on-sonnet]]): settings.json's
#    env sets CLAUDE_CODE_SUBAGENT_MODEL=sonnet, so an omitted `model` lands on Sonnet
#    mechanically (Agent tool AND Workflow agent() -- 396/396 workflow agents ran Sonnet
#    2026-10-21/22 with no model opt in any script). Right for regulation/mechanical work.
#    Real judgment (architecture call, adversarial verify, wrong call costly) belongs on the
#    SESSION's model, not a fixed "opus" -- the session may be on fable or already dropped
#    to opus at a cap. So when `model` is omitted, this hook names the live session model
#    (last assistant message in the transcript; settings.json `.model` before the first
#    reply) as additionalContext, so the caller can pass it exactly. Judgment is Claude's;
#    the value is mechanical.
#
# NEVER denies -- a genuinely open-ended audit legitimately has no word cap, and Sonnet is
# the right default for most spawns. Honors SUBAGENT_MODEL_TIERING=off.
set -u

[ "${SUBAGENT_MODEL_TIERING:-}" = "off" ] && exit 0

payload="$(cat | tr -d '\r')"

# Cheap pure-bash prefilter before any jq fork (GATES-AND-HOOKS.md fork-budget convention).
case "$payload" in *'"prompt"'*) ;; *) exit 0 ;; esac

prompt="$(printf '%s' "$payload" | jq -r '.tool_input.prompt // empty')"
model="$(printf '%s' "$payload" | jq -r '.tool_input.model // empty')"
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"

need_budget=1
printf '%s' "$prompt" | grep -qiE \
  'under [0-9]+ ?words|[0-9]+ ?words or (fewer|less)|no more than [0-9]+ ?words|at most [0-9]+ ?words|max(imum)? [0-9]+ ?words|[0-9]+[ -]?word (cap|limit|budget|max)|word (budget|cap|limit)|output budget|≤ ?[0-9]+ ?words|<= ?[0-9]+ ?words' \
  && need_budget=0

[ "$need_budget" = 0 ] && [ -n "$model" ] && exit 0

# Live session model -> Agent `model` enum (fable|opus|sonnet|haiku). Transcript tail only:
# one line can be 200+ KB of tool result, never read the whole file in a hook.
session_model=""
if [ -z "$model" ]; then
  id=""
  [ -n "$transcript" ] && [ -f "$transcript" ] && \
    id="$(tail -c 300000 "$transcript" 2>/dev/null | grep -oE '"model":"claude-[a-z0-9.-]+"' | tail -1)"
  [ -n "$id" ] || id="$(jq -r '.model // empty' "$HOME/.claude/settings.json" 2>/dev/null)"
  case "$id" in
    *fable*)  session_model=fable ;;
    *opus*)   session_model=opus ;;
    *sonnet*) session_model=sonnet ;;
    *haiku*)  session_model=haiku ;;
  esac
fi

reason='No output budget in the prompt -- add an explicit cap (e.g. "report in under 400 words; bullets, file:line, no preamble"). You pay the whole report into context and it stays for the session; unbudgeted Explore/Plan agents routinely return 3-5k tokens. Rough defaults: lookup <=200, scoped investigation <=400, broad audit <=800. Not a mandate -- this never blocks.'

ctx=''
if [ -z "$model" ]; then
  ctx="Agent \`model\` omitted -> Sonnet (env default): right for regulation/mechanical/bounded work. Needs real judgment (architecture call, adversarial verify, wrong call costly)? Pass model:\"${session_model:-fable}\" -- this session's model -- not a fixed \"opus\". Mechanical lookup -> model:\"haiku\"."
fi

if [ "$need_budget" = 1 ]; then
  jq -cn --arg r "$reason" --arg c "$ctx" '{
    hookSpecificOutput: ({
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: $r
    } + (if $c != "" then {additionalContext: $c} else {} end))
  }'
else
  jq -cn --arg c "$ctx" '{
    hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: $c }
  }'
fi
