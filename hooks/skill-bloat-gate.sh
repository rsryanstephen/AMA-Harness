#!/usr/bin/env bash
# PreToolUse hook (Edit/Write), mechanical backstop for write-a-skill's anti-bloat rule.
# Confirmed real incident: that rule (added earlier the same day) was violated again in
# the very next skill edit -- a "confirmed real gap:" tag ballooned into a multi-sentence
# incident retelling. Prose alone didn't prevent a repeat, same lesson as bare-cd-gate.sh.
#
# Heuristic, not perfect: flags a paragraph in an edit to CLAUDE.md, or to ANY .md file
# anywhere under a skills/ tree (SKILL.md and reference docs alike -- the match is
# */claude.md or */skills/*.md, and a shell case glob's `*` matches `/`, so this covers
# every depth), that both contains "confirmed real" (this harness's own established
# one-line-tag lead-in) AND exceeds ~35 words. A genuine one-line tag reads well under
# that; every real violation so far was well over it. A determined rewrite could dodge
# the phrase and still smuggle in narrative bloat under different wording -- this
# catches the specific, already-confirmed pattern, not every conceivable phrasing of the
# same mistake. Widened past skills/*/SKILL.md after CLAUDE.md and a
# DEPLOY-VERIFICATION.md edit both landed unchecked (same pattern, uncovered path).
set -u

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"

[ -n "$file_path" ] || exit 0

norm="$(printf '%s' "$file_path" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')"
case "$norm" in
  */skills/*.md) : ;;
  */claude.md) : ;;
  *) exit 0 ;;
esac

text=""
case "$tool" in
  Edit) text="$(printf '%s' "$payload" | jq -r '.tool_input.new_string // empty')" ;;
  Write) text="$(printf '%s' "$payload" | jq -r '.tool_input.content // empty')" ;;
  *) exit 0 ;;
esac
[ -n "$text" ] || exit 0

# Split into paragraphs (blank-line separated), skip fenced code blocks, check each.
offender="$(printf '%s\n' "$text" | awk '
  BEGIN { para=""; in_code=0 }
  /^```/ { in_code = !in_code; next }
  in_code { next }
  /^[[:space:]]*$/ {
    if (para != "") { print para; print "\x01" }
    para=""
    next
  }
  { para = (para=="" ? $0 : para " " $0) }
  END { if (para != "") { print para; print "\x01" } }
' | awk -v RS='\x01' '{
  p=$0
  lower=tolower(p)
  if (index(lower, "confirmed real") > 0) {
    n = split(p, words, /[[:space:]]+/)
    if (n > 35) { print p; exit }
  }
}')"

[ -n "$offender" ] || exit 0

jq -cn --arg p "$offender" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("This paragraph reads as incident-narrative bloat, not an instruction (contains \"confirmed real\" and runs long). Per write-a-skill'"'"'s anti-bloat rule: trim to a one-line tag naming the consequence, drop the backstory of what broke/used-to-happen -- the commit message already owns that. Offending paragraph: \"" + $p + "\"")
  }
}'
