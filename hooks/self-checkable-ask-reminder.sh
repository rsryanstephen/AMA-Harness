#!/usr/bin/env bash
# Stop hook. Flags a reply that told the USER to go and check something Claude can read
# itself through an existing harness skill.
#
# The incident, 2026-08-20: a reply ended "Worth checking the Octopus yourproduct-blog-domain
# value -- that decides whether this is open right now, and it isn't readable from the
# repos." The repos part was true; the conclusion was not. Three read-only API calls
# (project -> variableset -> variables) answered it, and the answer inverted the finding:
# the variable is populated in every environment scope, so the Contains("") fail-open the
# reply had just called urgent was not reachable at all. The user had to ask for a check
# that should never have been handed to them.
#
# Deliberately NOT a PreToolUse gate -- there is no tool call to intercept. The failure
# lives in prose, so the reply text is the only observable surface. Same reply-scanning
# shape as on-stop.sh's check_unticketed_flag (paragraph split, \x01 record separator,
# backtick guard), and a separate FILE from on-stop.sh on purpose: that file regularly
# carries another session's staged changes, and harness-gaps.md already records one
# incident of a concurrent session's work being swept into a harness commit.
#
# Precision comes from CO-OCCURRENCE, not from the ask-phrase alone. "worth checking" is
# far too common on its own; it only flags when a readable-system keyword sits in the SAME
# paragraph. A rule that fires on every "please check" would be trained away within a day.
set -u

payload="$(cat)"
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
[ -n "$tr_path" ] || exit 0
[ -f "$tr_path" ] || exit 0

# Last assistant turn only. tail bounds the read rather than duplicating on-stop.sh's
# per-session offset bookkeeping -- a reply is always within the last few transcript lines.
text="$(tail -n 200 "$tr_path" 2>/dev/null | jq -s -r '
  [.[] | select(.type=="assistant")] | last | .message.content[]? |
  select(.type=="text") | .text' 2>/dev/null | tr -d '\r')"
[ -n "$text" ] || exit 0

hit="$(printf '%s\n\n' "$text" | awk '
  BEGIN { para="" }
  /^[[:space:]]*$/ { if (para != "") { print para; print "\x01" }; para=""; next }
  { para = (para=="" ? $0 : para " " $0) }
' | awk -v RS='\x01' '
  {
    p = tolower($0)
    # Asking the user to go and look at something.
    ask = (p ~ /worth checking/ || p ~ /you.ll need to check/ || p ~ /you will need to check/ ||
           p ~ /needs a look at/ || p ~ /cannot be determined from/ || p ~ /not readable from/ ||
           p ~ /could you check/ || p ~ /can you check/ || p ~ /please check/)
    # A system this harness already reads programmatically.
    sys = (p ~ /octopus/ || p ~ /variable set/ || p ~ /task definition/ || p ~ /task def/ ||
           p ~ /ecs/ || p ~ /graylog/ || p ~ /redshift/ || p ~ /postgres/ || p ~ /cloudwatch/ ||
           p ~ /documentdb/ || p ~ /pipelines?\b/ || p ~ /confluence/ || p ~ /jira/)
    # Quoting the rule (backtick immediately before the phrase) is not committing it.
    quoted = (p ~ /`"?(worth checking|please check|can you check)/)
    if (ask && sys && !quoted) { print; exit }
  }
')"

[ -n "$hit" ] || exit 0

snippet="$(printf '%s' "$hit" | cut -c1-220)"
printf -- '- [session %s, %s] SELF-CHECKABLE ASK: "%s..." -- the reply asked the user to check something a harness skill can read (Octopus/ECS/Graylog/Postgres/Redshift/Jira/Confluence/Bitbucket). See the self-check-before-asking memory note for which surfaces are readable and which genuinely need the user. Resolve: do the check, or confirm it really did need a human.\n' \
  "${sid%%-*}" "$(date +%Y-%m-%d)" "$snippet" >> "$HOME/.claude/harness-gaps.md"
exit 0
