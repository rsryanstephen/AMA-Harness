#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell): after a MUTATING production AWS CLI call, check the
# ticket bookkeeping. Closes harness-gaps.md's infra-only gap at both ends:
#
# 1. THE TICKET IS STILL "Open"/"To Do". ticket-worked-while-open-gate.sh already covers
#    this for a `git commit`, but infra-only work (a security-group rule, a DNS record) has
#    no commit for that hook to see. Confirmed live 2026-08-20: PROJ-15314 was worked
#    to a production `modify-security-group-rules` call while sitting at Open, and nothing
#    warned.
#
# 2. THE WORK IS DONE BUT NOTHING EVER CLOSES IT. commit-ticket-jira's infra-only transition row
#    says a live-in-prod infra change with nothing outstanding goes straight to Done, or to
#    Ready to Test + a follow-up ledger row if blocked on a third party. Nothing enforced
#    that either -- confirmed live 2026-08-26: PROJ-15312's whitelisting went live on
#    two production load balancers and sat at In Progress until the user pointed it out.
#
# Modelled on ticket-worked-while-open-gate.sh (live Jira read, block-shaped reminder,
# fails open) and octopus-prod-deploy-ticket-sweep-reminder.sh (cheap raw prefilter before
# any jq fork).
#
# Only MUTATING verbs fire this -- describe-*/get-* never match, so a read-only sweep of
# the fleet stays silent. Known gap, same class as the deploy-sweep hook's: only catches
# calls with the verb literally in the command text; a wrapper script or SDK call bypasses
# it. Accepted tradeoff, not silently "handled".
#
# Reminder, never a gate: the AWS call already happened by the time this runs, and Jira
# bookkeeping must never be able to block infra work. Fails open on no token, no network,
# an unparseable response, or a status this hook doesn't have an opinion on.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork -- every mutating verb below is an `aws`
# subcommand, so a payload without the literal substring can exit on zero forks.
case "$payload" in *aws*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
[ -n "$command" ] || exit 0

# Terraform-first nudge (PROJ-15657): CloudFront/WAF/S3-bucket/log-delivery config is
# yourproduct-backbone Terraform. A CLI change drifts state and the next Octopus apply reverts it
# (PROJ-15654's console fix would have been undone by a pre-fix release). Context only,
# no ticket read. create-invalidation is routine and excluded; s3api object verbs too.
if printf '%s' "$command" | grep -qP \
  'aws\s+(cloudfront\s+((create|update|delete|associate|disassociate)-(?!invalidation)|(un)?tag-resource)|wafv2\s+(create|update|delete|associate|disassociate|put|tag|untag)-|s3api\s+(create-bucket|delete-bucket|put-bucket-|put-public-access-block)|logs\s+(put-delivery-|create-delivery|delete-delivery))'; then
  jq -cn '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:"That AWS call changed CloudFront/WAF/S3-bucket/log-delivery config, which yourproduct-backbone Terraform manages (e.g. Applications/AMA/ExporterPlus). A CLI change drifts the state and the next Octopus apply reverts it. Make the change in yourproduct-backbone instead; if it had to be done by hand, put the same change (or an import block) in code under the same ticket before closing it. PROJ-15657."}}'
  exit 0
fi

printf '%s' "$command" | grep -qP \
  'aws\s+(ec2\s+(authorize-security-group-(ingress|egress)|revoke-security-group-(ingress|egress)|modify-security-group-rules)|elb\s+apply-security-groups-to-load-balancer|elbv2\s+set-security-groups|route53\s+change-resource-record-sets)' \
  || exit 0
# Verb carries no environment: a staging/qa target named in the command (and no production
# one) is not a production mutation. Bare sg-/zone ids stay ambiguous -> still fires.
if printf '%s' "$command" | grep -qiP '(staging|qa)-v1-' && ! printf '%s' "$command" | grep -qiP 'production|prod-v1-'; then
  exit 0
fi

ticket=""
if [ -n "$sid" ]; then
  TF="$HOME/.claude/.session-chatfiles/$sid.ticket"
  [ -f "$TF" ] && ticket="$(cat "$TF" 2>/dev/null)"
fi
[ -n "$ticket" ] || exit 0

CONFIG="$HOME/.claude/harness-config.json"
[ -f "$CONFIG" ] || exit 0
email="$(jq -r '.user.email // empty' "$CONFIG" 2>/dev/null | tr -d '\r')"
host="$(jq -r '.atlassian.cloudId // "yourorg.atlassian.net"' "$CONFIG" 2>/dev/null | tr -d '\r')"
harness_epic="$(jq -r '.atlassian.harnessEpicKey // "<harnessEpicKey>"' "$CONFIG" 2>/dev/null | tr -d '\r')"
regressions="$(jq -r '.atlassian.regressionsTicketKey // empty' "$CONFIG" 2>/dev/null | tr -d '\r')"
[ -n "$email" ] || exit 0
[ -n "${ATLASSIAN_API_TOKEN:-}" ] || exit 0

# Both documented never-transition tickets -- same exemption ticket-worked-while-open-gate
# uses, for the same reason.
[ "$ticket" != "$harness_epic" ] || exit 0
[ -n "$regressions" ] && [ "$ticket" = "$regressions" ] && exit 0

issue="$(curl -sS --max-time 8 -u "$email:$ATLASSIAN_API_TOKEN" \
  "https://$host/rest/api/3/issue/$ticket?fields=status" 2>/dev/null)"
[ -n "$issue" ] || exit 0
status="$(printf '%s' "$issue" | jq -r '.fields.status.name // empty' 2>/dev/null)"
[ -n "$status" ] || exit 0

reason=""
case "$status" in
  Open|"To Do")
    reason="$ticket is still \"$status\" but a production infra mutation for it just landed. Move it to In Progress NOW (same rule ticket-worked-while-open-gate.sh enforces for a commit -- this is that gap's infra-only twin: PROJ-15314 reached a production security-group mutation while sitting at Open and nothing warned)."
    ;;
  "In Progress")
    reason="$ticket is at In Progress and a production infra mutation just landed with no code artifact behind it -- for this shape the change IS the deploy (commit-ticket-jira's infra-only transition row). Once you've verified it's actually live (describe the real resource, don't infer from the write response), transition it now: nothing outstanding -> Done directly; blocked on a third party confirming -> Ready to Test + a comment naming who owes what and linking the thread, then seed an ama-followups ledger row for the check-in. Confirmed live 2026-08-26: PROJ-15312's whitelisting sat at In Progress after going live on two production load balancers until the user pointed it out."
    ;;
  *) exit 0 ;;
esac

jq -cn --arg t "$ticket" --arg s "$status" --arg r "$reason" '{
  decision: "block",
  reason: ("Just ran a production infra mutation for " + $t + " (status: " + $s + ") -- fix the ticket bookkeeping now: " + $r)
}'
