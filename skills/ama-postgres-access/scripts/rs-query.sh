#!/usr/bin/env bash
# Run a read-only SQL query against the aggregation Redshift cluster via the AWS
# redshift-data API -- no Docker, no psql, no password (IAM temp credentials).
# See ../SKILL.md "Aggregation DB (Redshift) -- redshift-data, no Docker needed".
#
# Usage: rs-query.sh "select ... limit 20"          # defaults: qa user
#        RS_DB_USER=ama_staging rs-query.sh "..."
# Output: TSV, one line per row. NULLs print as the literal <NULL>.

set -euo pipefail

sql="${1:?usage: rs-query.sh \"<sql>\"}"

lib="$HOME/.claude/hooks/lib-harness-repos.sh"
# shellcheck source=/dev/null
. "$lib"

region="$(hr_config_required '.aws.region')" || exit 1
cluster="$(hr_config '.aws.redshiftClusterId' 'your-redshift-cluster')"
database="$(hr_config '.aws.redshiftDatabase' 'dev')"
db_user="${RS_DB_USER:-ama_qa}"

# aws-cli (Python) mangles non-ASCII result values (e.g. an en-dash inside a Redshift
# enum value) to replacement bytes on Windows without this -- same fix as
# ama-graylog-search's CACHE-UPDATE-DEBUGGING.md applies to `aws logs`.
export PYTHONUTF8=1

id="$(aws redshift-data execute-statement --region "$region" \
  --cluster-identifier "$cluster" --database "$database" --db-user "$db_user" \
  --sql "$sql" --query 'Id' --output text)"

# Poll. Statements here are interactive-scale; 120s is generous for a metadata read and
# still finishes a group-by over the ~155M-row fact table.
for _ in $(seq 1 120); do
  status="$(aws redshift-data describe-statement --region "$region" --id "$id" \
    --query 'Status' --output text)"
  case "$status" in
    FINISHED) break ;;
    FAILED|ABORTED)
      aws redshift-data describe-statement --region "$region" --id "$id" \
        --query 'Error' --output text >&2
      exit 1 ;;
  esac
  sleep 1
done

if [ "${status:-}" != "FINISHED" ]; then
  echo "rs-query.sh: statement $id still $status after 120s -- rerun with a narrower query" >&2
  exit 1
fi

# A statement with no result set (DDL, or a query returning nothing) has no ResultSet --
# treat that as success with no output rather than an error.
# The trailing `sed 's/\r$//'` is NOT optional: this environment's jq (1.5rc1, Windows)
# emits CRLF on `-r` output -- same bug lib-harness-repos.sh fixes centrally in `_jqr()`.
# Without it, a caller that feeds this output back into a query gets `table_name='foo\r'`,
# which matches nothing and returns zero rows with exit 0 -- a silent wrong answer, not an
# error. Confirmed real: it broke AGGREGATION-DB.md's across-the-set field search.
aws redshift-data get-statement-result --region "$region" --id "$id" 2>/dev/null \
  | jq -r '.Records // [] | .[] | map(
      if .isNull == true then "<NULL>"
      elif has("stringValue") then .stringValue
      elif has("longValue") then (.longValue|tostring)
      elif has("doubleValue") then (.doubleValue|tostring)
      elif has("booleanValue") then (.booleanValue|tostring)
      else "?" end) | @tsv' \
  | sed 's/\r$//'
