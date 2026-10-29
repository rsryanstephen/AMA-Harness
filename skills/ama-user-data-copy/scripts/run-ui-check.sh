#!/usr/bin/env bash
# run-ui-check.sh -- ui-check.mjs as a harness test user, with the exporterplus dev server
# (proxying to the env) started and torn down around it by ama-ui-verify's with-dev-server.sh.
# Usage: run-ui-check.sh <manifest.json> <target|source> [out-dir]
# The user is the manifest's target (or source) and must be a harness test user -- its password
# comes from the env var named in ~/.claude/.ama-ui-credentials.json. Real accounts: SKIP.
# Screenshots land in out-dir (default: next to the manifest, <manifest>.ui/).
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
M="${1:?usage: run-ui-check.sh <manifest.json> <target|source> [out-dir]}"; ROLE="${2:?target|source}"
OUT="${3:-${M%.json}.ui}"
ENV="$(jr .env "$M")"
U="$(jr ".${ROLE/target/to}.username" "$M")"; [ "$ROLE" = source ] && U="$(jr .from.username "$M")"
CREDS="$HOME/.claude/.ama-ui-credentials.json"
jq -e --arg e "$ENV" --arg u "$U" '.users[$e] | to_entries[] | select(.value==$u)' "$CREDS" >/dev/null 2>&1 \
  || { echo "SKIP  ui-check $ROLE $U: not a harness test user (no password); use the admin direct-URL open"; exit 0; }
PW_VAR="$(jr '.passwordEnvVar // "claude_ama_pw"' "$CREDS")"
[ -n "${!PW_VAR:-}" ] || { echo "run-ui-check.sh: $PW_VAR not set" >&2; exit 1; }
case "$ENV" in
  qa) PROXY=proxy.config.qa-ecs.json; CONF=localqa ;;
  staging) PROXY=proxy.config.staging-ecs.json; CONF=localstaging ;;
  production) PROXY=proxy.config.prod-ecs.json; CONF=localprod ;;
  *) echo "bad env $ENV" >&2; exit 1 ;;
esac
EP="${AMA_EXPORTERPLUS_DIR:-$HOME/Repos/AMA_APP/exporterplus}"
PORT="${AMA_UI_PORT:-4210}"
export AMA_UI_USERNAME="$U" AMA_UI_PASSWORD="${!PW_VAR}" AMA_UI_BASE="http://localhost:$PORT"
mkdir -p "$OUT"
bash "$HOME/.claude/skills/ama-ui-verify/scripts/with-dev-server.sh" --port "$PORT" --cwd "$EP" --timeout 400 \
  --serve "npx ng serve --proxy-config $PROXY --configuration $CONF --port $PORT --live-reload=false" \
  -- node "$HERE/ui-check.mjs" "$M" "$ROLE" "$OUT"
rc=$?
echo "screenshots: $OUT" >&2
exit $rc
