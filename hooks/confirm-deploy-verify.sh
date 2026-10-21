#!/usr/bin/env bash
# Usage: confirm-deploy-verify.sh [session_id] [scope]
# Model-invoked (not a hook) ONLY after the user has explicitly said yes to running
# QA deploy verification (verify-qa-deploy.sh / verify-deployment-e2e.sh) THIS session.
# Records it so deploy-verify-confirm-gate.sh stops blocking the launch -- ONE-SHOT,
# consumed once the allowed verify call actually runs (gate's PostToolUse side), so a later
# push in the same session asks again.
# session_id defaults to $CLAUDE_SESSION_ID if not passed.
#
# `scope` is what the user approved verifying: `<repo>:<version>` (version may be empty),
# the same shape the gate derives from the verify command's own arguments. An approval
# recorded WITH a scope only unlocks that scope; a run for a different repo or a different
# build version is denied and names both, so re-verifying a CHANGED artifact goes back to
# the user instead of being re-armed on the strength of the earlier yes (user instruction
# 2026-09-22, after a first verification failed, its cause was fixed, and the same session
# re-armed itself for the redeploy -- same verification in spirit, different artifact).
# Omitting the scope records an unscoped approval, which unlocks the next run whatever it
# is -- that is the pre-2026-09-22 behaviour, kept so an approval given before the
# expected version is known still works.
#
# --consume <session_id> <repo> <version>: called by verify-deployment-e2e.sh as it ENTERS
# Stage 3 (live AWS), removing the first row for that sid scoped "", "<repo>:" or
# "<repo>:<version>". An e2e run that stops earlier (build still IN_PROGRESS, no Octopus
# match) verified nothing and leaves the approval for the rerun (user decision 2026-10-12).
set -u
if [ "${1:-}" = "--consume" ]; then
  csid="${2:-}"; crepo="${3:-}"; cver="${4:-}"
  [ -n "$csid" ] || exit 0
  . "$HOME/.claude/hooks/lib-claude-paths.sh"
  FILE="$(hstate tickets .deploy-verify-approved)"
  [ -f "$FILE" ] || exit 0
  hit=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ "${line%%	*}" = "$csid" ] || continue
    case "$line" in *"	"*) s="${line#*	}" ;; *) s="" ;; esac
    case "$s" in ""|"$crepo:"|"$crepo:$cver") hit="$line"; break ;; esac
  done < "$FILE"
  [ -n "$hit" ] || exit 0
  grep -vxF "$hit" "$FILE" > "$FILE.tmp"   # exits 1 when it empties the file -- mv regardless
  mv "$FILE.tmp" "$FILE"
  exit 0
fi
sid="${1:-${CLAUDE_SESSION_ID:-}}"
scope="${2:-}"
[ -n "$sid" ] || { echo "usage: confirm-deploy-verify.sh <session_id> [scope]" >&2; exit 1; }

. "$HOME/.claude/hooks/lib-claude-paths.sh"
FILE="$(hstate tickets .deploy-verify-approved)"
touch "$FILE"
row="$(printf '%s\t%s' "$sid" "$scope")"
grep -qxF "$row" "$FILE" || printf '%s\n' "$row" >> "$FILE"
if [ -n "$scope" ]; then
  echo "confirmed: deploy verification approved for session $sid, scope $scope (one-shot)"
else
  echo "confirmed: deploy verification approved for session $sid (one-shot, any scope)"
fi
