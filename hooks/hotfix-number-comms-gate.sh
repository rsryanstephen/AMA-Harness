#!/usr/bin/env bash
# PreToolUse hook (Gmail draft/send + Slack send/draft/schedule). Denies an outbound message
# that names a hotfix NUMBER. Saying "a hotfix" is fine; "hotfix 2.19.1" is not.
#
# User instruction 2026-08-21: harness comms shouldn't mention the hotfix number in Slacks or
# emails, just that it is a hotfix. Rule and rationale in memory/hotfix-number-not-in-comms.md.
# Gated rather than left to prose because self-recognition per message is unreliable --
# CLAUDE.md's mechanical-triggers rule, same reasoning as slack-brevity-gate.sh.
#
# Why deny and not ask: the rule is unconditional and the fix is always available (drop the
# number), so this is a gate that can genuinely fail -- unlike tone, which is why
# audience-policy-gate.sh only injects context. An `ask` would also stack a second prompt onto
# the same calls client-mail-cc-gate.sh already asks on.
#
# Fields scanned: Slack `message`, plus Gmail `subject`/`body`/`htmlBody` (paths taken from
# gmail-draft-sig-gate.sh). Subject is in scope deliberately -- that is where a version lands.
#
# ACCEPTED RECALL LIMIT, stated rather than chased: only a version ADJACENT to the word
# hotfix/HF is caught. "Fix is out, deployed 2.19.1 to prod" in a separate sentence passes.
# Widening to any bare X.Y version would false-positive on dates, ticket numbers, library
# versions and timings, so precision wins here -- the prose rule still covers the rest.
#
# Scope is Slack + email ONLY. Jira comments, Confluence pages, release notes and commit
# messages legitimately carry the version and are not matched (no such tool in the matcher).
set -u

payload="$(cat)"

# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh) --
# no hotfix/HF literal anywhere means this cannot be a hit. Deliberately a `grep -qiE` and not
# a `case` glob: the glob is case-SENSITIVE while the pattern below runs `grep -oiP`, so a case
# list would fail open on `hf 2.19.1` / `hotFix/3.4.0` -- confirmed live, both slipped through.
# One grep fork is still far cheaper than jq, and it can no longer disagree with what it guards.
printf '%s' "$payload" | grep -qiE 'hot-?fix|HF' || exit 0

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
case "$tool" in
  mcp__*__create_draft|mcp__*__update_draft|mcp__*__reply|mcp__*__forward|mcp__*__send_message) ;;
  mcp__*__slack_send_message|mcp__*__slack_send_message_draft|mcp__*__slack_schedule_message) ;;
  *) exit 0 ;;
esac

text="$(printf '%s' "$payload" | jq -r '
  [.tool_input.message // "", .tool_input.subject // "",
   .tool_input.body // "", .tool_input.htmlBody // ""] | join("\n")' 2>/dev/null)"
[ -n "$text" ] || exit 0

# hotfix / hot-fix / HF, optional filler word (release|version|branch|build|v), then a dotted
# version. The dot is required, so "one hotfix", "2 hotfixes", "HF today" all pass. A full stop
# is deliberately NOT a separator -- it would make "a hotfix. 3.5 hours later" a hit.
PAT='(hotfix|hot-fix|\bHF)\b[[:space:]/_:-]*((release|version|branch|build)[[:space:]/_:-]*)?v?[0-9]+\.[0-9]+'
hit="$(printf '%s' "$text" | tr -d '\r' | grep -oiP "$PAT" | head -1)" || exit 0
[ -n "$hit" ] || exit 0

jq -cn --arg h "$hit" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("This message names a hotfix number (\"" + $h + "\"). Standing user instruction 2026-08-21: Slack messages and emails say that a fix went out as a HOTFIX, never which one. Rewrite as \"a hotfix\" / \"shipped as a hotfix\" and drop the version entirely -- do not swap it for a vaguer number. Subject lines count too. If the user explicitly asked for the number in this message, tell them the standing rule blocks it rather than silently including it or silently stripping it. Jira comments, Confluence pages, release notes, commit messages and branch names are NOT in scope and keep the version. See memory/hotfix-number-not-in-comms.md.")
  }
}'
