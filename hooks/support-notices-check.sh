#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Nudges Claude to run the
# <amaSupportChannelName>-notices skill.
#
# This is the SECONDARY scheduler -- the PRIMARY is the hourly scheduled task
# (AMA-Harness-Support-Notices-Ping -> support-notices-unattended-run.sh), because
# Gmail is MCP-only and the cadence is data-driven (hourly on a monthly-file processing
# day), which no cron expression alone can express. This nudge exists for the same gap
# every sibling monitor has: no-session-for-a-while, plus surfacing that runner's
# one-shot digest and any `pending` rows so an unanswered exception can't be forgotten.
#
# Pure bash, no network, a couple of tiny state-file reads -- on-prompt.sh runs on
# EVERY prompt and is fork-cost/timeout sensitive.
#
# Uses if/else, NOT <one entry per line; this element only declares the type>'s `return 0 2>/dev/null || exit 0` -- if that exit branch is
# ever reached while sourced, on-prompt.sh dies before its final jq emit and the whole
# turn's injected context is silently lost. Copied from aws-notices-check.sh's shape.
#
# Sets $support_notices_notice (empty if nothing to say).
support_notices_notice=""
. "$HOME/.claude/hooks/lib-claude-paths.sh"
DIGEST_FILE="$(hstate notices .support-notices-digest)"
SEEN_FILE="$(hstate notices .support-notices-seen)"

# One-shot digest wins -- it carries actual findings (or failures) from the hourly runner.
if [ -s "$DIGEST_FILE" ]; then
  support_notices_notice="Support notification monitor: $(cat "$DIGEST_FILE") Surface this distinctly, then continue with the task."
  : > "$DIGEST_FILE"
else
  # Pending rows -- unanswered exceptions -- surfaced regardless of digest state, so
  # they can't be forgotten just because no new mail arrived since. Throttled to once
  # per calendar day, same shape as the other nudges' staleness throttle.
  if [ -s "$SEEN_FILE" ]; then
    pending_count="$(awk -F'\t' '$4=="pending"' "$SEEN_FILE" | wc -l | tr -d ' ')"
    if [ "${pending_count:-0}" -gt 0 ]; then
      today="$(date +%F)"
      PENDING_NUDGED="$(hstate notices .support-notices-pending-nudged)"
      last_nudge="$(cat "$PENDING_NUDGED" 2>/dev/null || true)"
      if [ "$last_nudge" != "$today" ]; then
        support_notices_notice="Support notification monitor has $pending_count pending row(s) awaiting an answer -- run <amaSupportChannelName>-notices to settle them."
        printf '%s\n' "$today" > "$PENDING_NUDGED"
      fi
    fi
  fi
fi
