#!/usr/bin/env bash
# Read-only: desired/running count per ECS service in <env>-v1-AMA (same cluster/region as scale-env.sh).
#   bash env-counts.sh qa | bash env-counts.sh staging
set -uo pipefail
ENV=${1:?usage: env-counts.sh <qa|staging>}
case "$ENV" in qa|staging) ;; *) echo "refusing env '$ENV' (qa|staging only)" >&2; exit 2 ;; esac
CLUSTER="$ENV-v1-AMA"
REGION=us-east-1

arns=$(aws ecs list-services --cluster "$CLUSTER" --region "$REGION" --query 'serviceArns[]' --output text | tr -d '\r') || exit 1
[ -n "$arns" ] || { echo "no services in $CLUSTER"; exit 0; }
# describe-services takes <=10 names per call
set -- $arns
while [ $# -gt 0 ]; do
  batch=("${@:1:10}"); shift $(( $# < 10 ? $# : 10 ))
  aws ecs describe-services --cluster "$CLUSTER" --region "$REGION" --services "${batch[@]}" \
    --query 'services[].[serviceName,desiredCount,runningCount]' --output text | tr -d '\r' \
    | awk '{printf "%-60s desired=%s running=%s\n",$1,$2,$3}'
done
