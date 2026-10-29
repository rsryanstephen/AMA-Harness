#!/usr/bin/env bash
# Scout 2: disk, Octopus environments, all tfstate objects in every terraform S3 bucket, and the pipeline's root->project mapping.
set -u
S="${SWEEP_DIR:?set SWEEP_DIR=<work dir>}"
W=${BACKBONE_WORKTREE:?set BACKBONE_WORKTREE=<checkout to plan>}
H="X-Octopus-ApiKey: $OCTOPUS_API_KEY"; O=https://yourorg.octopus.app/api/Spaces-1
echo "== disk C:"; df -h C: | tail -n 1
echo "== docker"; docker version --format '{{.Server.Version}}' 2>&1 | head -n 1
echo "== environments"; curl -sS -H "$H" "$O/environments/all" | tr -d '\r' | jq -r '.[] | "\(.Id) \(.Name)"'
echo "== terraform buckets"
aws s3api list-buckets --query 'Buckets[?contains(Name, `terraform`)].Name' --output text | tr -d '\r' | tr '\t' '\n' > "$S/sweep-buckets.txt"; cat "$S/sweep-buckets.txt"
echo "== tfstate objects"
: > "$S/sweep-states.txt"
while read -r b; do
  [ -n "$b" ] || continue
  aws s3api list-objects-v2 --bucket "$b" --query 'Contents[?ends_with(Key, `.tfstate`)].[Key,Size,LastModified]' --output text 2>/dev/null | tr -d '\r' | awk -v b="$b" '{print b"\t"$1"\t"$2"\t"$3}' >> "$S/sweep-states.txt"
done < "$S/sweep-buckets.txt"
wc -l < "$S/sweep-states.txt"; cut -f1,2,4 "$S/sweep-states.txt" | sed -E 's/T[0-9:.]+Z?$//' | column -t -s $'\t' | head -n 120
echo "== build.sh mapping"
grep -n -E 'Projects-|grep -q|OCTOPUS_PROJECT|project=' "$W/_build/build.sh" | head -n 40
