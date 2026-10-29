#!/usr/bin/env bash
# Attach a local file to a Jira issue (v2 multipart POST). Prints the attachment filename
# Jira stored, which a wiki-markup comment then embeds as !<filename>|thumbnail!.
# Usage: jira-add-attachment.sh <ticket-key> <file-path>
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

key="${1:?usage: jira-add-attachment.sh <ticket-key> <file-path>}"
file="${2:?usage: jira-add-attachment.sh <ticket-key> <file-path>}"
[ -f "$file" ] || { echo "jira-add-attachment.sh: $file not found" >&2; exit 1; }
[ -n "${ATLASSIAN_API_TOKEN:-}" ] || { echo "ATLASSIAN_API_TOKEN not set" >&2; exit 1; }

# X-Atlassian-Token: no-check is mandatory on this endpoint (XSRF guard) -- 403 without it.
resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X POST -H "X-Atlassian-Token: no-check" -F "file=@${file}" \
  "https://${HOST}/rest/api/2/issue/${key}/attachments")"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"

if [ "$status" != "200" ]; then
  printf 'jira-add-attachment.sh: HTTP %s for %s\n%s\n' "$status" "$key" "$respbody" >&2
  exit 1
fi

printf '%s' "$respbody" | jq -r '.[].filename' | tr -d '\r'
