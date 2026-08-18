#!/usr/bin/env bash
# Usage: confirm-deploy-verify.sh [session_id]
# Model-invoked (not a hook) ONLY after the user has explicitly said yes to running
# QA deploy verification (verify-qa-deploy.sh / verify-deployment-e2e.sh) THIS session.
# Records it so deploy-verify-confirm-gate.sh stops blocking the launch -- ONE-SHOT,
# consumed by the gate on first allow, so a later push in the same session asks again.
# session_id defaults to $CLAUDE_SESSION_ID if not passed.
set -u
sid="${1:-${CLAUDE_SESSION_ID:-}}"
[ -n "$sid" ] || { echo "usage: confirm-deploy-verify.sh <session_id>" >&2; exit 1; }

FILE="$HOME/.claude/.deploy-verify-approved"
touch "$FILE"
grep -qxF "$sid" "$FILE" || printf '%s\n' "$sid" >> "$FILE"
echo "confirmed: deploy verification approved for session $sid (one-shot)"
