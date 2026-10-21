#!/usr/bin/env bash
# PreToolUse hook, matcher "ExitPlanMode".
# Auto-approves the "Ready to code?" plan-approval prompt so it never blocks
# on a manual keypress. Which mode the session lands in after this (auto vs
# default) is decided elsewhere (permissions.defaultMode + prePlanMode inside
# the tool itself) -- this hook only skips the "ask" gate.
#
# See is-there-any-way-jolly-micali.md plan for the binary-string evidence
# this is based on (ExitPlanMode's own permission check hardcodes {behavior:
# "ask"} for interactive sessions; a PreToolUse permissionDecision:"allow"
# preempts that check before it runs).

set -u

jq -nc '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "plan auto-approved"
  }
}'

exit 0
