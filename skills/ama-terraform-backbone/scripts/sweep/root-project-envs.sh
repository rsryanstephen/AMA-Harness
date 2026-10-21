#!/usr/bin/env bash
# Hand-mapped yourproduct-backbone root -> Octopus project; resolve each project's environments (progression) and the latest deployment per env with its Terraform plan line.
set -u
S="${SWEEP_DIR:?set SWEEP_DIR=<work dir>}"
H="X-Octopus-ApiKey: $OCTOPUS_API_KEY"; O=https://yourorg.octopus.app/api/Spaces-1
cat > "$S/root-project.tsv" <<'EOF'
Applications/AMA/Admin	Projects-140
Applications/AMA/ApiAutomation	Projects-141
Applications/AMA/Blog	-
Applications/AMA/CacheUpdate	Projects-143
Applications/AMA/CohortData	Projects-145
Applications/AMA/CohortReportsExport	Projects-146
Applications/AMA/CohortSearch	Projects-148
Applications/AMA/Cohorts	Projects-147
Applications/AMA/Dynamic-Cohorts	Projects-149
Applications/AMA/ElasticCache	Projects-150
Applications/AMA/Export	Projects-151
Applications/AMA/ExportProducer	Projects-153
Applications/AMA/ExporterPlus	Projects-152
Applications/AMA/Feedback	Projects-154
Applications/AMA/FieldTableMapper	Projects-155
Applications/AMA/Infrastructure	Projects-156
Applications/AMA/Manage	Projects-157
Applications/AMA/Notifications	Projects-158
Applications/AMA/OrganisationExports	Projects-159
Applications/AMA/Platform	Projects-160
Applications/AMA/Pricing	-
Applications/AMA/PricingProcessor	Projects-162
Applications/AMA/QueryBuilder	Projects-163
Applications/AMA/RabbitMq	Projects-263
Applications/AMA/Reports	Projects-164
Applications/AMA/ResultsProcessor	Projects-165
Applications/AMA/Search	Projects-166
Applications/AMA/Social	-
Applications/AMA/UiAutomation	Projects-167
Applications/Aggregation-API	Projects-138
Applications/Aggregation-API-Monitor	Projects-139
Applications/CloudMap	Projects-168
Applications/Exporter	-
Applications/Ingress	Projects-169
Applications/Mapping-Tool	Projects-170
Base/Certificates	Projects-601
Base/Database/RDS	Projects-171
Base/Graylog	Projects-173
Base/Network/Route53	-
Base/Repositories	-
Base/Security/IAM	Projects-174
Base/Security/SecurityGroups	-
Base/Storage/S3	Projects-175
Data/Client-SFTP	Projects-176
Data/Embs-Snapshot	-
Load/Elasticsearch	Projects-179
Load/Orchestrator	Projects-181
pricing/adco-api	-
pricing/core-api	-
pricing/market-index-rates	-
pricing/models/adco	-
pricing/service	-
pricing/tweb-api	-
EOF
echo "== project envs + latest deploy plan line" > "$S/root-project-envs.tsv"
printf 'root\tproject\tenv\tlatest_task\tstate\tcompleted\tplan_line\n' > "$S/root-project-envs.tsv"
while IFS=$'\t' read -r root proj; do
  [ "$proj" = "-" ] && { printf '%s\t-\t-\t-\t-\t-\t-\n' "$root" >> "$S/root-project-envs.tsv"; continue; }
  envs=$(curl -sS -H "$H" "$O/projects/$proj/progression" | jq -r '.Environments[].Id' | tr -d '\r' | tr '\n' ' ')
  for e in $envs; do
    dep=$(curl -sS -H "$H" "$O/deployments?projects=$proj&environments=$e&take=1" | tr -d '\r' | jq -r '.Items[0] | "\(.TaskId // "-") \(.Created // "-")"')
    t=${dep%% *}
    if [ "$t" = "-" ] || [ -z "$t" ]; then printf '%s\t%s\t%s\t-\tnever\t-\t-\n' "$root" "$proj" "$e" >> "$S/root-project-envs.tsv"; continue; fi
    ti=$(curl -sS -H "$H" "$O/tasks/$t" | jq -r '"\(.State)\t\(.CompletedTime // "-")"' | tr -d '\r')
    pl=$(curl -sS -H "$H" "$O/tasks/$t/raw" | tr -d '\r' | grep -aoE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy|No changes\. Infrastructure is up-to-date' | sort | uniq -c | sed -E 's/^ +//' | tr '\n' ';')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$root" "$proj" "$e" "$t" "$ti" "${pl:-?}" >> "$S/root-project-envs.tsv"
  done
done < "$S/root-project.tsv"
echo DONE
