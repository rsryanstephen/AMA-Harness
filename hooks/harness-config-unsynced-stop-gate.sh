#!/usr/bin/env bash
# Stop hook. Blocks the turn from ending while harness-config.json carries an edit THIS
# session made that has not been pushed to the Octopus variable set.
#
# Why a Stop gate and not the existing PostToolUse reminder (user request 2026-09-16, per
# CLAUDE.md "Mechanical Triggers Over Self-Recognition"): octopus-config-push-reminder.sh
# says the right thing and an agent read it, agreed, and still asked the user to run the
# push -- an informational message cannot stop a turn. This can. Same shape as
# library-version-sync-reminder.sh's rule: the push is part of "done", not a follow-up.
#
# Own-edit only. The reminder records a per-session marker when it fires on this session's
# tool call (a Write/Edit of the file, or a Bash command naming it); an edit made by another
# session or by hand leaves no marker here and stays the reminder's "review with the user"
# case -- blocking every session on a change one of them cannot describe would be wrong.
#
# Synced = the live file equals the last-synced copy the reminder keeps (same
# .harness-config-synced-copy.json baseline; a successful `octopus-config-sync.sh push`
# refreshes it). Verified by content, never by the agent saying it pushed.
#
# Escape hatch: `hstate harness .harness-config-sync-deferred-<sid>` containing one line of
# reason -- for a session that genuinely cannot push (no VPN, no OCTOPUS_API_KEY). The
# reason is echoed in the reply so the deferral is visible, not silent.
#
# stop_hook_active: Claude Code sets it when the Stop is a retry after a block, so a hook
# that blocked once must let the second attempt through or the turn can never end.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"

IFS= read -r -d '' payload || true
case "$payload" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac

sid=""
[[ $payload =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && sid="${BASH_REMATCH[1]}"
[ -n "$sid" ] || exit 0

MARK="$(hstate harness ".harness-config-edited-$sid")"
[ -f "$MARK" ] || exit 0

# HCFG_FILE / HCFG_COPY are test seams (check-gates.sh), same role HR_CONFIG_FILE plays elsewhere.
CFG="${HCFG_FILE:-$HOME/.claude/harness-config.json}"
COPY="${HCFG_COPY:-$(hstate harness .harness-config-synced-copy.json)}"
[ -f "$CFG" ] || exit 0
# No baseline copy: cannot judge, and the reminder's own first-sighting branch owns that
# case. Silent.
[ -f "$COPY" ] || exit 0

if cmp -s "$CFG" "$COPY"; then
  rm -f "$MARK" 2>/dev/null
  exit 0
fi

DEFER="$(hstate harness ".harness-config-sync-deferred-$sid")"
if [ -s "$DEFER" ]; then
  why="$(head -c 300 "$DEFER" | tr -d '\r\n')"
  jq -cn --arg w "$why" '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:("harness-config.json still unpushed to Octopus; deferred this session with reason: " + $w + ". State that deferral in the reply so the user knows the change is machine-local until pushed.")}}'
  exit 0
fi

jq -cn '{decision:"block", reason:"harness-config.json was edited in THIS session and the live file still differs from the last-synced Octopus copy. The push is part of finishing the task, not a follow-up: run `bash <harness>/scripts/octopus-config-sync.sh push` now (needs OCTOPUS_API_KEY + VPN; add any new key to harness-config.example.json first if the parity check refuses). Cannot push right now (no VPN/key)? Write one line of reason to the file `hstate harness .harness-config-sync-deferred-<session id>` (source hooks/lib-claude-paths.sh) and end the turn -- the deferral is then echoed to the user instead of silently dropped."}'
