#!/usr/bin/env bash
# Sourced from on-prompt.sh (UserPromptSubmit). Sets $audience_notice when THIS prompt looks
# like a request to write to somebody the audiences config knows about, so the resolved
# communication policy lands in context BEFORE anything is composed.
#
# Same sourced-nudge shape as followup-check.sh / embs-coverage-check.sh: sets one variable,
# never writes to stdout (stdout from this hook is the additionalContext JSON on-prompt.sh
# emits, so a stray echo here corrupts it).
#
# Why prompt time and not just the PreToolUse gate: by the time create_draft or
# slack_send_message fires, the message is already written. A PreToolUse hook can only inform
# the revision. This is the one point where guidance can still shape the first draft, which is
# why this is the load-bearing half and audience-policy-gate.sh is the backstop.
#
# Two-stage filter, deliberately. Stage 1 asks whether the prompt is about WRITING to someone;
# stage 2 asks WHO. Name-matching alone would fire on "Reviewer One's PR" or "the ticket Reviewer Two raised" --
# every mention of a colleague, most of which are not messages -- and a nudge that fires on
# turns it cannot help is a nudge that gets trained away (the failure
# gmail-reply-thread-reminder.sh:30-33 is written to avoid).
set -u

audience_notice=""

_ap_prompt="${prompt:-}"
[ -n "$_ap_prompt" ] || return 0

# Stage 1: does this prompt concern an outbound message at all? Pure parameter expansion, no
# fork -- this runs on EVERY prompt and on-prompt.sh's fork budget is already documented as a
# real contributor to the 30s hook timeout (see its harness-memory loop).
_ap_lc="${_ap_prompt,,}"
case "$_ap_lc" in
  *email*|*e-mail*|*mail*|*slack*|*message*|*messaging*|*draft*|*dm*|*reply*|*respond*|*write\ to*|*send*|*forward*|*notify*|*tell*) ;;
  *) return 0 ;;
esac

_AP_HERE="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib-audience-policy.sh
. "$_AP_HERE/lib-audience-policy.sh"

# Stage 2: which configured people does the prompt name? Word-boundary matched, so a bare
# first name cannot be picked out of a longer word. The whole prompt is handed to the resolver
# as one "key" line only after the resolver's own matcher has been asked for the hit list --
# see audience_match_text below.
audience_match_text "$_ap_prompt" || return 0
[ -n "${audience_policy:-}" ] || return 0

audience_notice="$audience_policy This fired because the prompt names them; if the message actually goes to someone else, resolve the policy for the real recipients instead."
