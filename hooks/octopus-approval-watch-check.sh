#!/usr/bin/env bash
# Stop hook. A reply that hands the user an Octopus task/deployment/release link and asks them to
# APPROVE or DEPLOY it must also have started scripts/octopus-task-watch.sh on it, as a background
# task -- otherwise the session only learns the outcome when the user pastes a failure (which is
# what happened with ExporterPlus 2.0.0.114 on 2026-10-14, and what the user asked to end).
# Same shape as deferred-window-reminder-check.sh: last assistant text, tail-bounded reads,
# `stop_hook_active` honoured so a resumed turn is never blocked twice.
#   fires when: the reply has an octopus.app link (tasks/ServerTasks-N, deployments/Deployments-N
#               or .../releases/<v>) AND an ask verb (approve / deploy ... to / promote),
#   silent when: a `octopus-task-watch.sh` call sits in the recent transcript, or the reply itself
#               says the watcher is running ("watcher"/"watching").
set -u
payload="$(cat)"
case "$payload" in *"stop_hook_active\":true"*) exit 0 ;; esac
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
[ -n "$tr_path" ] && [ -f "$tr_path" ] || exit 0
sid="$(printf '%s' "$payload" | jq -r '.session_id // "<sid>"')"

text="$(tail -n 200 "$tr_path" 2>/dev/null | jq -s -r '[.[] | select(.type=="assistant")] | last | .message.content[]? | select(.type=="text") | .text' 2>/dev/null | tr -d '\r')"
[ -n "$text" ] || exit 0
printf '%s' "$text" | grep -qE 'octopus\.app/app#/[^ )]*(tasks/ServerTasks-[0-9]+|deployments/Deployments-[0-9]+|/releases/[0-9][^ )/]*)' || exit 0
low="$(printf '%s' "$text" | tr 'A-Z' 'a-z')"
printf '%s' "$low" | grep -qE 'approve|deploy (release|it|this|that|[0-9]|the release|[a-z_]+ to)|promote|run the deploy|please deploy' || exit 0

# 1. Approval preflight (user rule 2026-10-15): every task/deployment linked for approval must carry a
# fresh (<3h) stamp from scripts/octopus-approval-preflight.sh -- plan re-checked, no stale vars, no
# other session on it. NETWORK verdicts may be linked only if the reply names the network change.
# Release-only links (no task yet) have no plan to check and pass through.
. "$HOME/.claude/hooks/lib-claude-paths.sh"
pids="$(printf '%s' "$text" | grep -oE '(ServerTasks|Deployments)-[0-9]+' | sort -u)"
now="$(date +%s)"; pbad=""
for t in $pids; do
  f="$(hstate octopus "approval-preflight/$t")"
  if ! read -r v ts _ < "$f" 2>/dev/null; then pbad="$pbad $t(never preflighted)"; continue; fi
  [ $(( now - ${ts:-0} )) -gt 10800 ] && { pbad="$pbad $t(preflight >3h old)"; continue; }
  case "$v" in
    SAFE|REVIEW) ;;
    NETWORK) printf '%s' "$low" | grep -qE 'security group|load balancer|network change' || pbad="$pbad $t(NETWORK change not explained in the reply)" ;;
    *) pbad="$pbad $t($v)" ;;
  esac
done
if [ -n "$pbad" ]; then
  jq -cn --arg b "$pbad" --arg s "$sid" '{decision:"block", reason:("APPROVAL LINK WITHOUT A CLEARED PREFLIGHT:" + $b + ". Before handing the user an Octopus approval link, run `bash ~/.claude/scripts/octopus-approval-preflight.sh --sid " + $s + " <ids>` (fresh read-only plan via ama-terraform-backbone for plans >6h old or with variables changed since: --fresh-plan <task>=<log>; another live session on the project: read its tail, then --ack-session <sid>). Give links only for SAFE/REVIEW tasks (REVIEW: say what changes); NETWORK: explain the security-group/load-balancer change and which clients you checked. Remove or hold back the rest.")}'
  exit 0
fi

# 2. Watcher
printf '%s' "$low" | grep -qE 'watcher|watching|octopus-task-watch' && exit 0
tail -n 600 "$tr_path" 2>/dev/null | grep -q 'octopus-task-watch.sh' && exit 0

ids="$(printf '%s' "$text" | grep -oE 'ServerTasks-[0-9]+' | sort -u | tr '\n' ' ')"
slug="$(printf '%s' "$text" | grep -oE 'projects/[a-z0-9-]+/' | head -1 | sed 's#projects/##; s#/##')"
how=""
[ -n "$ids" ] && how="for the task(s): \`bash ~/.claude/scripts/octopus-task-watch.sh <ServerTasks-N> $sid\` (one call per id: ${ids})"
[ -z "$ids" ] && how="no task exists yet (you linked a release), so wait for the deploy the user will create: \`bash ~/.claude/scripts/octopus-task-watch.sh --next ${slug:-<Projects-N or project slug>} <Environments-N> $sid\` (environment ids: harness-config.json octopus.environmentIds)"
jq -cn --arg h "$how" '{decision:"block", reason:("DEPLOY HANDED TO THE USER WITH NO WATCHER: the reply asks the user to approve/deploy in Octopus, but nothing in this session will learn whether it succeeds. Start the watcher NOW as Bash run_in_background:true " + $h + ". It is silent until the task ends and then reports SUCCESS or FAILED with the error lines and a cause; on FAILED, debug immediately. User rule 2026-10-14: the user never has to report a failed deploy here. Then end the turn (one line is enough -- do not repeat the reply).")}'
exit 0
