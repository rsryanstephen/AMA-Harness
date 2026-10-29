#!/usr/bin/env bash
# PreToolUse gate (Jira comment MCP tool + Bash/PowerShell running jira-add-comment.sh + the
# Write that PRODUCES that script's payload). Two tiers on a Jira comment about regressions:
#
#   chars > 1200 or steps > 10 -> DENY  (plain rule violation; model trims, no user prompt)
#   chars >  800 or steps >  6 -> ASK   (grey band; the length might be deliberate)
#
# Rule (memory/ready-to-test-regression-comment.md, 2026-08-26): a regression comment is for the
# UI tester -- max 5 one-line steps, no narrative. PROJ-15312 got an 1800-char essay the day
# the rule was written down, so prose alone did not hold; same reasoning as slack-brevity-gate.sh.
#
# Why two tiers (2026-09-04). The gate asked at 800 for a week and every single firing was 1.7x
# the limit or worse -- 1337, 1409, 1678, 3592 chars; two of them 0 step lines, i.e. pure
# narrative. One session was asked three times and the comment GREW each time (1409 -> 1678 ->
# 3592): an ask hands a plain rule violation to the user to clear instead of to the model to fix.
# Nothing has ever landed in 800-1200, so the ask is kept only there, where "this one genuinely
# needs the length" is still a plausible human call. No other hook does soft-ask/hard-deny on one
# metric (gmail-draft-sig-gate.sh is the nearest two-branch shape); this is a deliberate departure
# from mongo-write-gate.sh:14's "deny-plus-hatch over ask", justified by that recorded data.
#
# Ticket status and working-tree diff are NOT usable signals here, checked 2026-09-15 and
# recorded so this is not proposed a fourth time. A plain status comment on an In Progress
# ticket (PROJ-14778) asked, and the obvious narrowings both fail:
#   - STATUS: a real regression comment is posted BEFORE the Ready-to-Test transition, so the
#     ticket still reads In Progress at comment time. Suppressing there kills the gate on
#     exactly the comments it exists for. (The sibling REMINDER can use jira_status because it
#     is post-tool and fires on the transition itself, where the status has already moved.)
#   - DIFF: by comment time the change is committed and pushed, so the tree is clean for a
#     genuine regression comment too.
# Both of those cases ASK, never deny, so the cost of the remaining false positives is one
# approval, not a blocked write. Left as-is by user decision.
#
# Script path: jira-add-comment.sh reads its text from the fixed payload file (written by the
# Write tool BEFORE the Bash call, so PreToolUse can read it). Missing/unreadable -> silent;
# ready-to-test-regression-reminder.sh handles the missing-payload nudge post-tool. The Write
# branch catches it one step earlier still, with the text in hand -- Write ONLY, never Edit: an
# Edit carries a fragment, so a char count on it is meaningless, and an edited payload is still
# caught at the Bash call.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"

IFS= read -r -d '' payload || true
case "$payload" in
  *addCommentToJiraIssue*|*jira-add-comment*|*jira-write-payload*) ;;
  *) exit 0 ;;
esac

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
body=""
case "$tool" in
  mcp__*__addCommentToJiraIssue)
    body="$(printf '%s' "$payload" | jq -r '.tool_input.commentBody // .tool_input.body // empty')"
    ;;
  Bash|PowerShell)
    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
    # Invocation only, never the filename mentioned in a read (same regex as the reminder).
    printf '%s' "$command" | grep -qE '(^|[;&|(] *)([A-Z_]+=[^[:space:]]+ +)*(bash +)?"?[^" ]*jira-add-comment\.sh"? +[A-Z]' || exit 0
    PF="$(jira_payload_file "$command")"
    [ -f "$PF" ] && body="$(jq -r '.body // empty' < "$PF" 2>/dev/null || true)"
    ;;
  Write)
    # jira_payload_file() parses a COMMAND line, so it cannot be reused here -- match the path
    # shape instead (same normalisation as native-memory-gate.sh). Covers both the shared default
    # and the per-call JIRA_PAYLOAD_FILE=...-<suffix>.json form.
    fp="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
    [ -n "$fp" ] || exit 0
    case "$(printf '%s' "$fp" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')" in
      */.jira-write-payload*.json) : ;;
      *) exit 0 ;;
    esac
    body="$(printf '%s' "$payload" | jq -r '.tool_input.content // empty' \
      | jq -r '.body // empty' 2>/dev/null || true)"
    ;;
esac
[ -n "$body" ] || exit 0
# The NOUN, word-anchored -- not any `regress*` substring. A bare substring match also caught
# the VERB: an implementation-outcome comment saying a later deploy must not "regress" a config
# fix was measured against the regression-comment budget and denied at 2273 chars (hit
# 2026-09-09 on PROJ-15378). Every shape this rule actually governs uses the noun
# ("Regression: checked a, b", "no regressions found"), so requiring it loses no coverage.
# ready-to-test-regression-reminder.sh deliberately keeps the broader substring for its
# self-suppression: there, over-matching means one fewer nudge, not a wrongful denial.
printf '%s' "$body" | grep -qiE '\bregressions?\b' || exit 0

chars=${#body}
steps="$(printf '%s\n' "$body" | grep -cE '^[[:space:]]*([-*]|[0-9]+[.)])' || true)"
steps=${steps:-0}

# The rule's own remedy for a NON-UI-testable ticket is one "Regression: checked a, b; nothing
# found" line INSIDE the testing-steps comment. That body legitimately mentions regression and
# is legitimately long, so measuring it against the standalone-regression-comment budget denied
# exactly what the rule asks for (hit 2026-09-08 on PROJ-15376, a 2253-char testing-steps
# comment carrying the prescribed one-liner). Exempt that shape only: a SINGLE line-anchored
# "Regression:" sentence that is a small part of a larger comment.
# A standalone regression comment still gets measured -- it either has step lines and no
# "^Regression:" anchor, or one long "Regression:" line that fails the length check below.
reg_lines="$(printf '%s\n' "$body" | grep -cE '^[[:space:]]*Regression:' || true)"
reg_lines=${reg_lines:-0}
if [ "$reg_lines" = "1" ]; then
  reg_len="$(printf '%s\n' "$body" | grep -E '^[[:space:]]*Regression:' | head -1 | wc -c | tr -d ' ')"
  if [ "${reg_len:-0}" -le 400 ] && [ "$chars" -gt $((reg_len * 2)) ]; then
    exit 0
  fi
fi

if [ "$chars" -gt 1200 ] || [ "$steps" -gt 10 ]; then
  decision="deny"
elif [ "$chars" -gt 800 ] || [ "$steps" -gt 6 ]; then
  decision="ask"
else
  exit 0
fi

rule="Rule: max 5 one-line steps ('open X, confirm Y still works'), ~800 chars, no narrative -- and only if the UI tester can run it from the UI; otherwise one 'Regression: checked a, b; nothing found' line in the testing-steps comment instead."
if [ "$decision" = "deny" ]; then
  tail_msg="That is past the 1200-char / 10-step hard limit, too far over to be a deliberate exception, so trim it yourself rather than asking: cut to 5 one-line steps or fewer, or drop the separate comment entirely and put one 'Regression: checked a, b; nothing found' line in the testing-steps comment. Rewrite the payload and retry."
else
  tail_msg="Trim it, or approve if this one genuinely needs the length."
fi
reason="Regression comment is ${chars} chars / ${steps} step lines. ${rule} ${tail_msg} memory/ready-to-test-regression-comment.md."

jq -cn --arg d "$decision" --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
