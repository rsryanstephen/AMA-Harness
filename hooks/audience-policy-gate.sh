#!/usr/bin/env bash
# PreToolUse hook on the Gmail and Slack send/draft tools. Injects the resolved
# audience-communication policy (see memory/audience-communication-levels.md and
# hooks/lib-audience-policy.sh) as additionalContext.
#
# NON-BLOCKING BY DESIGN, and honest about what that buys. It emits
# hookSpecificOutput.additionalContext with NO permissionDecision at all:
#   - No hook can judge tone, so denying or asking on "is this too detailed" would be a gate
#     that cannot actually fail -- the shape gmail-drafting:44 already warns about.
#   - permissionDecision "allow" is deliberately NOT set either. clientcorp-cc-horia-gate.sh ASKS on
#     these same tool calls, and an explicit allow from this hook risks overriding it. Silence
#     on the decision leaves that gate's ask intact.
#
# This is the BACKSTOP, not the enforcement. By the time create_draft or slack_send_message
# fires, the message is already written, so this can only inform the revision. The load-bearing
# half is audience-policy-check.sh, which fires at UserPromptSubmit -- before anything is
# composed. This hook exists for the case the prompt never named the recipient ("reply to that
# thread", "send it on"), where layer 1 has nothing to match.
#
# Recipient rule: `to` ONLY, never cc or bcc -- explicit user decision 2026-08-20. The standing
# rule cc's one person on every mail to the client (clientcorp-cc-horia-gate.sh), so counting cc
# would make EVERY such mail a "mixed audience" and collapse it to business level, silently
# defeating the per-person rules for the person it was actually written for.
#
# Slack limitation, stated rather than papered over: slack_send_message carries only
# channel_id + message, no recipient list. A person is therefore resolvable only when
# channel_id is a DM (a U.../D... id) or the text @-mentions them. A post to a real channel
# resolves to nobody and stays silent, falling through to the general brevity rule
# slack-brevity-gate.sh already enforces.
#
# Mail limitation, same shape (confirmed live 2026-08-26): `reply`/`forward` with
# `replyAll:true` and no explicit `to` carries NO recipients in the payload at all --
# Gmail resolves them server-side. `keys` comes back empty, this hook stays silent, and
# the tone backstop is simply absent for that send. Accepted: this hook is the backstop,
# not the enforcement (see header) -- clientcorp-cc-horia-gate.sh's unresolvable-recipients
# branch is the one that actually blocks on this same shape, because it guards a
# compliance rule rather than a tone suggestion.
set -u

payload="$(cat)"

# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh) --
# a tool-name literal substring must be present.
case "$payload" in
  *create_draft*|*update_draft*|*_reply*|*forward*|*send_message*|*schedule_message*) ;;
  *) exit 0 ;;
esac

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
case "$tool" in
  mcp__*__create_draft|mcp__*__update_draft|mcp__*__reply|mcp__*__forward|mcp__*__send_message) ;;
  mcp__*__slack_send_message|mcp__*__slack_send_message_draft|mcp__*__slack_schedule_message) ;;
  *) exit 0 ;;
esac

# Match keys: the `to` list for mail, plus channel_id and any <@Uxxxx> mentions for Slack.
keys="$(printf '%s' "$payload" | jq -r '
  ((.tool_input.to // []) | flatten | .[]?),
  (.tool_input.channel_id // empty),
  ((.tool_input.message // "") | [scan("<@([A-Za-z0-9]+)")] | flatten | .[]?)
  | ascii_downcase' 2>/dev/null | tr -d '\r')"
[ -n "$keys" ] || exit 0

HERE="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib-audience-policy.sh
. "$HERE/lib-audience-policy.sh"

audience_resolve "$keys"
[ -n "${audience_policy:-}" ] || exit 0

jq -n --arg c "$audience_policy" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: ($c + " This message is already composed, so check it against the policy above before you hand it over -- and if it does not match, revise it rather than reporting it as sent. For a REPLY draft, revise by re-creating it: update_draft detaches a reply from its thread (gmail-drafting step 2c).")
  }
}'
exit 0
