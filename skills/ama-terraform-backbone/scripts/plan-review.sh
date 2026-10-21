#!/usr/bin/env bash
# Review a Terraform plan BEFORE recommending its approval (user rule 2026-10-15).
#   plan-review.sh <ServerTasks-N> [<previous ServerTasks-N>]   -- plan from an Octopus task log
#   plan-review.sh --file <plan.txt> [<previous plan.txt>]       -- a local plan (terraform plan -no-color output)
# Mechanical half: plan-review.py (blockers, real changes with list-shift noise removed, diff vs a
# previous plan). Judgment half: SKILL.md "Before recommending a plan approval". Stamps
# harness-state/octopus/plan-reviewed/<id> so octopus-approval-watch-check.sh (Stop) can tell a
# reviewed plan from an unreviewed one. Read-only.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"
here="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$HOME/.claude/harness-config.json"
SERVER="$(jq -r '.octopus.serverUrl // "https://yourorg.octopus.app"' "$CONFIG" 2>/dev/null | tr -d '\r')"
SPACE="$(jq -r '.octopus.spaceId // "Spaces-1"' "$CONFIG" 2>/dev/null | tr -d '\r')"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fetch() { curl -sS --max-time 60 -H "X-Octopus-ApiKey: ${OCTOPUS_API_KEY:?OCTOPUS_API_KEY unset}" "$SERVER/api/$SPACE/tasks/$1/raw" | tr -d '\r' > "$2"; }
if [ "${1:-}" = --file ]; then
  cur="${2:?plan file}"; prev="${3:-}"; id="file-$(basename "$cur")"
else
  id="${1:?ServerTasks-N}"; fetch "$id" "$tmp/cur.txt"; cur="$tmp/cur.txt"; prev=""
  [ -n "${2:-}" ] && { fetch "$2" "$tmp/prev.txt"; prev="$tmp/prev.txt"; }
  st="$(curl -sS --max-time 30 -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$SERVER/api/$SPACE/tasks/$id" | tr -d '\r' | jq -r '"\(.Description) | state=\(.State) awaitingApproval=\(.HasPendingInterruptions)"')"
  echo "$id: $st"
fi
python "$here/plan-review.py" "$cur" ${prev:+"$prev"}; rc=$?
[ "$rc" = 0 ] && { d="$(dirname "$(hstate octopus plan-reviewed/.keep)")"; date -u +%FT%TZ > "$d/$id"; }
echo "Now do the judgment checks (SKILL.md 'Before recommending a plan approval') before telling the user to approve."
exit "$rc"
