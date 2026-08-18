#!/usr/bin/env bash
# Appends missing template sections to an EXISTING ticket description, without touching
# what's already there. Direct v3 ADF read-modify-write -- NOT the v2 wiki-markup route
# jira-create-issue.sh uses, deliberately: a wiki-markup round-trip on a description that
# already contains media/table/inlineCard/codeBlock nodes renders them lossily, then
# writes the lossy rendering back (same class of bug ama-confluence-api documents for
# Confluence HTML writes dropping media nested in an <li>). This script only ever pushes
# NEW nodes onto the end of the existing ADF doc -- every pre-existing node is untouched.
#
# Payload file shape: {"sections": [{"heading": "Acceptance criteria", "bullets": ["...", "..."]}]}
# Usage: jira-append-description.sh <ticket-key>
set -uo pipefail

. "$HOME/.claude/hooks/lib-harness-repos.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1

key="${1:?usage: jira-append-description.sh <ticket-key>}"

PAYLOAD_FILE="$HOME/.claude/.jira-write-payload.json"
if [ ! -f "$PAYLOAD_FILE" ]; then
  echo "jira-append-description.sh: $PAYLOAD_FILE not found -- write the payload there first (Write tool, never shell)" >&2
  exit 1
fi
if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

# Fetch fresh, right before writing -- doubles as the concurrent-edit guard.
GET_FILE="$(mktemp)"
getstatus="$(curl -s -w '%{http_code}' -o "$GET_FILE" -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  "https://${HOST}/rest/api/3/issue/${key}?fields=description")"
if [ "$getstatus" != "200" ]; then
  printf 'jira-append-description.sh: GET HTTP %s for %s\n' "$getstatus" "$key" >&2
  cat "$GET_FILE" >&2
  rm -f "$GET_FILE"
  exit 1
fi

# Extracted doc + existing-text go to their OWN temp files, never a command-line
# argument (--arg/--argjson) -- this jq build mangles multi-byte UTF-8 passed that
# way (confirmed live: a curly apostrophe in an existing description became a literal
# "?" after a --argjson round-trip). Same class of corruption ama-bitbucket-api/SKILL.md
# already documents for shell args generally -- the fixed-payload-file rule these
# scripts follow exists for exactly this, and it applies to EVERY dynamic value here,
# not just the caller's payload.
DOC_FILE="$(mktemp)"
jq -c '.fields.description // {type:"doc",version:1,content:[]}' "$GET_FILE" > "$DOC_FILE"
EXISTING_FILE="$(mktemp)"
jq -c '{text: ([.fields.description // {} | .. | objects | select(.type=="text") | .text] | join(" "))}' "$GET_FILE" > "$EXISTING_FILE"
rm -f "$GET_FILE"

BODY_FILE="$(mktemp)"
jq -c -s '
  .[0] as $doc | .[1] as $existing | .[2] as $payload |
  ($existing.text | ascii_downcase) as $ex |
  ($payload.sections // []) as $sections |
  ($sections | map(select(. as $s | ($ex | test($s.heading; "i")) | not))) as $new |
  if ($new | length) == 0 then null else
    ($new | map(
      [
        {type:"heading", attrs:{level:3}, content:[{type:"text", text:.heading}]},
        {type:"bulletList", content: (.bullets | map(
          {type:"listItem", content:[{type:"paragraph", content:[{type:"text", text:.}]}]}
        ))}
      ]
    ) | flatten) as $newnodes |
    {fields: {description: ($doc + {content: ($doc.content + $newnodes)})}}
  end
' "$DOC_FILE" "$EXISTING_FILE" "$PAYLOAD_FILE" > "$BODY_FILE"
rm -f "$DOC_FILE" "$EXISTING_FILE"

if [ "$(cat "$BODY_FILE")" = "null" ]; then
  echo "SKIP: ${key} already has all requested sections"
  rm -f "$PAYLOAD_FILE" "$BODY_FILE"
  exit 0
fi

# -d @file, never -d "$var" -- a bash-variable-held body corrupts crossing the
# MSYS->Win32 boundary into curl.exe (confirmed live: identical JSON via -d @file got
# 204, the same content via -d "$body" 400'd with "error parsing JSON").
resp="$(curl -s -w '\n%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -X PUT -H "Content-Type: application/json" -d "@$BODY_FILE" \
  "https://${HOST}/rest/api/3/issue/${key}")"
status="${resp##*$'\n'}"
respbody="${resp%$'\n'*}"

rm -f "$BODY_FILE"

if [ "$status" != "204" ]; then
  printf 'jira-append-description.sh: PUT HTTP %s for %s\n%s\n' "$status" "$key" "$respbody" >&2
  exit 1
fi

rm -f "$PAYLOAD_FILE"
echo "OK: ${key} description updated"
