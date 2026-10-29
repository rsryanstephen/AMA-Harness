#!/usr/bin/env bash
# Shared audience-policy resolver, sourced by audience-policy-check.sh (UserPromptSubmit, via
# on-prompt.sh) and by audience-policy-gate.sh (PreToolUse). Same lib-* shape as
# lib-harness-repos.sh / lib-chatfile-link.sh: one copy of the resolution rule, so the
# pre-compose nudge and the post-compose backstop can never disagree about it.
#
# THE RULE (standing user instruction 2026-08-20, see memory/audience-communication-levels.md):
# outbound email AND Slack depth varies by who is being addressed. The people-to-role mapping
# is deliberately DATA, not code -- the user asked for it to be configurable because people
# swap roles. It lives in harness-config.json's `audiences` block; nothing in this file names
# a person.
#
# Two independent axes, because one ordering cannot express these people. `level`
# (business|<level>) is depth. `avoid` is subject matter a person cannot use even at their
# own level -- an infrastructure lead who does not own the app, a <level> contact at the
# client who has never seen the product. A single seniority number collapses those two and
# gets both wrong.
#
# Resolution: level = MIN across addressees (business < <level>), avoid = UNION. The user's
# "a combination of all of the above -> keep it business level" is then a CONSEQUENCE of the
# min rather than a fourth hand-written case, which is what makes a role swap a one-line
# config edit instead of a code change.
set -u

# Overridable for the gate suite only -- the real file is the default. Same seam convention as
# lib-repo-claims.sh's CLAIMS_FILE and config-key-parity-reminder.sh's CFGPARITY_LIVE. Without
# a seam the suite could only assert the silent direction, and a resolver proven only by "it
# said nothing" is the shape check-gates.sh's own header warns about.
AUDIENCE_CONFIG="${AUDIENCE_CONFIG:-$HOME/.claude/harness-config.json}"

# audience_resolve <newline-separated match keys> -> sets $audience_policy ("" if nobody
# matched). Keys are email addresses, Slack user ids, or bare names -- whatever the caller
# could see. Matching is case-insensitive. A key matching nobody contributes NOTHING: it must
# not drag the level down to the default, or one stranger on a mail would silently mute the
# whole rule.
audience_resolve() {
  audience_policy=""
  [ -f "$AUDIENCE_CONFIG" ] || return 0
  [ -n "${1:-}" ] || return 0

  # CRs are stripped before jq splits on newlines. The native jq.exe here emits CRLF, so a key
  # list piped in from another jq arrives with a trailing CR on every line but the last, and
  # those keys then match nobody. Confirmed live during this change: a two-person mail
  # resolved to ONE person and the second name vanished from the policy, silently, with no
  # error anywhere. Same class as the CRLF bug on-prompt.sh records for the memory notes, and
  # the reason confluence-media-gate.sh and embs-notices-check.sh both strip CRs.
  local _keys
  _keys="$(printf '%s' "$1" | tr -d '\r')"
  [ -n "$_keys" ] || return 0

  # jq reads the config on STDIN, not as a path argument and not via --slurpfile: the native
  # jq here is 1.5rc1 and has NO --slurpfile (confirmed, exit 2 "Unknown option"). Same
  # stdin-redirect shape confluence-media-gate.sh uses.
  audience_policy="$(jq -r --arg keys "$_keys" -f "$(dirname "${BASH_SOURCE[0]}")/lib-audience-policy.jq" < "$AUDIENCE_CONFIG" 2>/dev/null | tr -d '\r')"
}

# audience_match_text <free text> -> sets $audience_policy from whoever the text NAMES.
# Returns 1 (leaving $audience_policy empty) when nobody matches, so a caller can `|| return`.
#
# Matching differs by key shape on purpose. An email address or a Slack user id is distinctive
# enough for a plain substring test. A bare first name is NOT -- unanchored, a three-letter
# name matches inside ordinary words -- so names are word-boundary matched, and only names of
# three or more characters are considered at all.
audience_match_text() {
  audience_policy=""
  [ -f "$AUDIENCE_CONFIG" ] || return 1
  [ -n "${1:-}" ] || return 1

  local _keys
  _keys="$(jq -r --arg text "$1" -f "$(dirname "${BASH_SOURCE[0]}")/lib-audience-match.jq" < "$AUDIENCE_CONFIG" 2>/dev/null | tr -d '\r')"
  [ -n "$_keys" ] || return 1

  audience_resolve "$_keys"
  [ -n "$audience_policy" ] || return 1
  return 0
}
