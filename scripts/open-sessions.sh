#!/usr/bin/env bash
# Reopen the last <n> Claude Code sessions, each in its own Git Bash (mintty) window --
# e.g. after a reboot. Reads sessions.md (most-recently-active first; its rows already drop
# dead/superseded sessions) and runs each row's backticked `cd <dir> && claude -r <handle>`.
# The window keeps a login shell open after claude exits, same as typing the command by hand.
# A session already open is skipped (two clients on one transcript) but still counts toward
# <n>, so re-running opens nothing new instead of walking further down the list.
#
# usage: open-sessions.sh <n> [--dry-run]     (`ros [n]` in ~/.bashrc, added by install.ps1; n defaults to 8)
set -u

n="${1:-}"
case "$n" in ''|*[!0-9]*|0) echo "usage: open-sessions.sh <n> [--dry-run]" >&2; exit 2 ;; esac
dry=0; [ "${2:-}" = "--dry-run" ] && dry=1

md="$HOME/.claude/sessions.md"
[ -r "$md" ] || { echo "open-sessions: $md not found" >&2; exit 1; }

# Open = Claude Code's own ~/.claude/sessions/<winpid>.json AND that pid still a live
# claude.exe (a crash leaves the file behind). Transcript mtime can't tell -- an idle open
# session looks dead.
live_pids=" $(tasklist //FI "IMAGENAME eq claude.exe" //FO CSV //NH 2>/dev/null | cut -d, -f2 | tr -d '"\r' | tr '\n' ' ') "
open=" "
for f in "$HOME"/.claude/sessions/*.json; do
  [ -e "$f" ] || continue
  read -r pid sid < <(jq -r '"\(.pid) \(.sessionId)"' "$f" 2>/dev/null) || continue
  case "$live_pids" in *" $pid "*) open+="${sid:0:8} " ;; esac
done

count=0
while IFS= read -r line; do
  [ "$count" -ge "$n" ] && break
  [[ $line =~ ^-\ \*\*(.*)\*\*\ — ]] || continue
  name="${BASH_REMATCH[1]}"
  [[ $line =~ \`(cd\ [^\`]*claude\ -r\ [^\`]*)\` ]] || continue
  cmd="${BASH_REMATCH[1]}"
  count=$((count + 1))
  if [[ $line =~ —\ ([0-9a-f]{8})\ — ]] && [[ $open == *" ${BASH_REMATCH[1]} "* ]]; then
    echo "$count. $name -- already open, skipped"
    continue
  fi
  echo "$count. $name"
  echo "   $cmd"
  [ "$dry" -eq 1 ] && continue
  mintty -t "$name" -e /usr/bin/bash -lc "$cmd; exec bash -l" >/dev/null 2>&1 &
  disown
done < "$md"

[ "$count" -eq 0 ] && { echo "open-sessions: no session rows in $md" >&2; exit 1; }
[ "$count" -lt "$n" ] && echo "(only $count session(s) listed)"
exit 0
