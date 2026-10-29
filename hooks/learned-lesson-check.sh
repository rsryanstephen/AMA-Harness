#!/usr/bin/env bash
# Stop hook. A reply that reports a LEARNED LESSON about a system this harness works with
# (a wrong assumption corrected, a root cause found, "the fix was X") must also have recorded
# it somewhere durable this turn -- a skill/memory/AGENTS edit or a harness-gaps.md line --
# or the turn is sent back once (decision:block) to do so.
#
# User instruction 2026-10-14 (PROJ-15658 session): "when Claude runs into issues and
# learns the correct way to do something related to any part of AMA, it should automatically
# update the harness so future agents handle it better." CLAUDE.md already says where a
# lesson goes (Gotcha/Lesson Placement); this is the mechanical trigger behind it, because
# self-recognition is unreliable -- that session had learned six Terraform-on-Windows lessons
# before anything was written down, and only because the user asked.
#
# Shape: same reply-scan as self-checkable-ask-reminder.sh (last assistant text, paragraph
# split, co-occurrence rule). Precision comes from THREE conditions in one paragraph:
#   lesson phrase  ("i was wrong", "the real cause", "turned out", "the fix was" ...)
#   system keyword (terraform, octopus, aws, jira, docker, msys, hook, gate ...)
#   no durable write in the turn's transcript tail (Edit/Write under ~/.claude or the harness
#   repo, or an append to harness-gaps.md), and not quoting the rule in backticks.
# stop_hook_active (the resumed turn) -> silent, or it would loop. One block per turn.
set -u

payload="$(cat)"
case "$payload" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
[ -n "$tr_path" ] && [ -f "$tr_path" ] || exit 0

tail_json="$(tail -n 400 "$tr_path" 2>/dev/null)"
text="$(printf '%s\n' "$tail_json" | jq -s -r '
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
    lesson = (p ~ /i was wrong/ || p ~ /my earlier (reading|claim|answer) was wrong/ || p ~ /that was wrong/ ||
              p ~ /the real cause/ || p ~ /root cause (was|is|turned)/ || p ~ /turned out (to be|that)/ ||
              p ~ /turns out (to be|that)/ || p ~ /the actual fix/ || p ~ /the fix (was|is) to/ ||
              p ~ /the trick is/ || p ~ /lesson:/ || p ~ /gotcha:/ || p ~ /what i got wrong/)
    sys = (p ~ /terraform/ || p ~ /octopus/ || p ~ /\baws\b/ || p ~ /jira/ || p ~ /confluence/ ||
           p ~ /bitbucket/ || p ~ /pipeline/ || p ~ /graylog/ || p ~ /redshift/ || p ~ /postgres/ ||
           p ~ /documentdb/ || p ~ /mongo/ || p ~ /docker/ || p ~ /msys/ || p ~ /git-bash/ ||
           p ~ /powershell/ || p ~ /\bhook\b/ || p ~ /\bgate\b/ || p ~ /slack/ || p ~ /\becs\b/ ||
           p ~ /cloudfront/ || p ~ /lambda/)
    quoted = (p ~ /`[^`]*(i was wrong|the real cause|turned out|the fix was)[^`]*`/)
    if (lesson && sys && !quoted) { print; exit }
  }
')"
[ -n "$hit" ] || exit 0

# A durable write already happened this turn? Edit/Write into the harness (any path under
# .claude/ or ama-claude-harness/) or an append to harness-gaps.md. Bounded to the tail read.
if printf '%s' "$tail_json" | grep -aqE '"name":"(Edit|Write)"[^}]*"file_path":"[^"]*(/\.claude/|ama-claude-harness/)' \
   || printf '%s' "$tail_json" | grep -aqE 'harness-gaps\.md'; then
  exit 0
fi

snippet="$(printf '%s' "$hit" | cut -c1-220)"
jq -cn --arg s "$snippet" '{decision:"block",
  reason:("learned-lesson-check: this reply reports a lesson about a system the harness works with, and nothing durable was written this turn. Paragraph: \"" + $s + "...\". Before ending the turn: put the lesson where the NEXT agent hitting the problem will find it (CLAUDE.md Gotcha/Lesson Placement -- the skill whose description matches the future request, memory/ for a user rule, AGENTS.md one-liner for a hook/gate fact), or append one line to ~/.claude/harness-gaps.md if it is only a gap you cannot fix now. Then finish the reply. If the paragraph is not a durable lesson (a one-off fact about this ticket), say so in one line and end the turn; this hook does not fire again on the resumed turn.")}'
