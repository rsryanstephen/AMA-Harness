#!/usr/bin/env bash
# PreToolUse hook (Slack send/draft/schedule). Enforces THREE Slack message rules:
#   1. brevity -- >120 prose words denies
#   2. address lists -- 3+ bare IP/CIDR tokens deny; each needs its own backticks
#   3. self-DM -- a send/schedule to the user's own DM must contain <@user.slackUserId>
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

# --- rule 3: a DM to the user themselves must @-mention them ---------------------------
# User instruction 2026-10-16: a self-DM without <@self> raises no Slack notification, so it
# goes unseen. Send/schedule only -- a draft notifies nobody until the user sends it. Self =
# user.slackUserId (posting to a U-id opens the self-DM) or user.slackSelfDmChannelId (D-id).
case "$tool" in *_draft) ;; *)
  chan="$(printf '%s' "$payload" | jq -r '.tool_input.channel_id // empty' | tr -d '\r')"
  cfg="${HR_CONFIG_FILE:-$HOME/.claude/harness-config.json}"
  if [ -n "$chan" ] && [ -f "$cfg" ]; then
    IFS=$'\t' read -r self selfdm < <(jq -r '[(.user.slackUserId // ""), (.user.slackSelfDmChannelId // "")] | @tsv' "$cfg" 2>/dev/null | tr -d '\r')
    if [ -n "${self:-}" ] && { [ "$chan" = "$self" ] || [ "$chan" = "${selfdm:-}" ]; }; then
      case "$msg" in *"<@$self>"*) ;; *)
        jq -cn --arg s "$self" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("This is a DM to the user themselves without an @-mention, so Slack raises no notification and it goes unseen. Standing user instruction (2026-10-16): open the message with <@" + $s + "> alone on its own line, then a blank line, then the message; re-send.")}}'
        exit 0 ;;
      esac
    fi
  fi ;;
esac

# --- rule 2: an address LIST must be backticked per item -------------------------------
# Slack renders each `...` span as its own chip, so per-item backticks give an orderly row;
# bare addresses run together as plain text. Confirmed by the user 2026-08-18 with a
# rendered screenshot of the wanted result.
#
# High precision on purpose: only 3+ BARE tokens fire, so one or two addresses mentioned in
# flowing prose are left alone, and a single inline id like sg-def080a9 is never in scope
# (the user's own edit left that un-backticked). Fenced blocks already render as a block, so
# they are stripped and exempt, as are tokens already inside inline-code spans.
. "$(dirname "${BASH_SOURCE[0]}")/lib-slack-words.sh"   # shared counting, one copy
nofence="$(printf '%s\n' "$msg" | slack_nofence)"
uncoded="$(printf '%s\n' "$nofence" | slack_uncode)"

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

LIMIT_DEFAULT=120
LIMIT_STANDUP=320
LIMIT_SUPPORT=$SLACK_LIMIT_SUPPORT   # 400, lib-slack-words.sh
LIMIT_TEAM_MEETING=480

# A stand-up note is the one message type whose recipients genuinely lack the background
# this gate's own deny text tells you to drop: it goes to a group DM (Reviewer One/Reviewer Two), not just
# Your Name's self-DM, and a bare label like "WAM_HIST annotation" is unreadable without
# context. Confirmed live 2026-08-21 -- the first automated draft did exactly that.
# Per-ticket explanation cannot fit 120 words across ~17 items, so stand-ups get 250.
#
# Discriminator is the note's mandated opening line, `Updates from me:` -- the literal
# ama-standup-notes Step 6 requires (user instruction 2026-08-21: no "Stand-up <date>"
# header, no window clause). Must be a line of its OWN, so the same phrase leading into
# other prose keeps the 120 default.
#
# Scanned over the first 3 lines, not just line 1, because a configurable per-audience
# greeting sits above it ("<team>", then optionally a blank line). 3 is the whole
# allowance: greeting + blank + header. Deeper would let any long message bury the token
# and claim the ceiling.
#
# Content-shape discriminator, not a hidden flag, so a long message could claim the higher
# ceiling by carrying that line. Accepted deliberately: single-user harness, and the line
# is a real user-visible label the note needs anyway. NOT a loophole to tidy away.
# Same content-shape discriminator as the standup ceiling above, applied to the
# <amaSupportChannelName>-notices Phase 1 triage DM: a multi-mail proposal digest (verdict + ack +
# ETL message + ticket summary + diagnosis, per mail) genuinely can't fit 120 words.
# Raised 250->400 2026-10-15 (a 301-word DM was denied; the unattended run sent nothing).
# The runner now pre-checks against THIS gate and shrinks to fit -- lib-support-dm-fit.sh.
# Line 1 only, not the first 3 -- this message has no per-audience greeting above it.
#
# Third case, same pattern again: ama-team-meeting-notes' unattended Slack send opens with
# a self-mention (triggers the notification) then a blank line then this header -- first 3
# lines, same allowance shape as standup's greeting+blank+header. A week's Last+This-week
# ticket list across two sections, with occasional real per-ticket explanations, won't fit
# 120 either. LIMIT_TEAM_MEETING is a starting estimate, unverified against a real run --
# same status LIMIT_STANDUP had before 2026-08-21 showed a real overrun; expect to revisit
# it after the first live Monday send.
#
# Both raised again 2026-08-25 (250->320 standup, 400->480 team-meeting) for the new
# Client mail/Decisions blocks (both skills) and Action items' widened Zoom+Slack source
# -- still provisional, same "revisit after a real overrun" status as before.
limit=$LIMIT_DEFAULT
limit_kind=default
# Header detection skips a leading self-mention line (rule 3) + blanks, so `<@U..>` on line 1
# cannot knock a support triage DM's head -1 header off its raised ceiling.
hdr="$msg"
if printf '%s\n' "$msg" | head -1 | grep -qE '^[[:space:]]*<@[A-Z0-9]+>[[:space:]]*$'; then
  hdr="$(printf '%s\n' "$msg" | sed 1d | sed '/./,$!d')"
fi
if printf '%s\n' "$hdr" | head -3 \
   | grep -qiE '^[[:space:]]*\**[[:space:]]*Updates from me[[:space:]]*:?[[:space:]]*\**[[:space:]]*$'; then
  limit=$LIMIT_STANDUP
  limit_kind=standup
elif printf '%s\n' "$hdr" | head -1 \
   | grep -qiE '^[[:space:]]*\**[[:space:]]*Support notification triage[[:space:]]*:?[[:space:]]*\**[[:space:]]*$'; then
  limit=$LIMIT_SUPPORT
  limit_kind=support
elif printf '%s\n' "$hdr" | head -3 \
   | grep -qiE '^[[:space:]]*\**[[:space:]]*Team meeting notes[[:space:]]*\**[[:space:]]*$'; then
  limit=$LIMIT_TEAM_MEETING
  limit_kind=team_meeting
fi

# Prose words only. $uncoded is already fence-stripped and inline-code-stripped above --
# reuse it rather than repeating the filter, so the two rules can never disagree on what
# counts as code.
words="$(printf '%s\n' "$uncoded" | slack_word_count)"

[ "$words" -gt "$limit" ] 2>/dev/null || exit 0

case "$limit_kind" in
  standup)
    extra="This is the raised stand-up ceiling ($LIMIT_STANDUP vs the normal $LIMIT_DEFAULT) and it is STILL over -- group more tickets under one shared context line instead of explaining each separately, per ama-standup-notes Step 6." ;;
  support)
    extra="This is the raised support-triage ceiling ($LIMIT_SUPPORT vs the normal $LIMIT_DEFAULT) and it is STILL over -- trim each mail's block to verdict + one-line proposal, drop restated background, per <amaSupportChannelName>-notices' Output section." ;;
  team_meeting)
    extra="This is the raised team-meeting ceiling ($LIMIT_TEAM_MEETING vs the normal $LIMIT_DEFAULT) and it is STILL over -- cut explanations to the tickets that truly need them, most should carry none; a bare title is the default, per ama-team-meeting-notes Step 7." ;;
  *)
    extra="Cut it to the ask plus only what the recipient does not already know -- drop background they have, drop how you worked it out, drop caveats that change nothing for them. Link a ticket instead of summarising it." ;;
esac

jq -cn --argjson w "$words" --argjson l "$limit" --arg extra "$extra" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("This Slack message is \($w) prose words (limit \($l)). Standing user instruction: Slack messages use as few words as possible. " + $extra + " Code blocks and inline-code spans are already excluded from this count, so the length is genuinely prose. See memory/slack-messages-terse.md.")
  }
}'
