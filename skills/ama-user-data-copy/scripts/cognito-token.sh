#!/usr/bin/env bash
# cognito-token.sh -- get an AMA access/id token for a harness test user, without a browser.
# Usage: cognito-token.sh <qa|staging|production> <username> <out-file>
#   password: env var named by ~/.claude/.ama-ui-credentials.json `.passwordEnvVar` (claude_ama_pw)
#   out-file: written mode 0600 as JSON {AccessToken, IdToken, ExpiresIn}; never printed.
# The exporterplus app client allows USER_PASSWORD_AUTH and has no secret (confirmed on
# HS_Exporter_Qa 2026-10-07), so this is the same login the SPA performs, minus SRP.
# Callers read the token from the file; nothing here echoes it (the chat log is a git repo).
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }

ENV="${1:?usage: cognito-token.sh <qa|staging|production> <username> <out-file>}"
USERNAME="${2:?usage: cognito-token.sh <env> <username> <out-file>}"
OUT="${3:?usage: cognito-token.sh <env> <username> <out-file>}"
REGION=us-east-1

# Pool + the SPA's own app client (userPoolWebClientId in exporterplus's config.local<env>.json,
# read 2026-10-07). Production's pool has TWO clients (HS_Exporter_Production is the SPA's;
# HS_Exporter_Prod is something else) -- never pick "the first one listed".
case "$ENV" in
  qa)         POOL=us-east-1_EZPzT4PvW; CLIENT=6mritthc3q2fd08ejgdpmi3tvt ;;
  staging)    POOL=us-east-1_mAGKqTZ5f; CLIENT=4lq7b6k2p1h69ilricsfpnfi2g ;;
  production) POOL=us-east-1_lTBs66UDQ; CLIENT=39g73nkq8djkjvlkrso4retoj2 ;;
  *) echo "bad env: $ENV" >&2; exit 1 ;;
esac

CREDS="$HOME/.claude/.ama-ui-credentials.json"
PW_VAR="$(jr '.passwordEnvVar // "claude_ama_pw"' "$CREDS" 2>/dev/null || echo claude_ama_pw)"
PW="${!PW_VAR:-}"
[ -n "$PW" ] || { echo "cognito-token.sh: password env var $PW_VAR is not set" >&2; exit 1; }

umask 077
# Parameters go through a temp JSON file so the password never appears on a command line.
PARAMS="$(mktemp)"; trap 'rm -f "$PARAMS"' EXIT
jq -n --arg u "$USERNAME" --arg p "$PW" '{USERNAME:$u, PASSWORD:$p}' > "$PARAMS"
unset PW

aws cognito-idp initiate-auth --region "$REGION" --client-id "$CLIENT" \
  --auth-flow USER_PASSWORD_AUTH --auth-parameters "file://$(cygpath -w "$PARAMS" 2>/dev/null || printf '%s' "$PARAMS")" \
  --query 'AuthenticationResult.{AccessToken:AccessToken,IdToken:IdToken,ExpiresIn:ExpiresIn}' --output json > "$OUT"
rc=$?
if [ $rc -ne 0 ] || ! jq -e '.AccessToken' "$OUT" >/dev/null 2>&1; then
  echo "cognito-token.sh: auth failed for $USERNAME on $ENV (rc=$rc)" >&2
  rm -f "$OUT"; exit 1
fi
echo "token for $USERNAME ($ENV) -> $OUT (expires in $(jr .ExpiresIn "$OUT")s)" >&2
