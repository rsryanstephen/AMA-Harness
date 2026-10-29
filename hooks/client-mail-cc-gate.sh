#!/usr/bin/env bash
# PreToolUse hook (Gmail create_draft/update_draft/reply/forward/send). Every mail to an
# ClientCorp recipient must copy <emailRecipients>.
#
# User instruction 2026-08-20: "each new mail to anyone in ClientCorp needs to also copy ContactOne
# in", confirmed as a harness rule. Prose alone would rely on self-recognition on every
# draft, which CLAUDE.md's "mechanical triggers over self-recognition" rule calls
# unreliable -- and this session is itself the evidence: the sig rule in gmail-drafting was
# read and then violated three times in a row. Same reasoning as slack-brevity-gate.sh.
# See memory/clientcorp-cc-contactone.md for the rule itself.
#
# ASKS rather than denies (user's choice 2026-08-20): a deliberate exception stays possible
# with one approval, where a hard deny would need the hook edited. The prompt names the
# address so approving is a real decision, not a reflex.
#
# SELF-ADDRESS EXEMPTION (user's choice 2026-08-20): the user's own alternate address
# <secondaryEmail> is an <one entry per line; this element only declares the type> address, so a literal domain test would fire on
# every note-to-self -- including the signature test drafts this very rule was built
# alongside. A mail whose ONLY <one entry per line; this element only declares the type> recipient is that address is self-mail and passes.
# A mail to a real colleague still fires even when your.windows.username2 is also copied.
#
# UNRESOLVABLE-RECIPIENTS BRANCH (added 2026-08-26, confirmed live): `reply`/`forward` only
# require `messageId` -- a `replyAll:true` reply carries NO addresses in the payload at
# all, Gmail resolves them server-side. That broke BOTH guards above: the raw-payload
# prefilter finds no "<one entry per line; this element only declares the type>" substring to trigger on, and even if it did, `rcpts` would
# still come back empty from a payload with no to/cc/bcc. Confirmed: a real reply-all to an
# ClientCorp thread passed this gate silently. Fix is NOT trying to resolve the real recipient
# set (would need a live Gmail thread-participants lookup this hook doesn't have) --
# instead, when a reply/forward's recipients are structurally unknowable from the payload,
# ask unconditionally. Costs an extra prompt on a reply/forward to a purely-internal
# thread; the alternative is silently mailing ClientCorp with no cc, which already happened once.
set -u

payload="$(cat)"

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
case "$tool" in
  mcp__*__create_draft|mcp__*__update_draft|mcp__*__reply|mcp__*__forward|mcp__*__send_message) ;;
  *) exit 0 ;;
esac

# reply/forward with no explicit `to` (and no `cc`/`bcc` either) means the real recipient
# set is resolved server-side from the thread -- this payload cannot tell ClientCorp from
# not-ClientCorp. Ask rather than silently pass. create_draft/update_draft/send_message always
# carry explicit recipients in the sanctioned gmail-drafting flow, so this branch is
# defense-in-depth there, not the expected path.
case "$tool" in
  mcp__*__reply|mcp__*__forward)
    has_to="$(printf '%s' "$payload" | jq -r '(.tool_input.to // []) | length')"
    has_cc="$(printf '%s' "$payload" | jq -r '(.tool_input.cc // []) | length')"
    has_bcc="$(printf '%s' "$payload" | jq -r '(.tool_input.bcc // []) | length')"
    if [ "${has_to:-0}" = "0" ] && [ "${has_cc:-0}" = "0" ] && [ "${has_bcc:-0}" = "0" ]; then
      jq -n '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "ask",
          permissionDecisionReason: "This reply/forward has no explicit to/cc/bcc -- Gmail resolves the real recipients server-side (e.g. replyAll:true), so this hook cannot tell whether an ClientCorp address is among them, and therefore cannot check the standing <emailRecipients> cc rule. If the thread involves ClientCorp, pass to/cc explicitly (with ContactOne included) instead of relying on replyAll, or use create_draft so the draft can be reviewed before sending. Approve only if you have confirmed this thread has no ClientCorp recipient."
        }
      }'
      exit 0
    fi
    ;;
esac

# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh)
# -- no <one entry per line; this element only declares the type> anywhere means nothing to check. Case-insensitive: addresses arrive in
# mixed case ("<emailRecipients>", "<one entry per line; this element only declares the type>"). Only reached
# once recipients are known to be explicit (the branch above already handled the
# unresolvable case), so this is safe again as a cheap filter. Literal QUOTED: the public
# mirror's scrub swaps it for a `<...>` placeholder, which is shell syntax unquoted.
case "$(printf '%s' "$payload" | tr 'A-Z' 'a-z')" in *'<one entry per line; this element only declares the type>'*) ;; *) exit 0 ;; esac

# Every recipient field, lowercased, one per line. bcc counts: a bcc'd ClientCorp colleague is
# still an ClientCorp recipient.
rcpts="$(printf '%s' "$payload" | jq -r '
  [ (.tool_input.to // []), (.tool_input.cc // []), (.tool_input.bcc // []) ]
  | flatten | .[] | ascii_downcase')"
[ -n "$rcpts" ] || exit 0

# ClientCorp recipients other than the user's own alternate address -- read from config, not
# hardcoded: a regex-escaped copy here dodged the public mirror's literal scrub (2026-10-28).
own2="$(jq -r '.user.secondaryEmail // empty' "$HOME/.claude/harness-config.json" 2>/dev/null | tr -d '\r' | tr 'A-Z' 'a-z')"
others="$(printf '%s\n' "$rcpts" | grep '@clientcorp\.com' | grep -vxF "$own2" || true)"
[ -n "$others" ] || exit 0

# ContactOne present anywhere in to/cc/bcc satisfies the rule.
case "$rcpts" in *'contact.one@client.example.com'*) exit 0 ;; esac

jq -n --arg who "$(printf '%s\n' "$others" | paste -sd', ' -)" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: ("This mail goes to ClientCorp (" + $who + ") but does not copy <emailRecipients>. Standing user rule from 2026-08-20: every mail to anyone at ClientCorp copies ContactOne in. Add <emailRecipients> to `cc` and call the tool again. Approve this call only if the user has said THIS mail is a deliberate exception. (Mailing the user'"'"'s own <secondaryEmail> is exempt and never reaches this prompt.)")
  }
}'
