#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell, dispatched). Denies Claude APPROVING an Octopus manual-intervention
# (POST .../interruptions/<id>/submit, or a helper invoked as `approve ServerTasks-N`) unless
# scripts/octopus-approval-preflight.sh stamped every named task in the last 3h with an
# approvable verdict.
#   SAFE / REVIEW  -> allowed (REVIEW = the preflight listed non-tag changes; say them to the user)
#   NETWORK        -> denied unless the command carries AMA_APPROVE_NETWORK_ACK=1, which needs the
#                     user's explicit yes to the security-group / load-balancer change AFTER the
#                     clients of that resource were checked against the new rules
#   STALE / CONFLICT / NOT-WAITING / no stamp -> denied: re-plan, or resolve the other session
# Why (user rule 2026-10-15): this session approved RabbitMq Staging (ServerTasks-424416) from a
# tags-looking plan; the apply swapped the broker NLB's security group to an offices-only group and
# every Staging export failed for ~9h. Twin of the Stop check in octopus-approval-watch-check.sh,
# which applies the same stamps to an approval LINK handed to the user.
set -u
IFS= read -r -d '' payload || true
case "$payload" in
  *interruptions*|*approve*) ;;
  *) exit 0 ;;
esac
. "$HOME/.claude/hooks/lib-claude-paths.sh"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // "" | gsub("[\n\r]"; " ")' | tr -d '\r')"
[ -n "$command" ] || exit 0
. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
region="$(command_scan_region "$command")"
. "$HOME/.claude/hooks/lib-scan-script-refs.sh" 2>/dev/null && region="$region
$(scan_referenced_scripts "$command")"
flat="$(printf '%s' "$region" | tr '\n' ' ')"
# Approve actions only -- a GET listing interruptions or the word in prose does not count.
printf '%s' "$flat" | grep -qE 'interruptions/[^[:space:]"'"'"']*/submit' && act=1 || act=""
printf '%s' "$command" | grep -qE '(^|[[:space:]])approve[[:space:]]+ServerTasks-[0-9]+' && act=1
[ -n "$act" ] || exit 0

deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
ids="$(printf '%s' "$command" | grep -oE '(ServerTasks|Deployments)-[0-9]+' | sort -u)"
[ -n "$ids" ] || deny "Octopus approval blocked: no literal ServerTasks-N / Deployments-N in the command, so the approval preflight cannot be checked. Run \`bash ~/.claude/scripts/octopus-approval-preflight.sh --sid <your sid> <ServerTasks-N>\` and approve by task id."
now="$(date +%s)"; bad=""
for t in $ids; do
  f="$(hstate octopus "approval-preflight/$t")"
  read -r v ts _ < "$f" 2>/dev/null || { bad="$bad
  - $t: never preflighted"; continue; }
  if [ $(( now - ${ts:-0} )) -gt 10800 ]; then bad="$bad
  - $t: preflight is older than 3h ($v)"; continue; fi
  case "$v" in
    SAFE|REVIEW) ;;
    NETWORK) case "$command" in *AMA_APPROVE_NETWORK_ACK=1*) ;; *) bad="$bad
  - $t: NETWORK change (security group / load balancer / listener / route). Check every client of the resource against the new rules, show the user, and only with their explicit yes re-run with AMA_APPROVE_NETWORK_ACK=1." ;; esac ;;
    *) bad="$bad
  - $t: preflight verdict $v" ;;
  esac
done
[ -n "$bad" ] && deny "Octopus approval blocked -- the approval preflight has not cleared these tasks:$bad
Run \`bash ~/.claude/scripts/octopus-approval-preflight.sh --sid <your sid> [--fresh-plan <task>=<read-only plan log>] [--ack-session <sid>] <ids>\` and act on what it reports (STALE: fresh read-only plan via ama-terraform-backbone; CONFLICT: read the other session's tail first)."
exit 0
