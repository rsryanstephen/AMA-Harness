#!/usr/bin/env bash
# Shared Slack prose-word counting -- ONE copy, sourced by slack-brevity-gate.sh and by
# skills/<amaSupportChannelName>-notices/scripts/lib-support-dm-fit.sh, so a runner's pre-send count can
# never disagree with the gate that will judge the send.
#
# Fenced code blocks and inline-code spans are excluded: pasting data is not wordiness.

# Support-triage DM ceiling (raised 250->400 2026-10-15: a 301-word triage DM was denied and
# the unattended monitor sent nothing). The runner reads this, never a hardcoded number.
SLACK_LIMIT_SUPPORT=400

slack_nofence() {  # stdin -> stdout, fenced blocks removed
  awk '
    BEGIN { in_code=0 }
    /^[[:space:]]*```/ { in_code = !in_code; next }
    in_code { next }
    { print }
  '
}

slack_uncode() {  # stdin -> stdout, inline-code spans blanked
  sed 's/`[^`]*`/ /g'
}

slack_word_count() {  # stdin (already fence/code stripped) -> prose word count
  tr -s '[:space:]' '\n' | grep -c '[[:alnum:]]'
}

slack_prose_words() {  # $1 = full message text -> prose word count, as the gate counts it
  printf '%s\n' "$1" | slack_nofence | slack_uncode | slack_word_count
}
