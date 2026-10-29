#!/usr/bin/env bash
# Preflight an Octopus deployment that is waiting for manual approval, BEFORE Claude approves it
# or hands the user its approval link (user rule 2026-10-15, after a RabbitMq Staging approval
# swapped a load balancer's security group and broke every Staging export for ~9h).
#
# Usage: octopus-approval-preflight.sh [--sid <own-sid>] [--fresh-plan <ServerTasks-N>=<plan.log>]...
#                                      [--ack-session <sid>]... <ServerTasks-N|Deployments-N>...
# Per task it checks:
#   1. WAITING   the task is Executing with a pending interruption (else nothing to approve).
#   2. PLAN      parses the Terraform plan in the task log: No changes / tags ADDED only -> SAFE;
#                tags removed -> REVIEW, mnd-* (ClientCorp governance) tags removed -> BLOCKED;
#                other in-place, create, destroy or replace -> REVIEW (listed);
#                any change to a network resource or attribute (security groups, LB, listener,
#                target group, subnets, ingress/egress, route53) -> NETWORK, with the security
#                groups added/removed and each one's live ingress rules printed. A NETWORK change
#                must be checked against every CLIENT of that resource (who connects to this LB /
#                service, from which SG or CIDR) before anyone approves it.
#   3. STALE     the apply step RE-PLANS with current variables and live AWS, so the approval plan
#                can be out of date: Octopus variable edits on the project or its library sets
#                since the task started -> STALE; plan older than 6h -> STALE unless
#                --fresh-plan gives a read-only plan log (skills/ama-terraform-backbone recipe or
#                the sweep tooling) whose summary line matches the task's.
#   4. CONFLICT  another live Claude session (transcript written <30 min) mentions the task, the
#                deployment or the project; or another deploy of the same project is queued or
#                running. Read that session's tail, then rerun with --ack-session <sid>.
# Verdict per task: SAFE | REVIEW | NETWORK | STALE | CONFLICT | BLOCKED (plan-review.sh blockers) | NOT-WAITING, printed and stamped
# to `hstate octopus approval-preflight/<id>` (both the ServerTasks and Deployments id) as
# "<verdict> <epoch> <project>". Read by hooks/octopus-approval-watch-check.sh (Stop: approval
# link in a reply) and hooks/octopus-approve-preflight-gate.sh (PreToolUse: Claude approving).
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"
CONFIG="${HR_CONFIG_FILE:-$HOME/.claude/harness-config.json}"
SERVER="$(jq -r '.octopus.serverUrl // "https://yourorg.octopus.app"' "$CONFIG" 2>/dev/null | tr -d '\r')"
SPACE="$(jq -r '.octopus.spaceId // "Spaces-1"' "$CONFIG" 2>/dev/null | tr -d '\r')"
O="$SERVER/api/$SPACE"; H="X-Octopus-ApiKey: ${OCTOPUS_API_KEY:-}"
[ -n "${OCTOPUS_API_KEY:-}" ] || { echo "OCTOPUS_API_KEY not set"; exit 2; }
api() { curl -sS --max-time 30 -H "$H" "$O/$1" 2>/dev/null | tr -d '\r'; }
STAMPDIR="$(dirname "$(hstate octopus approval-preflight/.keep)")"; mkdir -p "$STAMPDIR"
PLAN_MAX_AGE="${PREFLIGHT_PLAN_MAX_AGE:-21600}"

own_sid=""; acks=" "; fresh=" "; ids=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sid) own_sid="$2"; shift 2 ;;
    --ack-session) acks="$acks$2 "; shift 2 ;;
    --fresh-plan) fresh="$fresh$2 "; shift 2 ;;
    *) ids+=("$1"); shift ;;
  esac
done
[ ${#ids[@]} -gt 0 ] || { sed -n '6,7p' "$0"; exit 2; }

NETTYPES='aws_security_group|aws_security_group_rule|aws_vpc_security_group_ingress_rule|aws_vpc_security_group_egress_rule|aws_lb|aws_alb|aws_lb_listener|aws_lb_listener_rule|aws_alb_listener|aws_lb_target_group|aws_lb_target_group_attachment|aws_route53_record|aws_network_acl|aws_network_acl_rule|aws_route|aws_route_table|aws_vpc_endpoint'
NETATTRS='security_groups|vpc_security_group_ids|security_group_ids|ingress|egress|cidr_blocks|ipv6_cidr_blocks|source_security_group_id|subnets|subnet_ids|internal|network_configuration|load_balancer|default_action|port|protocol|records|alias'
RANK="SAFE REVIEW NETWORK STALE CONFLICT BLOCKED"
rank() { local i=0 w; for w in $RANK; do [ "$w" = "$1" ] && { echo $i; return; }; i=$((i+1)); done; echo 0; }

now="$(date +%s)"
for id in "${ids[@]}"; do
  task="$id"; dep=""
  case "$id" in
    Deployments-*) dep="$id"; task="$(api "deployments/$id" | jq -r '.TaskId // empty')" ;;
  esac
  [ -n "$task" ] || { echo "$id  ERROR: cannot resolve task"; continue; }
  tj="$(api "tasks/$task")"
  [ -z "$dep" ] && dep="$(printf '%s' "$tj" | jq -r '.Arguments.DeploymentId // empty')"
  dj="$(api "deployments/$dep")"
  proj="$(printf '%s' "$dj" | jq -r '.ProjectId // empty')"; env="$(printf '%s' "$dj" | jq -r '.EnvironmentId // empty')"
  pj="$(api "projects/$proj")"; pname="$(printf '%s' "$pj" | jq -r '.Name // empty')"; pslug="$(printf '%s' "$pj" | jq -r '.Slug // empty')"
  state="$(printf '%s' "$tj" | jq -r .State)"; pend="$(printf '%s' "$tj" | jq -r .HasPendingInterruptions)"
  start="$(printf '%s' "$tj" | jq -r '.StartTime // .QueueTime')"
  echo "=== $task ($dep) $pname $env  state=$state pending=$pend started=$start"
  notes=(); verdict=SAFE
  bump() { [ "$(rank "$1")" -gt "$(rank "$verdict")" ] && verdict="$1"; return 0; }

  # A task paused at a manual-intervention step reports State=Queued (not Executing) + pending=true.
  if [ "$pend" != "true" ] || { [ "$state" != "Executing" ] && [ "$state" != "Queued" ]; }; then
    verdict=NOT-WAITING; notes+=("task is not waiting for approval")
  else
    # Plan-content review (blockers, list-shift noise) is ama-terraform-backbone's plan-review.sh --
    # run it here so one preflight also stamps what terraform-plan-approval-review-check.sh wants.
    PR="$HOME/.claude/skills/ama-terraform-backbone/scripts/plan-review.sh"
    if [ -f "$PR" ]; then
      prout="$(bash "$PR" "$task" 2>&1)"
      bl="$(printf '%s\n' "$prout" | sed -n 's/^BLOCKERS: *//p' | head -n 1)"
      if [ -n "$bl" ] && [ "$bl" != "none" ]; then bump BLOCKED; notes+=("BLOCKED by plan-review.sh: $bl")
      else printf '%s\n' "$prout" | awk '/^TO EXPLAIN/{p=1;next} /^NOISE/{p=0} p' | grep -vE 'Plan: ' | sed 's/^ *- */  plan-review: /'; fi
    fi
    raw="$(api "tasks/$task/raw" | sed -E 's/\x1b\[[0-9;]*m//g; s/^[0-9:]+ +[A-Za-z]+ +\| ?//')"
    summary="$(printf '%s\n' "$raw" | grep -aoE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy|No changes\. (Infrastructure is up-to-date|Your infrastructure matches the configuration)' | tail -n 1)"
    echo "plan: ${summary:-<no plan found in task log>}"
    [ -n "$summary" ] || { bump REVIEW; notes+=("no Terraform plan line in the task log -- not a Terraform step? read the log"); }
    # one line per resource: <action>\t<address>\t<changed attrs csv>
    res="$(printf '%s\n' "$raw" | awk '
      /^ *# [^ ]+ (will be|must be)/ { if (addr!="") print act "\t" addr "\t" attrs; addr=$2; attrs="";
          act=($0 ~ /must be replaced/)?"replace":($0 ~ /will be created/)?"create":($0 ~ /will be destroyed/)?"destroy":($0 ~ /will be read/)?"read":"update"; next }
      /^ *(Plan:|No changes|Changes to Outputs:)/ { if (addr!="") print act "\t" addr "\t" attrs; addr=""; next }
      addr!="" && match($0, /^ *[~+-] [a-z_0-9]+( +=| \{)/) { a=$0; sub(/^ *[~+-] /,"",a); sub(/[ =].*/,"",a); if (index(","attrs",", ","a",")==0) attrs=attrs (attrs==""?"":",") a }
      END { if (addr!="") print act "\t" addr "\t" attrs }')"
    sgs="$(printf '%s\n' "$raw" | grep -aoE '^ *[+-] "sg-[0-9a-f]+"' | tr -d ' "' | sort -u | tr '\n' ' ')"
    while IFS=$'\t' read -r act addr attrs; do
      [ -n "$addr" ] || continue
      [ "$act" = read ] && continue
      rtype="$(printf '%s' "$addr" | sed -E 's/^(module\.[^.]+\.)*(data\.)?//; s/\..*//')"
      others="$(printf '%s' "$attrs" | tr ',' '\n' | grep -vE '^(tags|tags_all)$' | tr '\n' ',' | sed 's/,$//')"
      if [ "$act" = update ] && [ -z "$others" ]; then continue; fi
      net=""
      printf '%s' "$rtype" | grep -qxE "$NETTYPES" && net=1
      printf '%s' "$others" | tr ',' '\n' | grep -qxE "$NETATTRS" && net=1
      if [ -n "$net" ]; then bump NETWORK; notes+=("NETWORK $act $addr [$others]")
      else bump REVIEW; notes+=("$act $addr [${others:-all}]"); fi
    done <<< "$res"
    # Tags-only is SAFE only when tags are ADDED. A removal (`- "k" = "v" -> null`) strips live tags the
    # code lacks; ClientCorp mnd-* governance tags -> BLOCKED (2026-10-15: Cohorts Staging apply stripped them).
    trm="$(printf '%s\n' "$raw" | grep -aoE '^ *- "[A-Za-z0-9:_./-]+" += .* -> null' | sed -E 's/^ *- "([^"]+)".*/\1/' | sort -u | tr '\n' ' ')"
    if [ -n "$trm" ]; then
      case " $trm" in
        *" mnd-"*) bump BLOCKED; notes+=("BLOCKED: plan REMOVES live tags ($trm) -- ClientCorp mnd-* governance tags; add them to the root's code (provider default_tags, ama-terraform-backbone drift class 1) before approving") ;;
        *) bump REVIEW; notes+=("plan REMOVES live tags: $trm -- intended?") ;;
      esac
    fi
    if [ "$(rank "$verdict")" -ge "$(rank NETWORK)" ] && [ -n "$sgs" ]; then
      notes+=("security groups added(+)/removed(-) in the plan: $sgs")
      for sg in $sgs; do
        g="${sg#?}"
        rules="$(aws ec2 describe-security-groups --region us-east-1 --group-ids "$g" --query 'SecurityGroups[0].[GroupName,IpPermissions[].[IpProtocol,FromPort,ToPort,join(`,`,IpRanges[].CidrIp),join(`,`,UserIdGroupPairs[].GroupId)]]' --output json 2>/dev/null | tr -d '\r' | jq -c . 2>/dev/null)"
        notes+=("  $sg ingress: ${rules:-<describe failed>}")
      done
      notes+=("BEFORE APPROVING: list every client of the changed LB/service/SG (which services connect, from which SG/CIDR, on which port) and confirm the NEW rules still admit each one. A security group from a shared Octopus library set is suspect: compare it with what is live and override per project, never edit the shared set.")
    fi
    # STALE: variable edits since the plan ran, or an old plan with no fresh read-only plan
    sts="$(date -d "$start" +%s 2>/dev/null || echo "$now")"
    from="$(date -u -d "@$sts" +%Y-%m-%dT%H:%M:%SZ)"
    regard="$proj $(printf '%s' "$pj" | jq -r '.IncludedLibraryVariableSetIds[]?' | tr '\n' ' ')"
    why=""
    for r in $regard; do
      ev="$(api "events?regarding=$r&from=$from&take=50" | jq -r '.Items[]? | select(.Category=="Modified") | select(.Message|test("variable";"i")) | "\(.Occurred) \(.Username): \(.Message)"' | head -n 3)"
      [ -n "$ev" ] && why="${why}variables changed on $r after the plan ran (the apply uses the NEW values): $ev; "
    done
    age=$(( now - sts ))
    [ "$age" -gt "$PLAN_MAX_AGE" ] && why="${why}plan is $((age/3600))h old; "
    if [ -n "$why" ]; then
      # Either reason is cleared only by a fresh read-only plan (current vars, live AWS) that matches.
      fp=""; for f in $fresh; do case "$f" in "$task="*|"$dep="*) fp="${f#*=}" ;; esac; done
      if [ -z "$fp" ]; then bump STALE; notes+=("STALE: ${why}run a fresh read-only plan (ama-terraform-backbone) and pass --fresh-plan $task=<log>")
      else
        fs="$(sed -E 's/\x1b\[[0-9;]*m//g' "$fp" 2>/dev/null | grep -aoE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy|No changes\. (Infrastructure is up-to-date|Your infrastructure matches the configuration)' | tail -n 1)"
        if [ -n "$fs" ] && [ "${fs%%.*}" = "${summary%%.*}" ]; then notes+=("fresh read-only plan matches the task's plan ($fs); was: $why")
        else bump STALE; notes+=("STALE: fresh plan '$fs' differs from the task's '$summary' -- redeploy so the approval plan is current; was: $why"); fi
      fi
    fi
    # CONFLICT: other deploys of this project in flight, other live sessions on it
    others_t="$(api "deployments?projects=$proj&take=10" | jq -r --arg t "$task" '.Items[] | select(.TaskId!=$t) | .TaskId' | while read -r ot; do api "tasks/$ot" | jq -r 'select(.State=="Executing" or .State=="Queued" or .State=="Cancelling") | "\(.Id) \(.State) \(.Description)"'; done)"
    [ -n "$others_t" ] && { bump CONFLICT; notes+=("CONFLICT: other deploys of this project in flight: $(printf '%s' "$others_t" | tr '\n' ';')"); }
    pdir="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
    short="$(printf '%s' "$pname" | sed -E 's/^.*_(AMA|Applications|Base|Data|Load)_//')"
    while read -r tr; do
      [ -n "$tr" ] || continue
      s="$(basename "$tr" .jsonl)"; [ "$s" = "$own_sid" ] && continue
      case "$acks" in *" $s "*) continue ;; esac
      if tail -n 400 "$tr" 2>/dev/null | grep -aqF -e "$task" -e "$dep" -e "$pname" -e "$pslug"; then
        bump CONFLICT; notes+=("CONFLICT: live session ${s:0:8} mentions $task/$pname -- read its tail; if it is not working this project, rerun with --ack-session $s")
      elif [ -n "$short" ] && tail -n 400 "$tr" 2>/dev/null | grep -aqE "Applications/AMA/$short\b|$short (apply|deploy|plan|teardown)"; then
        bump CONFLICT; notes+=("CONFLICT: live session ${s:0:8} mentions the $short root -- check it, then --ack-session $s")
      fi
    done < <(find "$pdir" -name '*.jsonl' -not -path '*/subagents/*' -newermt '-1800 seconds' 2>/dev/null)
  fi
  for n in "${notes[@]}"; do echo "  - $n"; done
  echo "VERDICT $task $verdict"
  printf '%s %s %s\n' "$verdict" "$now" "$pname" > "$STAMPDIR/$task"
  [ -n "$dep" ] && printf '%s %s %s\n' "$verdict" "$now" "$pname" > "$STAMPDIR/$dep"
done
