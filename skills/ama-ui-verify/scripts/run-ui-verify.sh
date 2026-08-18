#!/usr/bin/env bash
# Entry point: resolves the right test-user username for <env>/<tier> from the gitignored
# creds file. Password comes from the file's own "password" field if set, else its named
# env var -- both are gitignored/local-only, never echoed. Ensures Playwright's chromium is
# installed, runs verify-ui.mjs.
#
# Usage: run-ui-verify.sh <env: qa|staging|production> <tier: 3500|1800> <url> <screenshot-out-path> [css-selector] [css-property]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$HOME/.claude/.ama-ui-credentials.json"

ENV_NAME="${1:?usage: run-ui-verify.sh <env: qa|staging|production> <tier: 3500|1800> <url> <screenshot-out-path> [css-selector] [css-property]}"
TIER="${2:?usage: run-ui-verify.sh <env> <tier> <url> <screenshot-out-path> [css-selector] [css-property]}"
shift 2

[ -f "$CREDS_FILE" ] || {
  echo "missing $CREDS_FILE -- see ama-ui-verify SKILL.md for the format" >&2
  exit 1
}

AMA_UI_USERNAME="$(jq -r --arg env "$ENV_NAME" --arg tier "tier${TIER}" '.users[$env][$tier] // empty' "$CREDS_FILE")"
[ -n "$AMA_UI_USERNAME" ] || {
  echo "no user configured for env=$ENV_NAME tier=$TIER in $CREDS_FILE" >&2
  exit 1
}
export AMA_UI_USERNAME

FILE_PW="$(jq -r '.password // empty' "$CREDS_FILE")"
if [ -n "$FILE_PW" ]; then
  export AMA_UI_PASSWORD="$FILE_PW"
else
  PW_VAR="$(jq -r '.passwordEnvVar' "$CREDS_FILE")"
  export AMA_UI_PASSWORD="${!PW_VAR:?password env var \$$PW_VAR (named in $CREDS_FILE) is not set, and no \"password\" field in the file either}"
fi

if [ ! -d "$SCRIPT_DIR/node_modules/playwright" ]; then
  (cd "$SCRIPT_DIR" && npm install >/dev/null)
fi
if [ ! -d "$HOME/AppData/Local/ms-playwright" ] && [ -z "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
  (cd "$SCRIPT_DIR" && npx playwright install chromium)
fi

node "$SCRIPT_DIR/verify-ui.mjs" "$@"
