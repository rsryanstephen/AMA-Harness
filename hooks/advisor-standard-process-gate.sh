#!/usr/bin/env bash
# PreToolUse hook (advisor). Denies advisor() during a STANDARD PROCESS or a BACKLOG PICK.
#
# Why (2026-09-22, user instruction). advisor() forwards the whole transcript to a stronger
# reviewer; measured on session d846bfed it blocked the turn for 1-2 minutes while the CLI
# showed only "Advising using Opus 5" and the user, watching a session that looked hung at
# 7.5 minutes, had no way to tell work from stall. The call added nothing there: the task was
# "next backlog item", whose every step is already written down in commit-ticket and the
# ama-* skills.
#
# The rule already existed as prose -- memory/feedback-minimize-advisor-calls.md, saved
# 2026-08-25 after an advisor call mid-hotfix-deploy. Prose did not hold, because the model
# has to recognise it is mid-procedure and choose to skip. CLAUDE.md: mechanical triggers
# over self-recognition. This is the mechanical version, and the user extended it to backlog
# pickup at the same time.
#
# NO HATCH, by explicit user decision. The memory note's carve-out ("a genuine judgment call
# mid-deploy still warrants advisor") survives only where this gate does not reach -- ordinary
# debugging, investigation, design. Inside a standard process the answer is now always "follow
# the documented steps".
#
# Fails OPEN everywhere: no transcript, unreadable transcript, no jq. A missed deny costs a
# slow turn; a spurious deny costs a second opinion on work that needed one.
set -u

payload="$(cat)"

# Only this tool. Cheap, and keeps the file safe if the matcher is ever widened.
case "$payload" in *'"advisor"'*) : ;; *) exit 0 ;; esac
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')"
[ "$tool" = "advisor" ] || exit 0

tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null | tr -d '\r')"

# Breadcrumb, written BEFORE any decision. PreToolUse coverage for a non-Bash tool like
# advisor was not documented anywhere, so this file is also the evidence that it fires.
. "$HOME/.claude/hooks/lib-claude-paths.sh" 2>/dev/null && \
  printf '%s\tadvisor-gate-invoked\n' "$(date +%s)" >> "$(hstate advisor invocations.log)" 2>/dev/null

[ -n "$tr_path" ] && [ -f "$tr_path" ] || exit 0

# Standard-process skills: every step already documented, nothing for a reviewer to add.
# ama-jira-api / ama-confluence-api are deliberately ABSENT -- they are reference skills a
# judgment-heavy investigation legitimately loads mid-task.
PROC='ama-deploy-release|ama-hotfix|ama-cut-release-branch|ama-octopus-deploy|ama-release-notes|ama-standup-notes|ama-team-meeting-notes|commit-ticket|commit-ticket-jira'

# Bounded window. A standard process is many turns long, so this looks further back than the
# fan-out gate's 500 lines, but still a tail rather than the whole file.
tail_n=1200

# (1) A standard-process skill invoked recently.
proc_hit="$(tail -n "$tail_n" "$tr_path" 2>/dev/null \
  | jq -r 'select(.type=="assistant") | (.message.content // [])[]?
           | select(.type=="tool_use" and .name=="Skill") | .input.skill // empty' 2>/dev/null \
  | grep -Ex "$PROC" | tail -1)"

# (2) A backlog pick: the most recent user prompt asks for one, or backlog-candidates.sh ran.
last_prompt="$(tail -n "$tail_n" "$tr_path" 2>/dev/null \
  | jq -r 'select(.type=="user") | .message.content
           | if type=="string" then . else "" end' 2>/dev/null \
  | grep -v '^$' | tail -1)"
backlog_hit=""
case "$(printf '%s' "$last_prompt" | tr '[:upper:]' '[:lower:]')" in
  *"next backlog item"*|*"next backlog"*|*"pick up a ticket"*|*"pick up the next"*|*"next ticket"*|*"backlog item"*)
    backlog_hit="the turn's prompt asks for a backlog item" ;;
esac
if [ -z "$backlog_hit" ]; then
  # Must be an actual Bash tool_use, not any mention. A raw `grep -F backlog-candidates.sh`
  # over the transcript also matches a session that merely DISCUSSES the script -- which is
  # how this gate first denied itself, in the very session that wrote it.
  tail -n "$tail_n" "$tr_path" 2>/dev/null \
    | jq -r 'select(.type=="assistant") | (.message.content // [])[]?
             | select(.type=="tool_use" and (.name=="Bash" or .name=="PowerShell"))
             | .input.command // empty' 2>/dev/null \
    | grep -qF 'backlog-candidates.sh' \
    && backlog_hit="backlog-candidates.sh has already run this session"
fi

[ -n "$proc_hit" ] || [ -n "$backlog_hit" ] || exit 0

if [ -n "$proc_hit" ]; then
  why="the \`$proc_hit\` skill is active"
  what="Follow that skill's documented steps."
else
  why="$backlog_hit"
  what="Read the ticket and start on it; commit-ticket and the ama-* skills already carry every step."
fi

jq -cn --arg why "$why" --arg what "$what" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("advisor() is barred here: " + $why + ". Standard processes and backlog pickup are step-by-step documented in this harness, so a second opinion adds one to two minutes of blocked turn and no information -- and the CLI shows only \"Advising using Opus 5\" meanwhile, which is indistinguishable from a hang (session d846bfed, 2026-09-22). " + $what + " There is no override; if you are genuinely stuck on a judgment the skill does not resolve, say so in the reply and let the user decide.")
  }
}'
