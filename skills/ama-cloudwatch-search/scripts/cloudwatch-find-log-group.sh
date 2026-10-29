#!/usr/bin/env bash
# Find CloudWatch log groups matching a keyword (repo/service name), across ECS and
# Lambda -- naming isn't uniform (ECS: /aws/ecs/<env>-v1-ama-<repo>, clean and
# consistent; Lambda: ad hoc per function, no reliable pattern), so this searches by
# substring instead of guessing a path.
# Usage: cloudwatch-find-log-group.sh <keyword>
# Prints: <log-group-name>\t<retention-days-or-"never expire">
set -uo pipefail

KEYWORD="${1:?usage: cloudwatch-find-log-group.sh <keyword>}"

# MSYS_NO_PATHCONV=1 is required -- git-bash silently mangles any argument starting
# with "/" (every CloudWatch log group name does) when passed to aws.exe, a native
# Windows exe, not an MSYS program. Confirmed real bug: a perfectly valid
# --log-group-name-prefix value failed AWS's own regex validation because git-bash
# had already rewritten it into a Windows path before aws.exe ever saw it.
MSYS_NO_PATHCONV=1 aws logs describe-log-groups --max-items 2000 2>&1 \
  | jq -r --arg kw "$(printf '%s' "${KEYWORD}" | tr '[:upper:]' '[:lower:]')" '
    .logGroups[]
    | select(.logGroupName | ascii_downcase | contains($kw))
    | "\(.logGroupName)\t\(.retentionInDays // "never expire")"
  '
