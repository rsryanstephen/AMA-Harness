#!/usr/bin/env bash
# PreToolUse hook (mcp__*__create_draft, mcp__*__update_draft, mcp__*__reply,
# mcp__*__forward). Two signature invariants on an outgoing Gmail draft/send.
#
# WIDENED to reply/forward 2026-08-26: both are direct-send API calls with no Gmail
# compose-UI auto-sig, same as create_draft -- so the same two defects apply. Confirmed
# live: a `reply` call sent to ClientCorp with no signature at all passed this gate silently,
# because the matcher only covered (create|update)_draft.
#
# reply's `body`/`htmlBody` fields match create_draft's naming exactly, so the typo-deny
# and sig-presence checks below apply unchanged. forward has no `body` -- its own added
# text is `forwardText`, and the typo-deny checks that field instead; forward gets no
# sig-presence check, since forwardText is commentary prepended to someone else's
# message, not a new message that owes a full closing signature.
#
# DENY -- body or htmlBody spells the company `SturctureIt`.
# The stored Gmail signature spells it correctly (user-confirmed 2026-08-20). The typo
# survives only in OLDER sent mail, so a draft carrying it proves gmail-drafting step 2b
# lifted its sig from a stale message. Confirmed live: 3 of 3 drafts created right after
# commit ce367ef carried `SturctureIt`, including one whose HTML markup was otherwise
# perfect -- the formatting fix worked and the sourcing still regressed, which is exactly
# the pair a reviewer eyeballing a rendered draft is most likely to wave through.
# `YourCompany` is never legitimately spelled this way, so the deny has no false-positive
# case and needs no allowlist.
#
# WARN -- create_draft whose htmlBody has no `class="gmail_signature"`.
# API drafts get no Gmail auto-sig, so an unsigned body is nearly always an oversight.
# Scoped to create_draft ONLY: an update_draft patching a subject or recipient carries no
# sig by design, and a gate that fires on ordinary operations trains itself away -- the
# failure mode gmail-reply-thread-reminder.sh:29-33 already documents avoiding.
#
# Anchor is `class="gmail_signature"`, NOT `data-smartmail`. The attribute is present on
# SENT messages but Gmail strips it when saving a draft (all 3 drafts above lacked it), so
# keying either check on it would false-negative every single time.
#
# PreToolUse is the only workable placement: the htmlBody is visible in the tool_input
# here, BEFORE the draft exists. Nothing downstream can un-send a bad sig.
#
# Why the typo deny does NOT false-positive on replies: it inspects the tool_input, which
# on a reply carries ONLY our own new text -- Gmail appends the quoted chain afterwards,
# server-side. The chain routinely contains `SturctureIt` from genuinely-sent older mail,
# so a check run against the STORED htmlBody instead would deny every reply on an old
# thread. Verified live 2026-08-20: creating a corrected reply on thread 1a0004ef44cd6154
# passed this gate, and the draft Gmail then stored held 3 historical `SturctureIt` in its
# quote. Known edge: a payload that deliberately embeds quoted history (a hand-built
# forward) would trip the deny. Accepted -- rare, and the reason text says to re-source
# rather than edit, which is still the right move. Do NOT "fix" it by matching only near
# the sig anchor; that reintroduces the false-pass this gate exists to stop.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload substring pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- ~60ms/fork on this machine.
case "$payload" in *create_draft*|*update_draft*|*_reply*|*forward*) ;; *) exit 0 ;; esac

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
case "$tool" in
  mcp__*__create_draft|mcp__*__update_draft|mcp__*__reply|mcp__*__forward) ;;
  *) exit 0 ;;
esac

# Both bodies matter: `body` is the plain-text alternative and ships in the same message.
# forward has no `body` -- its own added text is `forwardText`.
case "$tool" in
  mcp__*__forward)
    bodies="$(printf '%s' "$payload" | jq -r '[.tool_input.forwardText // "", .tool_input.htmlBody // ""] | join("\n")')"
    ;;
  *)
    bodies="$(printf '%s' "$payload" | jq -r '[.tool_input.body // "", .tool_input.htmlBody // ""] | join("\n")')"
    ;;
esac

case "$bodies" in
  *SturctureIt*)
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Draft body spells the company `SturctureIt` -- always `YourCompany`. This is not a typo to patch in place: the stored Gmail signature is CORRECT, so a sig carrying this spelling was lifted from a STALE sent message, and the rest of that block is probably stale too. Re-source it per gmail-drafting step 2b: search_threads `in:sent newer_than:30d`, take the genuinely NEWEST by date (do NOT filter by `smaller:` -- that biases toward old short messages, which is what caused this), get_message FULL_CONTENT, and extract the `<div class=\"gmail_signature\">` block appearing BEFORE any `gmail_quote`. Confirm the extracted block spells `YourCompany` before using it; if it does not, take the next-newest message rather than editing the string."
      }
    }'
    exit 0
    ;;
esac

case "$tool" in
  mcp__*__create_draft|mcp__*__reply)
    html="$(printf '%s' "$payload" | jq -r '.tool_input.htmlBody // ""')"
    case "$html" in
      *'class="gmail_signature"'*) ;;
      *)
        jq -n --arg tool "$tool" '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "ask",
            permissionDecisionReason: ($tool + " htmlBody carries no `class=\"gmail_signature\"` block. API sends get NO Gmail auto-sig, so this one will arrive unsigned -- or signed in the client default font if a plain-text sig was pasted into htmlBody, which is the exact defect gmail-drafting step 2b exists to prevent. Add the real signature: search_threads `in:sent newer_than:30d` -> newest -> get_message FULL_CONTENT -> copy the `<div class=\"gmail_signature\">` div VERBATIM into htmlBody (leave the body text itself unstyled; Gmail applies the account default client-side). Genuinely want an unsigned send -> approve this call.")
          }
        }'
        exit 0
        ;;
    esac
    ;;
esac

exit 0
