#!/usr/bin/env bash
# Reads the AWS notice surfaces that `health describe-events` structurally cannot see, and
# emits them in the SAME shape aws-notices-plan.sh already uses for Health events, so they
# ride the existing ledger machinery (suppress / restamp / watch) instead of a parallel one.
# PROJ-15336; the coverage audit that produced the list is PROJ-15332.
#
# WHY SYNTHETIC ROWS RATHER THAN A NEW PIPELINE
# Everything here is a STANDING CONDITION, not an event: a Trusted Advisor recommendation,
# a pending maintenance action or a deprecated runtime stays true until a human fixes it.
# Health events open and close; these do not. The plan script's diff is keyed on
# (arn, lastUpdatedTime) for suppression and on sha1(description) for restamp-vs-candidate,
# and that is exactly the right shape for a standing condition PROVIDED the stamp is
# content-derived rather than a clock. So each leg supplies:
#   arn              -- stable synthetic identity, `synthetic:<leg>:<id>`
#   lastUpdatedTime  -- a CONTENT value that moves only when the condition materially
#                       changes. Never a timestamp that churns on its own.
#   description      -- the human-readable finding; its hash decides candidate vs restamp.
# Get the stamp wrong and you get the failure this skill already documents: six year-old
# ELASTICACHE events re-flagging every week until the monitor got muted, which is how the
# Redis OSS EOL was missed. Per-leg stamp choices are justified at each leg below.
#
# READ-ONLY BY CONTRACT. Every call here is a list/describe. Nothing in this file may
# mutate anything -- it is run by an unattended monitor, and AGENTS.md's support-notices
# precedent is explicit that a read-only script is read-only by contract, not by luck.
#
# Usage: aws-notices-surfaces.sh
# Output: JSONL on stdout, one object per finding:
#   {arn, typeCode, region, service, category, lastUpdatedTime, startTime, endTime,
#    statusCode, desc, entities:[...]}
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

# The ACM leg reads the ledger directly: its rule is "NotAfter has not MOVED", which is a
# comparison against the previous run, not a property of the current API response. Every
# other leg is stateless and lets the plan script's diff do the work.
SEEN="$(hstate notices .aws-notices-seen)"
[ -f "$SEEN" ] || SEEN=/dev/null

# Regions. AC #3 of PROJ-15336 requires region handling to be iterated or explicitly
# documented as single-region. It is ITERATED: the ticket measured 22 deprecated Lambda
# runtimes and also recorded that eu-west-1 demonstrably holds real Lambdas, so a
# us-east-1-only census would under-report the very number the acceptance criterion names.
# The plan script's "no --region flag" convention is about describe-events, which is global;
# these are regional APIs and have no global view.
REGIONS_CSV="$(hr_config '.awsNotices.regions' 'us-east-1,eu-west-1')"
ACM_WINDOW="$(hr_config '.awsNotices.certExpiryLeadDays' 60)"

IFS=',' read -r -a REGIONS <<< "$REGIONS_CSV"

today_epoch="$(date +%s)"

emit() { # emit <arn> <typeCode> <region> <service> <category> <stamp> <status> <desc> <entities-json>
  jq -nc --arg arn "$1" --arg code "$2" --arg region "$3" --arg service "$4" \
         --arg category "$5" --arg upd "$6" --arg status "$7" --arg desc "$8" \
         --argjson entities "${9:-[]}" \
    '{arn:$arn, typeCode:$code, region:$region, service:$service, eventTypeCategory:$category,
      lastUpdatedTime:$upd, startTime:"", endTime:"", statusCode:$status,
      desc:$desc, entities:$entities}'
}

# --- Leg 1: Trusted Advisor ------------------------------------------------------------
# TRAP (measured, PROJ-15336): filter on lifecycleStage, NOT status. Two checks report
# status=error with lifecycleStage=resolved dated 2024 (RDS CA Certificate Expiration and
# the DocumentDB equivalent); all live CA certs were cross-checked and expire 2027. A
# status-only filter alarms on those forever.
# TRAP: the older `support describe-trusted-advisor-checks` API is a dead end here --
# describe-trusted-advisor-check-summaries rejects its own check ids with
# UNKNOWN_CHECK_ID_ERROR. Use the `trustedadvisor` service, not `support`.
# STAMP: lifecycleStage + status. Moves when the recommendation is resolved/dismissed or
# changes severity; does not move while it simply keeps being true.
leg_trusted_advisor() {
  local out
  out="$(MSYS_NO_PATHCONV=1 aws trustedadvisor list-recommendations \
           --output json 2>/dev/null)" || return 0
  printf '%s' "$out" | jq -r '
      .recommendationSummaries[]?
      | select((.lifecycleStage // "") as $l
               | ($l != "resolved" and $l != "dismissed"))
      | select((.status // "") as $s | ($s == "error" or $s == "warning"))
      | [ (.id // ""), (.name // ""), (.status // ""), (.lifecycleStage // ""),
          (.pillars // [] | join("/")), ((.resourcesAggregates.errorCount // 0)|tostring),
          ((.resourcesAggregates.warningCount // 0)|tostring), (.source // "") ]
      | @tsv' 2>/dev/null | tr -d '\r' \
  | while IFS=$'\t' read -r id name status stage pillars errc warnc source; do
      [ -n "$id" ] || continue
      emit "synthetic:ta:$id" "TRUSTED_ADVISOR_RECOMMENDATION" "global" "trustedadvisor" \
           "issue" "$stage/$status" "$status" \
           "Trusted Advisor: $name
Status: $status (lifecycleStage: $stage)
Pillars: ${pillars:-none}
Affected resources: $errc in error, $warnc warning
Source: ${source:-ta}
This is a standing recommendation, not a dated event -- it stays true until someone acts on it." \
           "[]"
    done
}

# --- Leg 2: pending maintenance (RDS + DocDB share the API shape) -----------------------
# TRAP (measured): the response key is PendingMaintenanceActions, NOT
# PendingMaintenanceActionsDetails. The wrong key returns null rather than erroring, which
# nearly caused the whole finding to be discarded as absent.
# STAMP: CurrentApplyDate, else AutoAppliedAfterDate, else "unscheduled". A null
# AutoAppliedAfterDate means AWS has not forced a date yet -- still schedulable on our
# terms -- and the stamp moving to a real date is precisely the news worth re-flagging.
leg_pending_maintenance() { # leg_pending_maintenance <engine: rds|docdb> <region>
  local engine="$1" region="$2" out
  out="$(MSYS_NO_PATHCONV=1 aws "$engine" describe-pending-maintenance-actions \
           --region "$region" --output json 2>/dev/null)" || return 0
  printf '%s' "$out" | jq -r --arg eng "$engine" '
      .PendingMaintenanceActions[]?
      | (.ResourceIdentifier // "") as $res
      | .PendingMaintenanceActionDetails[]?
      | [ $res, (.Action // ""), (.CurrentApplyDate // ""), (.AutoAppliedAfterDate // ""),
          (.ForcedApplyDate // ""), (.Description // "") ]
      | @tsv' 2>/dev/null | tr -d '\r' \
  | while IFS=$'\t' read -r res action applyd autod forcedd descr; do
      [ -n "$res" ] && [ -n "$action" ] || continue
      local stamp="${applyd:-${autod:-unscheduled}}"
      local short="${res##*:}"
      emit "synthetic:pending:$engine:$res#$action" "PENDING_MAINTENANCE_ACTION" \
           "$region" "$engine" "scheduledChange" "$stamp" "pending" \
           "Pending maintenance on $short ($engine, $region)
Action: $action
Description: ${descr:-none}
Current apply date: ${applyd:-none}
Auto-applied after: ${autod:-none (still schedulable on our terms)}
Forced apply date: ${forcedd:-none}
Invisible to AWS Health. A null auto-apply date means this has not been forced yet -- scheduling it is cheaper than having it applied for us." \
           "$(jq -nc --arg v "$short" '[$v]')"
    done
}

# --- Leg 3: ACM expiry -----------------------------------------------------------------
# Health has NO approaching-expiry event type for IMPORTED certificates (only
# AWS_ACM_RENEWAL_*, which covers certs ACM issued), and this account has zero ACM Health
# events -- so an imported cert expires in complete silence. That silence produced
# PROJ-15335: a production wildcard 52 days out and two prod listeners already serving
# expired certs.
# STAMP: NotAfter. This is the leg where the stamp choice does real work. The rule is "in
# the window AND NotAfter has not moved since we last looked": a NotAfter that moves means
# something is renewing the certificate, which is the definition of not needing an alert.
# Verified 2026-09-21 on the two live imported certs -- *.example-app.com is rotated
# in place by the certbot ECS task and *.<tenant domain> by the hs-production-certificate-sync
# Lambda, so both move and both stay quiet. The two that did NOT move (fcb684e8 for eleven
# months, 3c9dea62 for six weeks) are exactly what this leg exists to catch.
leg_acm() { # leg_acm <region>
  local region="$1" out
  out="$(MSYS_NO_PATHCONV=1 aws acm list-certificates --region "$region" \
           --output json 2>/dev/null)" || return 0
  printf '%s' "$out" | jq -r '
      .CertificateSummaryList[]?
      | [ (.CertificateArn // ""), (.DomainName // ""), (.NotAfter // ""),
          (.Type // ""), (.RenewalEligibility // ""), (.InUse // false | tostring) ]
      | @tsv' 2>/dev/null | tr -d '\r' \
  | while IFS=$'\t' read -r arn domain notafter ctype renew inuse; do
      [ -n "$arn" ] || continue
      [ -n "$notafter" ] || continue
      local exp_epoch days prior first_seen_note
      exp_epoch="$(date -d "$notafter" +%s 2>/dev/null)" || continue
      days=$(( (exp_epoch - today_epoch) / 86400 ))
      [ "$days" -le "$ACM_WINDOW" ] || continue

      # THE RULE, and it is the reverse of the obvious one: alarm when NotAfter has NOT
      # moved. A NotAfter that moved between runs means something renewed the certificate,
      # which is the definition of not needing an alert -- emitting there would re-fire on
      # every rotation, roughly four times a year per cert, and that is how a monitor gets
      # muted. Static-and-inside-the-window is the dangerous state.
      # Verified against the two live imported certs 2026-09-21: *.example-app.com
      # is rotated in place by the certbot ECS task and *.<tenant domain> by the
      # hs-production-certificate-sync Lambda, so both move and both stay silent here. The
      # two that did NOT move -- fcb684e8 for eleven months and 3c9dea62 for six weeks,
      # both serving live production traffic -- are what this leg exists to catch.
      prior="$(awk -F'\t' -v a="synthetic:acm:$arn" '$1==a{print $2; exit}' "$SEEN" 2>/dev/null)"
      if [ -n "$prior" ] && [ "$prior" != "$notafter" ]; then continue; fi
      first_seen_note="NotAfter has not moved since the previous run -- nothing is renewing this."
      [ -n "$prior" ] || first_seen_note="First observation of this certificate, so renewal cannot be judged yet; if NotAfter moves before the next run this will fall silent by itself."

      emit "synthetic:acm:$arn" "ACM_CERTIFICATE_APPROACHING_EXPIRY" "$region" "acm" \
           "issue" "$notafter" "$( [ "$days" -lt 0 ] && echo expired || echo upcoming )" \
           "Certificate $domain expires in $days day(s) -- NotAfter $notafter
ARN: $arn
Type: $ctype, RenewalEligibility: $renew, InUse: $inuse
AWS Health has no approaching-expiry event type for IMPORTED certificates, so nothing else reports this.
$first_seen_note" \
           "$(jq -nc --arg v "$domain" '[$v]')"
    done
}

# --- Leg 4: IAM Access Analyzer --------------------------------------------------------
# Security Hub is not subscribed and GuardDuty, Inspector and Config are all not enabled,
# so Access Analyzer plus Trusted Advisor is very nearly the entire managed
# security-finding capability in this account (measured, PROJ-15336).
# STAMP: status alone. Findings carry updatedAt/analyzedAt, both of which churn on
# re-analysis without the finding changing -- using either would re-flag the whole set on
# every sweep, the exact ELASTICACHE failure mode. status moves only on
# ACTIVE -> RESOLVED/ARCHIVED, which is the only transition worth hearing about.
leg_access_analyzer() { # leg_access_analyzer <region>
  local region="$1" analyzers a
  analyzers="$(MSYS_NO_PATHCONV=1 aws accessanalyzer list-analyzers --region "$region" \
                 --query 'analyzers[?status==`ACTIVE`].arn' --output text 2>/dev/null)" || return 0
  [ -n "$analyzers" ] || return 0
  for a in $analyzers; do
    [ -n "$a" ] || continue
    MSYS_NO_PATHCONV=1 aws accessanalyzer list-findings --region "$region" \
      --analyzer-arn "$a" --filter 'status={eq=["ACTIVE"]}' --output json 2>/dev/null \
    | jq -r '
        .findings[]?
        | [ (.id // ""), (.resource // ""), (.resourceType // ""), (.status // ""),
            (.isPublic // false | tostring), (.principal | tostring),
            ((.action // []) | join(",")) ]
        | @tsv' 2>/dev/null | tr -d '\r' \
    | while IFS=$'\t' read -r id resource rtype status ispublic principal actions; do
        [ -n "$id" ] || continue
        emit "synthetic:accessanalyzer:$id" "ACCESS_ANALYZER_FINDING" "$region" \
             "accessanalyzer" "issue" "$status" "$status" \
             "Access Analyzer: external access to ${resource:-unknown} ($rtype)
Public: $ispublic
Principal: ${principal:-unknown}
Actions: ${actions:-unspecified}
Finding id: $id
Security Hub, GuardDuty, Inspector and Config are all off in this account, so this leg and Trusted Advisor are very nearly the whole managed security-finding surface." \
             "$(jq -nc --arg v "${resource##*:}" '[$v]')"
      done
  done
}

# --- Leg 5: version censuses -----------------------------------------------------------
# Cheap, deterministic end-of-support detection where Health is vague. The Lambda count
# reconciles exactly with Trusted Advisor's deprecated-runtime count, which is a useful
# cross-validation rather than duplication: if the two ever disagree, one of the legs is
# wrong. These are the NEXT extended-support bills, before they start.
# STAMP: the version string itself. Moves only when someone actually upgrades.
DEPRECATED_RUNTIMES='nodejs8.10 nodejs10.x nodejs12.x nodejs14.x nodejs16.x dotnetcore2.1 dotnetcore3.1 dotnet6 python2.7 python3.6 python3.7 python3.8 ruby2.7 go1.x java8 provided'

leg_lambda_runtimes() { # leg_lambda_runtimes <region>
  local region="$1"
  MSYS_NO_PATHCONV=1 aws lambda list-functions --region "$region" \
    --query 'Functions[].[FunctionName,Runtime,FunctionArn]' --output text 2>/dev/null | tr -d '\r' \
  | while IFS=$'\t' read -r fname runtime farn; do
      [ -n "$fname" ] && [ -n "$runtime" ] || continue
      case " $DEPRECATED_RUNTIMES " in *" $runtime "*) ;; *) continue ;; esac
      emit "synthetic:runtime:lambda:$farn" "LAMBDA_DEPRECATED_RUNTIME" "$region" "lambda" \
           "issue" "$runtime" "deprecated" \
           "Lambda $fname runs on deprecated runtime $runtime ($region)
ARN: $farn
Deprecated runtimes stop receiving security patches and eventually block updates and then invocations.
This count should reconcile with Trusted Advisor's deprecated-runtime recommendation; a disagreement means one of the two legs is wrong." \
           "$(jq -nc --arg v "$fname" '[$v]')"
    done
}

leg_db_versions() { # leg_db_versions <engine: rds|docdb> <region>
  local engine="$1" region="$2"
  MSYS_NO_PATHCONV=1 aws "$engine" describe-db-instances --region "$region" \
    --query 'DBInstances[].[DBInstanceIdentifier,Engine,EngineVersion]' --output text 2>/dev/null | tr -d '\r' \
  | while IFS=$'\t' read -r dbid dbengine version; do
      [ -n "$dbid" ] && [ -n "$version" ] || continue
      emit "synthetic:version:$engine:$region:$dbid" "DB_ENGINE_VERSION_CENSUS" "$region" \
           "$dbengine" "accountNotification" "$dbengine $version" "census" \
           "$dbid runs $dbengine $version ($region)
A census row, not an alarm: it exists so an approaching extended-support cutoff is visible BEFORE the bill starts, and it re-surfaces only when the version string changes.
Judge it against the current AWS end-of-standard-support date for $dbengine $version." \
           "$(jq -nc --arg v "$dbid" '[$v]')"
    done
}

# --- run every leg ---------------------------------------------------------------------
leg_trusted_advisor

for r in "${REGIONS[@]}"; do
  r="$(printf '%s' "$r" | tr -d ' \r')"
  [ -n "$r" ] || continue
  # NOT also `leg_pending_maintenance docdb` -- DocDB clusters are RDS-backed and the rds
  # API already returns them. Measured 2026-09-21: running both produced 166 rows of which
  # 83 were exact resource#action duplicates, i.e. every single one, under two different
  # synthetic arns. That would have double-alerted the production DocDB os-upgrade this
  # ticket's acceptance criteria name by way of example.
  leg_pending_maintenance rds "$r"
  leg_acm "$r"
  leg_access_analyzer "$r"
  leg_lambda_runtimes "$r"
  leg_db_versions rds "$r"
done
