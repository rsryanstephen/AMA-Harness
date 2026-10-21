#!/usr/bin/env bash
# PROJ-15653: create-or-update the AWS half of the QA/Staging sleep schedule --
# IAM roles, the shutdown Lambda (../aws/shutdown_lambda.py) and an EventBridge Scheduler
# schedule firing it nightly at 22:00 Africa/Johannesburg. Idempotent; this script IS the
# infra definition, re-run it after editing the Lambda.
#   bash deploy-shutdown-schedule.sh            # deploy/update
#   bash deploy-shutdown-schedule.sh --disable  # pause the nightly shutdown
#   bash deploy-shutdown-schedule.sh --enable
set -euo pipefail
REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text | tr -d '\r')
NAME=ama-qa-staging-nightly-shutdown
LAMBDA_ROLE=$NAME-lambda-role
SCHED_ROLE=$NAME-scheduler-role
CRON='cron(0 22 * * ? *)'
TZ_NAME=Africa/Johannesburg
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# aws.exe is native Windows: hand it Windows paths, not /tmp/... MSYS paths.
w() { cygpath -w "$1"; }

lambda_arn="arn:aws:lambda:$REGION:$ACCOUNT:function:$NAME"
# Retries capped at 1h: a shutdown that finally lands at 08:00 would kill a working day.
TARGET="{\"Arn\":\"$lambda_arn\",\"RoleArn\":\"arn:aws:iam::$ACCOUNT:role/$SCHED_ROLE\",\"RetryPolicy\":{\"MaximumEventAgeInSeconds\":3600,\"MaximumRetryAttempts\":3}}"

schedule_state() {
  aws scheduler update-schedule --region "$REGION" --name "$NAME" \
    --schedule-expression "$CRON" --schedule-expression-timezone "$TZ_NAME" \
    --flexible-time-window Mode=OFF --state "$1" \
    --target "$TARGET" >/dev/null
  echo "schedule $NAME -> $1"
}
case "${1:-}" in
  --disable) schedule_state DISABLED; exit 0 ;;
  --enable)  schedule_state ENABLED;  exit 0 ;;
esac

ensure_role() { # name trust-principal policy-json
  if ! aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"%s"},"Action":"sts:AssumeRole"}]}' "$2" > "$WORK/trust.json"
    aws iam create-role --role-name "$1" --assume-role-policy-document "file://$(w "$WORK/trust.json")" >/dev/null
    echo "created role $1"; NEW_ROLE=1
  fi
  printf '%s' "$3" > "$WORK/policy.json"
  aws iam put-role-policy --role-name "$1" --policy-name "$1-inline" --policy-document "file://$(w "$WORK/policy.json")"
}

NEW_ROLE=0
ensure_role "$LAMBDA_ROLE" lambda.amazonaws.com "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["ecs:ListServices"],"Resource":"*"},
 {"Effect":"Allow","Action":["ecs:DescribeServices","ecs:UpdateService"],"Resource":[
   "arn:aws:ecs:$REGION:$ACCOUNT:service/qa-v1-AMA/*","arn:aws:ecs:$REGION:$ACCOUNT:service/staging-v1-AMA/*"]},
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"arn:aws:logs:$REGION:$ACCOUNT:*"}]}
JSON
)"
ensure_role "$SCHED_ROLE" scheduler.amazonaws.com \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"$lambda_arn\"}]}"
# A brand-new role is not assumable by Lambda for ~10s (IAM eventual consistency).
[ "$NEW_ROLE" = 1 ] && sleep 15

python -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.write(sys.argv[2],'shutdown_lambda.py')" \
  "$(w "$WORK/fn.zip")" "$(w "$DIR/../aws/shutdown_lambda.py")"

if aws lambda get-function --function-name "$NAME" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$NAME" --region "$REGION" \
    --zip-file "fileb://$(w "$WORK/fn.zip")" >/dev/null
  echo "updated lambda $NAME"
else
  aws lambda create-function --function-name "$NAME" --region "$REGION" \
    --runtime python3.12 --handler shutdown_lambda.handler --timeout 120 \
    --role "arn:aws:iam::$ACCOUNT:role/$LAMBDA_ROLE" \
    --description "PROJ-15653 nightly QA/Staging ECS scale-to-0" \
    --zip-file "fileb://$(w "$WORK/fn.zip")" >/dev/null
  echo "created lambda $NAME"
fi

if aws scheduler get-schedule --name "$NAME" --region "$REGION" >/dev/null 2>&1; then
  schedule_state ENABLED
else
  aws scheduler create-schedule --region "$REGION" --name "$NAME" \
    --description "PROJ-15653 scale QA+Staging ECS to 0 nightly" \
    --schedule-expression "$CRON" --schedule-expression-timezone "$TZ_NAME" \
    --flexible-time-window Mode=OFF \
    --target "$TARGET" >/dev/null
  echo "created schedule $NAME ($CRON $TZ_NAME)"
fi
