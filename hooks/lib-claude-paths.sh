#!/usr/bin/env bash
# PROJ-15342: the one place a ~/.claude harness-state or scratch path is built.
#
# Before this, every hook/skill script invented its own $HOME/.claude/.<feature>-<state>
# literal inline -- ~60 distinct paths across ~55 files, no shared accessor, and the
# top level of ~/.claude (a git repo pushed to a personal GitHub remote) accumulated
# ~90 files that didn't belong there. That single flat directory is also where
# .support-notices-seen / .aws-notices-seen / .embs-notices-seen / .pending-followups
# live -- the dedupe records that stop duplicate Slack/email going to real colleagues.
#
# Every write in this harness that touches state does so with `2>/dev/null || true`
# (fail soft, matching every other lib here). That means a parent directory that
# doesn't exist yet doesn't error -- it just silently stops recording, forever, with
# nothing in any log. So `hstate` below does two things a plain path-join can't:
#   1. guarantees the parent directory exists before handing back the path
#   2. absorbs a leftover file still sitting at the OLD top-level location on first
#      touch, so a sweep that ran mid-migration (or a straggler process) costs
#      nothing instead of losing its seen-list and re-firing every notice from scratch
#
# Override idiom matches hooks/lib-repo-claims.sh:23 (CLAIMS_FILE) -- test seam only.
set -u

CLAUDE_STATE_DIR="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}"
CLAUDE_SCRATCH_DIR="${CLAUDE_SCRATCH_DIR:-$HOME/.claude/scratch}"

# hstate <category> <name> -> absolute path under harness-state/<category>/<name>.
# <category> is one of: notices, standup, sessions, tickets, harness, settings-backups,
# logs -- see AGENTS.md's "Where harness state lives" section for what goes where.
# <name> may itself contain a subpath (e.g. "fleet-health/run-history.log") -- the full
# parent directory is created, not just harness-state/<category>/.
hstate() {
  local category="${1:?usage: hstate <category> <name>}" name="${2:?usage: hstate <category> <name>}"
  local new old parent
  new="$CLAUDE_STATE_DIR/$category/$name"
  old="$HOME/.claude/$name"
  parent="$(dirname "$new")"
  [ -d "$parent" ] || mkdir -p "$parent" 2>/dev/null
  # Absorb only against the REAL store: with CLAUDE_STATE_DIR overridden (test seam),
  # the mv would relocate genuine ~/.claude leftovers into a throwaway dir -- data loss.
  if [ "$CLAUDE_STATE_DIR" = "$HOME/.claude/harness-state" ]; then
    [ -e "$new" ] || [ ! -e "$old" ] || mv -f "$old" "$new" 2>/dev/null
  fi
  printf '%s' "$new"
}

# hscratch <purpose> <name> -> absolute path under scratch/<purpose>/<name>. No
# absorb-on-touch -- scratch is disposable by definition, nothing depends on its
# content surviving, so there's nothing worth migrating automatically.
hscratch() {
  local purpose="${1:?usage: hscratch <purpose> <name>}" name="${2:?usage: hscratch <purpose> <name>}"
  local dir="$CLAUDE_SCRATCH_DIR/$purpose"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
  printf '%s' "$dir/$name"
}

# Direct-execution dispatch, same shape as lib-harness-repos.sh, for PowerShell/other
# callers that need a path without sourcing bash.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fn="${1:-}"; shift || true
  case "$fn" in
    hstate) hstate "$@" ;;
    hscratch) hscratch "$@" ;;
    *) echo "usage: lib-claude-paths.sh {hstate|hscratch} <category|purpose> <name>" >&2; exit 1 ;;
  esac
fi

# Jira write payload path. Was ONE fixed file for every session -- two concurrent Jira
# writes clobbered each other (400 "Summary is required", 2026-08-20; the silent version is
# a comment landing on the other session's ticket). Callers now pass JIRA_PAYLOAD_FILE=<path>
# (scripts read the env var; hooks read it back out of the command text). Default = the old
# shared path, so an unprefixed call keeps working.
jira_payload_file() {
  local cmd="${1:-}" p=""
  [ -n "$cmd" ] && p="$(printf '%s' "$cmd" | grep -oP 'JIRA_PAYLOAD_FILE=\x27?"?\K[^"\x27[:space:]]+' | head -1)"
  p="${p/#\~/$HOME}"; p="${p/#\$HOME/$HOME}"
  [ -n "$p" ] && printf '%s' "$p" || hstate tickets .jira-write-payload.json
}
