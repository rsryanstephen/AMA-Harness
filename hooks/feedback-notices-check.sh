#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Surfaces the one-shot digest written by
# the daily client-feedback monitor (skills/ama-feedback-notices/scripts/
# feedback-notices-unattended-run.sh, task AMA-Harness-Feedback-Notices): tickets it created
# or a FAILED line. Shown once, then truncated -- same shape as support-notices-check.sh.
# Pure bash, one state-file read, if/else only (an exit here would kill on-prompt.sh).
#
# Sets $feedback_notices_notice (empty if nothing to say).
feedback_notices_notice=""
. "$HOME/.claude/hooks/lib-claude-paths.sh"
_fn_digest="$(hstate notices .feedback-notices-digest)"
if [ -s "$_fn_digest" ]; then
  feedback_notices_notice="Client-feedback monitor: $(tr '\n' ';' < "$_fn_digest" | sed 's/;$//'). Surface this in one line (ticket keys included), then continue with the task."
  : > "$_fn_digest"
fi
