#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Denies the 2nd+ Bash/PowerShell call in a
# genuine parallel dispatch batch -- the actual rule broken in a confirmed real
# incident: 7 Bash calls dispatched in one parallel
# batch, all under a trusted sandbox root so none needed a real permission decision
# on their own merits, but the batch itself got interrupted/cancelled by the user
# before most of them even finished resolving (visible in sandbox-allow.log: only 1
# of 7 logged a completed verdict). CLAUDE.md and the bash-command-style skill
# already say not to do this ("prove a form works on one call first, then
# parallelize") -- prose alone didn't stop it, this is the mechanical version, same
# pattern as the other gate hooks in this repo.
#
# DETERMINISTIC, not timing-based -- a first attempt at this used a same-prompt_id +
# elapsed-time heuristic (deny anything landing within 2s of the prior call). That
# was tested against this machine's real sandbox-allow.log and rejected: 1267 of
# 5782 consecutive same-prompt_id call pairs in real usage landed within 2 seconds,
# and those are ordinary fast SEQUENTIAL calls (quick reasoning between them), not
# parallel batches -- the threshold would have denied a huge fraction of legitimate
# work. The actual, exact signal for "these were dispatched together" is structural,
# not timing: Claude Code logs one transcript line per tool_use content block (even
# when several come from one parallel dispatch), but a genuine parallel batch logs
# ALL of its tool_use lines back-to-back with NO tool_result line between them --
# confirmed by inspecting this session's own transcript, where a real 7-call batch
# shows as "AAAAAAA" (7 tool_use entries) followed later by "RRRRRRR" (7 results),
# while ordinary sequential work always shows single tool_use/tool_result pairs. So:
# walk back from THIS call to the last tool_result boundary; if 2+ Bash/PowerShell
# tool_use entries fall in that uninterrupted run and this isn't the first one,
# it's fan-out.
#
# Only gates Bash/PowerShell -- NOT Agent, which this harness elsewhere explicitly
# encourages dispatching in parallel (independent subagents, no shared shell state,
# no persisted-cwd leak risk, no stacked interactive permission prompts).
set -u

IFS= read -r -d '' payload || true
# Single jq for all four fields instead of four (was 5 forks before the first bail;
# ~60ms/fork on this machine). `// ""` not `// empty` so a missing field still emits
# its line and the positional reads stay aligned. jq.exe emits CRLF and `read` (unlike
# `$(...)`) does NOT strip the \r -- and tr_path is used as a file path below, where a
# stray \r breaks the -f test -- so strip it from each explicitly.
sid=""; tr_path=""; tool_use_id=""; permission_mode=""
{ IFS= read -r sid; IFS= read -r tr_path; IFS= read -r tool_use_id; IFS= read -r permission_mode; } \
  < <(printf '%s' "$payload" | jq -r '.session_id // "", (.transcript_path // ""), (.tool_use_id // ""), (.permission_mode // "")' 2>/dev/null)
sid="${sid%$'\r'}"; tr_path="${tr_path%$'\r'}"; tool_use_id="${tool_use_id%$'\r'}"; permission_mode="${permission_mode%$'\r'}"

[ -n "$sid" ] || exit 0
[ -n "$tr_path" ] && [ -f "$tr_path" ] || exit 0
[ -n "$tool_use_id" ] || exit 0
# plan/auto modes don't surface the stacked-interactive-prompt failure mode this
# targets -- plan mode blocks real actions outright, auto mode has no per-call prompt
# to stack in the first place.
[ "$permission_mode" = "default" ] || exit 0

# Bounded recent window -- generous (500 transcript lines) relative to any real
# parallel batch size, cheap to scan every call.
result="$(tail -n 500 "$tr_path" 2>/dev/null | jq -c '
    if .type=="assistant" then
      ((.message.content // []) | map(select(.type=="tool_use")))[]?
      | {kind:"tooluse", name:.name, id:.id}
    elif .type=="user" and (.message.content|type)=="array" then
      (.message.content[]? | select(.type=="tool_result")) | {kind:"result"}
    else empty end
  ' 2>/dev/null | jq -s --arg id "$tool_use_id" '
    (map(.kind) | rindex("result")) as $ri
    | (if $ri == null then . else .[($ri + 1):] end) as $run
    | ($run | map(select(.kind=="tooluse" and (.name=="Bash" or .name=="PowerShell")))) as $calls
    | {count: ($calls | length), index: ($calls | map(.id) | index($id))}
  ' 2>/dev/null)"
[ -n "$result" ] || exit 0

# Same single-jq + CR-strip idiom as the payload read above.
count=""; index=""
{ IFS= read -r count; IFS= read -r index; } < <(printf '%s' "$result" | jq -r '(.count // ""), (.index // "")' 2>/dev/null)
count="${count%$'\r'}"; index="${index%$'\r'}"
[ -n "$count" ] && [ -n "$index" ] || exit 0
[ "$count" -ge 2 ] || exit 0
[ "$index" != "0" ] || exit 0

jq -cn --arg n "$count" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("This is one of " + $n + " Bash/PowerShell calls dispatched together in the same parallel batch (detected from the transcript: consecutive tool_use entries with no tool_result between them) -- one denial/interruption rejects the WHOLE batch, losing the useful calls along with the bad one. Per the bash-command-style skill: prove a form works on ONE call first, then parallelize -- or if these are genuinely independent, dispatch them as separate Agent calls instead (Agent fan-out is fine, has no shared shell/cwd state and no stacked interactive prompts). Only the first call in this batch is allowed through; let it fully resolve, then issue the next one.")
  }
}'
