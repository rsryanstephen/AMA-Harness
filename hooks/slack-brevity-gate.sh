#!/usr/bin/env bash
# PreToolUse hook (Slack send/draft/schedule). Enforces TWO Slack message rules:
#   1. brevity -- >120 prose words denies
#   2. address lists -- 3+ bare IP/CIDR tokens deny; each needs its own backticks
# (The filename predates rule 2; kept to avoid churning settings x2 + AGENTS.md + tests.)
#
# User instruction 2026-08-18: "for all future Slack messages, make them as few words as
# possible." Prose alone relies on self-recognition every single time, which CLAUDE.md's
# "mechanical triggers over self-recognition" rule says is unreliable -- same reasoning as
# skill-bloat-gate.sh. See memory/slack-messages-terse.md for the rule itself.
#
# Trigger: >120 words in `message`. Calibrated, not arbitrary -- the message that prompted
# the instruction ran ~250 words and its accepted rewrite was ~50, so 120 is well clear of
# a normal terse message and well under an essay. Fenced code blocks and quoted CIDR/ID
# lists are excluded from the count: pasting 12 addresses is not wordiness.
set -u

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
case "$tool" in
  *slack_send_message|*slack_send_message_draft|*slack_schedule_message) : ;;
  *) exit 0 ;;
esac

msg="$(printf '%s' "$payload" | jq -r '.tool_input.message // empty')"
[ -n "$msg" ] || exit 0

# --- rule 2: an address LIST must be backticked per item -------------------------------
# Slack renders each `...` span as its own chip, so per-item backticks give an orderly row;
# bare addresses run together as plain text. Confirmed by the user 2026-08-18 with a
# rendered screenshot of the wanted result.
#
# High precision on purpose: only 3+ BARE tokens fire, so one or two addresses mentioned in
# flowing prose are left alone, and a single inline id like sg-def080a9 is never in scope
# (the user's own edit left that un-backticked). Fenced blocks already render as a block, so
# they are stripped and exempt, as are tokens already inside inline-code spans.
nofence="$(printf '%s\n' "$msg" | awk '
  BEGIN { in_code=0 }
  /^[[:space:]]*```/ { in_code = !in_code; next }
  in_code { next }
  { print }
')"
uncoded="$(printf '%s\n' "$nofence" | sed 's/`[^`]*`/ /g')"

IPV4='[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?'
n_full="$(printf '%s\n' "$uncoded" | grep -oE "$IPV4" | grep -c . || true)"
# Abbreviated continuation form (".64/28") -- count only after removing full tokens, or the
# tail of a full CIDR would be double-counted.
n_abbr="$(printf '%s\n' "$uncoded" | sed -E "s#$IPV4# #g" \
  | grep -oE '(^|[[:space:](,])\.[0-9]{1,3}/[0-9]{1,2}' | grep -c . || true)"
bare=$(( ${n_full:-0} + ${n_abbr:-0} ))

# ONE span wrapping the whole list is the same defect wearing backticks -- Slack renders it
# as a single wide chip, not a row. Count addresses per inline span and flag the worst.
# Regex uses no {n,m} intervals so it works on mawk as well as gawk.
span_max="$(printf '%s\n' "$nofence" | grep -oE '`[^`]*`' | awk '
  { s=$0; n=0
    while (match(s, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?/)) { n++; s=substr(s, RSTART+RLENGTH) }
    t=$0; gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?/, " ", t)
    while (match(t, /\.[0-9]+\/[0-9]+/)) { n++; t=substr(t, RSTART+RLENGTH) }
    if (n > max) max = n
  }
  END { print max+0 }')"

if [ "$bare" -ge 3 ] 2>/dev/null || [ "${span_max:-0}" -ge 3 ] 2>/dev/null; then
  reported=$bare
  [ "${span_max:-0}" -gt "$reported" ] && reported=$span_max
  jq -cn --argjson n "$reported" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("This Slack message lists \($n) addresses without backticks. Standing user instruction: in a Slack message, wrap EACH address in its own backticks so Slack renders them as separate chips in an orderly row -- not one span around the whole list, not a bare run of text. Write: `20.42.35.32/28`  `.64/28`  `.80/28`   NOT: 20.42.35.32/28 .64/28 .80/28. A fenced code block is also fine and is exempt from this check, as is anything already inside inline-code spans. One or two addresses in flowing prose do not trip this. See memory/slack-messages-terse.md.")
    }
  }'
  exit 0
fi

# --- rule 1: brevity ------------------------------------------------------------------

# Prose words only. $uncoded is already fence-stripped and inline-code-stripped above --
# reuse it rather than repeating the filter, so the two rules can never disagree on what
# counts as code.
words="$(printf '%s\n' "$uncoded" | tr -s '[:space:]' '\n' | grep -c '[[:alnum:]]')"

[ "$words" -gt 120 ] 2>/dev/null || exit 0

jq -cn --argjson w "$words" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("This Slack message is \($w) prose words (limit 120). Standing user instruction: Slack messages use as few words as possible. Cut it to the ask plus only what the recipient does not already know -- drop background they have, drop how you worked it out, drop caveats that change nothing for them. Link a ticket instead of summarising it. Code blocks and inline-code spans are already excluded from this count, so the length is genuinely prose. See memory/slack-messages-terse.md.")
  }
}'
