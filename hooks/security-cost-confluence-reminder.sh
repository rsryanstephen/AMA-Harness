#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell, dispatched): after a Jira transition or comment on a ticket that
# reads like an AMA SECURITY improvement or an INFRASTRUCTURE COST saving/improvement, remind the
# session to add a dated row to the matching Confluence record (user instruction 2026-10-13):
#   security -> atlassian.securityImprovementsPageId ("AMA Security Improvements")
#   cost     -> atlassian.costSavingsPageId ("Cost Optimizations", Reviewer One's page; log table at the bottom)
# Rule + how: skills/ama-confluence-api/SKILL.md "Security / cost records".
#
# Why a hook: "remember to update the page after X" is exactly the self-recognition that fails
# (CLAUDE.md "Mechanical Triggers Over Self-Recognition"). A transition/comment is the moment the
# work is described in words, so it is the cheapest reliable trigger.
#
# Signal = keyword match on the ticket SUMMARY plus the comment body (JIRA_PAYLOAD_FILE). Over-matching
# costs one ignorable nudge; the reason text tells the model to skip work that is neither. Once per
# session per ticket+kind. Harness epic / regressions ticket exempt. Fails open (no token, no network,
# no config) -- reminder only, never blocks.
set -u

IFS= read -r -d '' payload || true
case "$payload" in
  *jira-add-comment*|*jira-transition-issue*) ;;
  *) exit 0 ;;
esac

. "$HOME/.claude/hooks/lib-claude-paths.sh"
. "$HOME/.claude/hooks/lib-command-text.sh"

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' | tr -d '\r')"
command_scan="$(printf '%s\n' "$command" | command_text_stripped)"
printf '%s' "$command_scan" | grep -qE 'jira-(add-comment|transition-issue)\.sh' || exit 0
key="$(printf '%s' "$command" | grep -oP '[A-Z][A-Z0-9]+-\d+' | head -1)"
[ -n "$key" ] || exit 0

CONFIG="$HOME/.claude/harness-config.json"
[ -f "$CONFIG" ] || exit 0
cfg="$(jq -r '[.user.email // "", .atlassian.cloudId // "yourorg.atlassian.net",
  .atlassian.harnessEpicKey // "", .atlassian.regressionsTicketKey // "",
  .atlassian.securityImprovementsPageId // "", .atlassian.costSavingsPageId // ""] | @tsv' "$CONFIG" 2>/dev/null | tr -d '\r')"
IFS=$'\t' read -r email host epic regressions secpage costpage <<< "$cfg"
[ "$key" = "$epic" ] || [ "$key" = "$regressions" ] && exit 0
[ -n "$secpage" ] || [ -n "$costpage" ] || exit 0

body=""
PF="$(jira_payload_file "$command" 2>/dev/null)"
[ -n "$PF" ] && [ -f "$PF" ] && body="$(jq -r '.body // empty' < "$PF" 2>/dev/null)"
summary=""
if [ -n "$email" ] && [ -n "${ATLASSIAN_API_TOKEN:-}" ]; then
  summary="$(curl -sS --max-time 8 -u "$email:$ATLASSIAN_API_TOKEN" \
    "https://$host/rest/api/2/issue/$key?fields=summary" 2>/dev/null | jq -r '.fields.summary // empty' 2>/dev/null | tr -d '\r')"
fi
text="$summary
$body"

SEC='security|vulnerab|content-security|\bCSP\b|\bIAM\b|secret|credential|access key|\bpublic(ly)?\b.{0,40}\b(bucket|access|read|endpoint|exposed)|least.privilege|end.of.life|\bEOL\b|unsupported runtime|leak|exposure|encrypt|penetration|pentest'
COST='\bcost|saving|decommission|downsiz|right.?siz|scal(e|ed|ing) (down|to (0|zero))|shut(s|ting)? ?down|terminat|\bgp3\b|\bRA3\b|savings plan|reserved instance|retire|clean.?up of (old|unused)|idle'
kinds=""
printf '%s' "$text" | grep -qiP "$SEC" && kinds="security"
printf '%s' "$text" | grep -qiP "$COST" && kinds="$kinds cost"
[ -n "$kinds" ] || exit 0

# Once per session per ticket+kind.
ledger="$(hstate sessions "${sid:-nosid}.confluence-log-nudged")"
new=""
for k in $kinds; do
  grep -qx "$key:$k" "$ledger" 2>/dev/null && continue
  echo "$key:$k" >> "$ledger"; new="$new $k"
done
[ -n "$new" ] || exit 0

base="https://$host/wiki/spaces/HO/pages"
targets=""
case "$new" in *security*) [ -n "$secpage" ] && targets="$targets security -> page $secpage ($base/$secpage) table 'Improvements';" ;; esac
case "$new" in *cost*) [ -n "$costpage" ] && targets="$targets cost/infrastructure -> page $costpage ($base/$costpage) table 'Cost savings and infrastructure improvements log';" ;; esac

msg="$key reads like${new} work. If it really is an AMA security improvement or an infrastructure cost saving/improvement that is now live (or landed), add ONE dated row to the matching Confluence record before you finish:${targets} Newest first, plain words, why it matters, status per environment, the ticket key; skip if this ticket is neither or the row already exists. How (get -> splice a <tr> after the header row -> update storage -> verify): skills/ama-confluence-api/SKILL.md "Security / cost records"."
jq -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$c}}'
