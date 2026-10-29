#!/usr/bin/env bash
# Attach a rule to the suppression pipeline's Stage 0. Idempotent -- no-op if the rule
# title is already referenced. <harnessEpicKey>: creating a rule does NOT run it; the
# pipeline's own `source` field lists rule titles under `stage 0 match either ... end`,
# and that list is what actually decides what fires. See PIPELINE-RULES.md.
#
# Usage: graylog-pipeline-attach-rule.sh "<rule title>"
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
BASE_URL="$(hr_config_required '.graylog.host')" || exit 1
PIPELINE_ID="$(hr_config_required '.graylog.suppressPipelineId')" || exit 1

title="${1:?usage: graylog-pipeline-attach-rule.sh \"<rule title>\"}"

if [ -z "${GRAYLOG_PAT:-}" ]; then
  echo "GRAYLOG_PAT not set" >&2
  exit 1
fi

AUTH=(-u "${GRAYLOG_PAT}:token")
JSONHDR=(-H "Content-Type: application/json" -H "Accept: application/json" -H "X-Requested-By: claude-harness")

cur="$(curl -sS -m 30 "${AUTH[@]}" -H "Accept: application/json" \
  "${BASE_URL}/api/system/pipelines/pipeline/${PIPELINE_ID}")" || { echo "GET pipeline failed" >&2; exit 1; }
p_title="$(printf '%s' "$cur" | jq -r '.title')"
src="$(printf '%s' "$cur" | jq -r '.source')"

esc_title="$(printf '%s' "$title" | sed 's/"/\\"/g')"
if printf '%s' "$src" | grep -qF "rule \"${esc_title}\""; then
  echo "OK: '${title}' already attached to pipeline '${p_title}' (${PIPELINE_ID}) -- nothing to do."
  exit 0
fi

BACKUP_DIR="$(hstate tickets .graylog-rule-backups)"
mkdir -p "$BACKUP_DIR"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_FILE="$BACKUP_DIR/pipeline-${PIPELINE_ID}-${ts}.json"
printf '%s' "$cur" | jq '{title,description,source}' > "$BACKUP_FILE"
[ -s "$BACKUP_FILE" ] || { echo "backup write failed, aborting before any write" >&2; exit 1; }
echo "backup: $BACKUP_FILE"

# Insert the new `rule "..."` line right before the final `end` line.
new_src="$(printf '%s\n' "$src" | awk -v t="$esc_title" '
  { lines[NR] = $0 }
  END {
    last_end = 0
    for (i = 1; i <= NR; i++) if (lines[i] == "end") last_end = i
    for (i = 1; i <= NR; i++) {
      if (i == last_end) printf "rule \"%s\"\n", t
      print lines[i]
    }
  }')"

BODY_FILE="$(mktemp)"
jq -n --arg t "$p_title" --arg d "$(printf '%s' "$cur" | jq -r '.description // ""')" --arg s "$new_src" \
  '{title:$t, description:$d, source:$s}' > "$BODY_FILE"

resp="$(curl -sS -w '\n%{http_code}' "${AUTH[@]}" "${JSONHDR[@]}" \
  -X PUT -d "@$BODY_FILE" "${BASE_URL}/api/system/pipelines/pipeline/${PIPELINE_ID}")"
rm -f "$BODY_FILE"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"

if [ "$status" != "200" ]; then
  printf 'graylog-pipeline-attach-rule.sh: HTTP %s writing pipeline\n%s\n' "$status" "$respbody" >&2
  exit 1
fi

verify="$(curl -sS -m 30 "${AUTH[@]}" -H "Accept: application/json" \
  "${BASE_URL}/api/system/pipelines/pipeline/${PIPELINE_ID}")"
if ! printf '%s' "$verify" | jq -r '.source' | grep -qF "rule \"${esc_title}\""; then
  echo "graylog-pipeline-attach-rule.sh: WARNING -- rule not found in pipeline source after write. Manual check needed." >&2
  exit 1
fi

echo "OK: '${title}' attached to pipeline '${p_title}' (${PIPELINE_ID}) and verified."
