#!/usr/bin/env bash
# Rewires settings.json's `Bash|PowerShell` blocks of one event to the single dispatcher.
#
#   bash scripts/wire-dispatch.sh                         # dry run, PreToolUse
#   bash scripts/wire-dispatch.sh --event PostToolUse     # dry run, PostToolUse
#   bash scripts/wire-dispatch.sh [--event E] --apply     # writes settings.json (backup kept)
#   bash scripts/wire-dispatch.sh [--event E] --template  # target settings.template.json
#
# Replaces every block of that event whose matcher is EXACTLY `Bash|PowerShell` with ONE
# block containing one command: dispatch.sh + that event's manifest. Combined matchers
# (`mcp__.*__createJiraIssue|Bash`) are untouched -- they fire for other tools too.
#
# The dispatcher's own timeout is generous because it now covers a whole block; each gate
# still gets its per-gate timeout INSIDE dispatch.sh, so one slow gate cannot fail the rest
# of the block open. Wiring a chain-wide timeout with no per-gate timeouts would recreate
# the "gate silently not enforced" class in GATES-AND-HOOKS.md, for every gate at once.
set -u

H="$(cd "$(dirname "$0")/.." && pwd)"
S="$HOME/.claude/settings.json"
APPLY=0; EV="PreToolUse"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --event) EV="${2:?}"; shift 2 ;;
    --template) S="$H/settings.template.json"; shift ;;   # the shipped copy new installs start from
    *) S="$1"; shift ;;
  esac
done
[ -f "$S" ] || { echo "no settings file at $S" >&2; exit 1; }
case "$EV" in PreToolUse) short=pre ;; PostToolUse) short=post ;; *) echo "unsupported event $EV" >&2; exit 1 ;; esac
MANIFEST="$H/hooks/dispatch-$short-bash.manifest"
[ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST -- run scripts/gen-dispatch-manifest.sh --event $EV first" >&2; exit 1; }
echo "target: $S  event: $EV"

CMD="bash \"\$HOME/.claude/hooks/dispatch.sh\" \"\$HOME/.claude/hooks/dispatch-$short-bash.manifest\""

before="$(jq --arg ev "$EV" '[.hooks[$ev][]? | select((.matcher // "") == "Bash|PowerShell") | .hooks | length] | add // 0' "$S")"
echo "$EV Bash|PowerShell hook commands before: $before"

new="$(jq --arg cmd "$CMD" --arg ev "$EV" --arg msg "Running Bash $short-hook block (dispatched)" '
  .hooks[$ev] |= (
    [ .[] | select((.matcher // "") != "Bash|PowerShell") ]
    + [ { matcher: "Bash|PowerShell",
          hooks: [ { type: "command", command: $cmd, shell: "bash", timeout: 120,
                     statusMessage: $msg } ] } ]
  )
' "$S")" || { echo "jq transform failed" >&2; exit 1; }

after="$(printf '%s' "$new" | jq --arg ev "$EV" '[.hooks[$ev][]? | select((.matcher // "") == "Bash|PowerShell") | .hooks | length] | add // 0')"
echo "$EV Bash|PowerShell hook commands after:  $after"

# Guard: every gate that was wired must still be reachable through the manifest, or it has
# been silently dropped from the harness entirely.
missing=0
while IFS=$'\t' read -r _t gate _a; do
  grep -q -- "$gate" "$MANIFEST" || { echo "NOT IN MANIFEST: $gate"; missing=1; }
done < <(jq -r --arg ev "$EV" '.hooks[$ev][]? | select((.matcher // "") == "Bash|PowerShell") | .hooks[] | .command' "$S" \
         | grep -oE 'hooks/[a-z0-9._-]+\.sh' | sed 's#hooks/##' \
         | grep -vxE 'hook-run\.sh|dispatch\.sh|build-needle-cache\.sh' \
         | sort -u | awk '{print "20\t"$0"\t-"}')
[ "$missing" = 0 ] || { echo "refusing to wire: gates above would lose their wiring" >&2; exit 1; }
echo "all previously-wired gates are present in the manifest."

if [ "$APPLY" = 1 ]; then
  # The backup must NOT land beside settings.json: ~/.claude's top level is a git repo
  # pushed to a personal remote, and everything ever dropped there got staged eventually
  # (PROJ-15342, and claude-dir-clutter-gate.sh denies it). This script wrote
  # "$S.bak-dispatch-<ts>" there on its first run and only slipped past the gate because
  # the gate sees the tool call's command line, not what a script does once running.
  bak="$S.bak-$(date +%Y%m%d%H%M%S)"
  if [ -r "$HOME/.claude/hooks/lib-claude-paths.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.claude/hooks/lib-claude-paths.sh" 2>/dev/null || true
    command -v hstate >/dev/null 2>&1 && \
      bak="$(hstate settings-backups "$(basename "$S").bak-$(date +%Y%m%d%H%M%S)")"
  fi
  cp -f "$S" "$bak"
  echo "backup: $bak"
  printf '%s\n' "$new" > "$S"
  echo "APPLIED. Takes effect on the NEXT session -- hook wiring is read at session"
  echo "start (GATES-AND-HOOKS.md)."
else
  echo "(dry run -- pass --apply to write)"
fi
