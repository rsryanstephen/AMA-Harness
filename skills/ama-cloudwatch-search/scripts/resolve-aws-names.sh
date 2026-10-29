#!/usr/bin/env bash
# Resolve one repo's AWS names in one environment -- by RUNNING IMAGE, not name similarity.
# Usage: resolve-aws-names.sh <env> <repo-folder-or-slug>
# Prints: cluster / service / task-def family / log group / running image, or LAMBDA info.
#
# The three AWS surfaces name the same service three different ways, the -esvc suffix is
# not universal (search is -isvc), exportproducer's log group drops the `ama` infix, and
# `export-cohort`'s service is called `cohorts` -- while `cohortdata` has no ECS service at
# all and is the Lambda `<env>-v1-cohort-data`. The only check that distinguishes these is
# the image the running task actually runs (`product-service-<slug>:2.0.0.<build>`). That
# rule was stated three times in prose; here it is the algorithm.
set -uo pipefail
export MSYS_NO_PATHCONV=1
ENV="${1:?usage: resolve-aws-names.sh <env> <repo>}"
REPO="${2:?usage: resolve-aws-names.sh <env> <repo>}"
CLUSTER="${ENV}-v1-AMA"

# Slug the image would carry. A folder resolves through its origin remote; a slug is itself.
SLUG="$REPO"
if [ -d "$REPO" ] || p="$(bash "$HOME/.claude/hooks/lib-harness-repos.sh" path "$REPO" 2>/dev/null)"; then
  s="$(bash "$HOME/.claude/hooks/lib-harness-repos.sh" slug "${p:-$REPO}" 2>/dev/null)"; [ -n "$s" ] && SLUG="$s"
fi
SLUG="${SLUG#product-service-}"; SLUG="${SLUG#yourproduct-}"

echo "cluster=$CLUSTER  looking for image *product-service-$SLUG:*"
found=0
for svc in $(PYTHONUTF8=1 aws ecs list-services --cluster "$CLUSTER" --max-items 200 2>/dev/null | jq -r '.serviceArns[]' | sed 's|.*/||'); do
  d="$(PYTHONUTF8=1 aws ecs describe-services --cluster "$CLUSTER" --services "$svc" 2>/dev/null | jq -c '.services[0]')"
  td="$(printf '%s' "$d" | jq -r '.taskDefinition')"
  tdj="$(PYTHONUTF8=1 aws ecs describe-task-definition --task-definition "$td" 2>/dev/null | jq -c '.taskDefinition')"
  img="$(printf '%s' "$tdj" | jq -r '.containerDefinitions[0].image')"
  case "$img" in
    *"product-service-$SLUG:"*|*"yourproduct-$SLUG:"*) ;;
    *) continue ;;
  esac
  found=1
  # The image the RUNNING task serves can differ from the registered task def for the whole
  # rollout window -- report both.
  task="$(PYTHONUTF8=1 aws ecs list-tasks --cluster "$CLUSTER" --service-name "$svc" --desired-status RUNNING 2>/dev/null | jq -r '.taskArns[0] // empty')"
  running="$( [ -n "$task" ] && PYTHONUTF8=1 aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" 2>/dev/null | jq -r '.tasks[0].containers[0].image' || echo "(no running task)")"
  printf 'service=%s\nfamily=%s\nlog_group=%s\nregistered_image=%s\nrunning_image=%s\ndesired=%s running=%s rollout=%s\n' \
    "$svc" "$(printf '%s' "$tdj" | jq -r '.family')" \
    "$(printf '%s' "$tdj" | jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-group"] // "(none)"')" \
    "${img##*/}" "${running##*/}" \
    "$(printf '%s' "$d" | jq -r '.desiredCount')" "$(printf '%s' "$d" | jq -r '.runningCount')" "$(printf '%s' "$d" | jq -r '.deployments[0].rolloutState // "-"')"
done

if [ "$found" = "0" ]; then
  # Not an ECS service -- maybe a Lambda (cohortdata -> cohort-data, cacheupdate ones, ...).
  # Compare with dashes removed on both sides: the repo is `cohortdata`, the Lambda is
  # `cohort-data`, and no mechanical rule predicts where the dash goes.
  flat="$(printf '%s' "$SLUG" | tr -d '-' | tr '[:upper:]' '[:lower:]')"
  lam="$(PYTHONUTF8=1 aws lambda list-functions --query "Functions[?starts_with(FunctionName, \`${ENV}-v1-\`)].FunctionName" --output text 2>/dev/null \
    | tr '\t' '\n' | awk -v f="$flat" '{ n=tolower($0); gsub(/-/,"",n); if (index(n, f)) print }' | head -5)"
  if [ -n "$lam" ]; then
    echo "no ECS service runs an image for '$SLUG' in $CLUSTER -- Lambda candidates:"; printf '  %s\n' $lam
    printf '  log group: /aws/lambda/%s\n' $lam
  else
    echo "nothing in $CLUSTER runs an image for '$SLUG', and no ${ENV}-v1-* Lambda matches"; exit 1
  fi
fi
