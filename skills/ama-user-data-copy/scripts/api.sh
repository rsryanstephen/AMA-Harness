#!/usr/bin/env bash
# api.sh -- one authenticated AMA API call, token read from a cognito-token.sh file.
# Usage: api.sh <qa|staging|production> <token-file> <METHOD> </service/path[?query]> [body-json-file] [extra curl args...]
# Prints the response body; the HTTP status goes to stderr as "HTTP <code>" and is the exit
# code's source: 2xx -> 0, anything else -> 1. Content-Type defaults to plain application/json;
# set API_CT='application/json;v=2.0' for the two reports PUT routes that need the version
# (PUT /report, PUT /report/{id}?name=) -- every unversioned route (user-folder, manage, cohort)
# answers 400 UnsupportedApiVersion to the versioned form (confirmed on QA 2026-10-07).
# The id token rides along as `IDToken` because OrgService reads custom:organization from it.
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }

ENV="${1:?usage: api.sh <env> <token-file> <METHOD> <path> [body-file] [curl args]}"
TOK="${2:?usage: api.sh <env> <token-file> <METHOD> <path> [body-file] [curl args]}"
METHOD="${3:?}"
URLPATH="${4:?}"
BODY="${5:-}"
shift 5 2>/dev/null || shift $#

case "$ENV" in
  qa)         BASE=https://qa.yourapp.example.com ;;
  staging)    BASE=https://staging.yourapp.example.com ;;
  production) BASE=https://example-app.com ;;
  *) echo "bad env: $ENV" >&2; exit 1 ;;
esac
[ -f "$TOK" ] || { echo "api.sh: token file $TOK missing (run cognito-token.sh)" >&2; exit 1; }

# Headers via a file so the bearer token never sits on a command line.
umask 077
HDR="$(mktemp)"; trap 'rm -f "$HDR"' EXIT
{
  printf 'Authorization: Bearer %s\n' "$(jr .AccessToken "$TOK")"
  printf 'IDToken: %s\n' "$(jr .IdToken "$TOK")"
  printf 'Content-Type: %s\n' "${API_CT:-application/json}"
  printf 'Accept: application/json\n'
} > "$HDR"

OUT="$(mktemp)"; trap 'rm -f "$HDR" "$OUT"' EXIT
if [ -n "$BODY" ]; then
  code="$(curl -sS -o "$OUT" -w '%{http_code}' -X "$METHOD" -H "@$HDR" --data-binary "@$BODY" "$@" "$BASE$URLPATH")"
else
  code="$(curl -sS -o "$OUT" -w '%{http_code}' -X "$METHOD" -H "@$HDR" "$@" "$BASE$URLPATH")"
fi
rc=$?
cat "$OUT"
echo "HTTP $code" >&2
[ $rc -eq 0 ] && [[ "$code" =~ ^2 ]]
