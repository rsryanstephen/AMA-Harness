#!/usr/bin/env bash
# Sourced, never run. ONE copy of "kill a dev server a Claude session started", shared by
# dev-server-teardown-reminder.sh (idle kill, any session's markers), the verify-tab-close
# hook and on-session-end.sh (this session's markers). A private copy per caller is how the
# 2026-09-15 gate bypasses happened (AGENTS.md, shared libs), so all three source this.
#
# Markers: harness-state/sessions/.usage-state/devserver-<sid>-<port>, written by
# dev-server-teardown-reminder.sh when a Claude tool call starts a server. Content = the
# listener PID once the reminder hook has seen it listening (empty before that). mtime =
# last time the server was seen in use. `devserver-probed-*` / `devserver-nudged-*` share
# the prefix and are NOT markers -- devserver_is_marker filters them.
#
#   devserver_listen_text                 -> netstat lines (all states) on stdout
#   devserver_kill_marker <marker> <text> -> kill that server if guards pass; prints
#                                            "<port> <pid>" on a kill; always drops marker
#   devserver_kill_session_ports <sid>    -> devserver_kill_marker over THIS sid's markers
#
# PID guard (2026-10-12): if the marker recorded a PID and a DIFFERENT process now listens on
# the port, the server we started is gone and the port belongs to someone else -- maybe the
# user's own server. Drop the marker, never kill. Kills the whole tree (//T): TaskStop leaves
# the `npx ng serve` node child alive (confirmed 2026-09-14) and node's esbuild child with it.
#
# Seams: AMA_DEVSERVER_LISTEN_SRC = a file of canned netstat output (no test binds a port);
# AMA_DEVSERVER_DRY_RUN=1 = report the kill, don't perform it; CLAUDE_STATE_DIR (the
# harness-wide state seam) = a throwaway marker store. The reminder hook sweeps EVERY
# session's markers, so a test without that seam would rewrite and delete live ones.
DEVSERVER_STATE="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/sessions/.usage-state"

devserver_is_marker() { # $1 = path; true for devserver-<sid>-<port> only
  local b="${1##*/}" port
  case "$b" in devserver-probed-*|devserver-nudged-*|devserver-hold-*|devserver-*.tmp) return 1 ;; devserver-*-*) ;; *) return 1 ;; esac
  port="${b##*-}"
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

devserver_listen_text() {
  if [ -n "${AMA_DEVSERVER_LISTEN_SRC:-}" ] && [ -f "${AMA_DEVSERVER_LISTEN_SRC}" ]; then
    cat "$AMA_DEVSERVER_LISTEN_SRC"
  else
    netstat -ano 2>/dev/null
  fi
}

devserver_kill_marker() { # $1 marker, $2 netstat text (all states)
  local marker="$1" text="$2" b port sid pid recorded
  b="${marker##*/}"; port="${b##*-}"; sid="${b#devserver-}"; sid="${sid%-"$port"}"
  pid="$(printf '%s\n' "$text" | awk -v p=":$port" '$1=="TCP" && toupper($4)=="LISTENING" && substr($2, length($2)-length(p)+1)==p {print $5; exit}')"
  recorded=""; [ -s "$marker" ] && read -r recorded < "$marker" 2>/dev/null
  recorded="${recorded%$'\r'}"
  case "$pid" in
    ''|*[!0-9]*|0) : ;;
    *)
      if [ -z "$recorded" ] || [ "$recorded" = "$pid" ]; then
        [ -n "${AMA_DEVSERVER_DRY_RUN:-}" ] || taskkill //PID "$pid" //T //F >/dev/null 2>&1
        printf '%s %s\n' "$port" "$pid"
      fi
      ;;
  esac
  rm -f -- "$marker" "$DEVSERVER_STATE/devserver-nudged-$sid-$port" 2>/dev/null
  return 0
}

devserver_kill_session_ports() { # $1 sid
  local sid="$1" marker text
  [ -n "$sid" ] || return 0
  set -- "$DEVSERVER_STATE"/devserver-"$sid"-*
  [ -e "$1" ] || return 0
  text="$(devserver_listen_text)"
  for marker; do
    [ -f "$marker" ] && devserver_is_marker "$marker" || continue
    devserver_kill_marker "$marker" "$text"
  done
  return 0
}
