#!/usr/bin/env bash
# Regenerates a dispatch manifest from settings.json.
#
#   bash scripts/gen-dispatch-manifest.sh [--event PreToolUse|PostToolUse] [settings.json] > hooks/dispatch-<pre|post>-bash.manifest
#
# Source of truth is every block of that event whose matcher is EXACTLY `Bash|PowerShell`.
# Combined matchers (`mcp__.*__createJiraIssue|Bash`) are deliberately left alone -- they
# also fire for tools this manifest knows nothing about. Default event: PreToolUse
# (dispatch-pre-bash.manifest); `--event PostToolUse` feeds dispatch-post-bash.manifest.
#
# Columns: <timeout>\t<gate.sh>\t<args>
# `args` is `-` when there are none. It is NEVER left empty: bash treats a tab in IFS as
# whitespace-class, so `read -r a b c d` COLLAPSES consecutive tabs and an empty middle
# column silently shifts every later field left. That bug made dispatch.sh read each gate's
# needle into its args slot, leaving the needle empty -> every gate fell back to @ALWAYS and
# ran regardless, which looked like a working dispatcher that saved almost nothing.
set -u
EV="PreToolUse"; S="$HOME/.claude/settings.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --event) EV="${2:?}"; shift 2 ;;
    *) S="$1"; shift ;;
  esac
done

jq -r --arg ev "$EV" '
  .hooks[$ev][]?
  | select((.matcher // "") == "Bash|PowerShell")
  | .hooks[]
  | [ (.timeout // 20 | tostring), .command ] | @tsv
' "$S" \
| tr -d '\r' \
| sed -E 's#\$HOME/\.claude/hooks/##g' \
| sed -E 's#^([0-9]+)\t.*hook-run\.sh" *"([a-z0-9._-]+\.sh)" *#\1\t\2\t#' \
| sed -E 's#2>/dev/null \|\| true##; s#[[:space:]]+$##' \
| awk -F'\t' '!seen[$2 FS $3]++ { a = ($3 == "" ? "-" : $3); printf "%s\t%s\t%s\n", $1, $2, a }'
