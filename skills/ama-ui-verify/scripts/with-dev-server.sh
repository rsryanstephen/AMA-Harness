#!/usr/bin/env bash
# One-shot UI verification with the dev server's lifecycle OWNED here: start it, wait until
# it answers, run the verify command, kill the whole server tree on exit -- pass, fail,
# timeout or Ctrl-C. A run through this script cannot leave an `ng serve` behind, which is
# the leak dev-server-teardown-reminder.sh / on-session-end.sh / the tab-close hook exist
# to clean up after (<harnessEpicKey>: a forgotten ng serve at 3.7 GB while the box paged).
#
# Usage:
#   with-dev-server.sh --port <n> --cwd <dir> --serve '<serve command>' [--timeout <secs>] \
#       -- <verify command> [args...]
# e.g.
#   bash ~/.claude/skills/ama-ui-verify/scripts/with-dev-server.sh --port 4210 \
#     --cwd "$HOME/Repos/AMA_APP/exporterplus" \
#     --serve 'npx ng serve --proxy-config proxy.config.qa-ecs.json --configuration localqa --port 4210 --live-reload=false' \
#     -- bash ~/.claude/skills/ama-ui-verify/scripts/run-ui-verify.sh qa 3500 'http://localhost:4210/x' out.png
#
# When: ONE verification (hotfix self-check, a screenshot, an export-vs-grid diff). An
# iterative fix -> re-verify loop still wants a background `ng serve` (its watch rebuilds
# on edit; here every run pays the 1-2 min startup) -- that is SKILL.md's
# run_in_background + same-turn teardown path, backstopped by the hooks.
#
# Readiness probes [::1]: the server binds v6 only, 127.0.0.1 answers 000 forever
# (SKILL.md "Dev server traps"). Port already held -> refuses up front, naming the PID:
# ng serve would PROMPT "use a different port?" and hang, and the holder is someone else's.
# Exit code is the verify command's; 2 = could not start/reach the server (log path printed).
set -u

PORT=""; CWD=""; SERVE=""; TIMEOUT=300
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:?}"; shift 2 ;;
    --cwd) CWD="${2:?}"; shift 2 ;;
    --serve) SERVE="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --) shift; break ;;
    *) echo "with-dev-server.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$PORT" ] && [ -n "$CWD" ] && [ -n "$SERVE" ] && [ $# -gt 0 ] || {
  sed -n '8,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ -d "$CWD" ] || { echo "with-dev-server.sh: --cwd $CWD is not a directory" >&2; exit 2; }

LOGDIR="$HOME/.claude/scratch/devserver"; mkdir -p "$LOGDIR" 2>/dev/null
LOG="$LOGDIR/with-dev-server-$PORT.log"

listener_pid() { netstat -ano 2>/dev/null | grep -i LISTENING | grep -E ":$PORT[[:space:]]" | awk '{print $NF}' | head -1; }

held="$(listener_pid)"
if [ -n "$held" ]; then
  echo "with-dev-server.sh: port $PORT already LISTENING (PID $held) -- not ours to reuse or kill. Pick another port or read that PID's command line first (SKILL.md, dev server traps)." >&2
  exit 2
fi

SERVE_PID=""
cleanup() {
  local pid
  pid="$(listener_pid)"
  case "$pid" in ''|*[!0-9]*|0) : ;; *) taskkill //PID "$pid" //T //F >/dev/null 2>&1 ;; esac
  [ -n "$SERVE_PID" ] && taskkill //PID "$SERVE_PID" //T //F >/dev/null 2>&1
  return 0
}
trap cleanup EXIT INT TERM

: > "$LOG"
( cd "$CWD" && exec bash -c "$SERVE" ) >"$LOG" 2>&1 &
SERVE_PID=$!

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://[::1]:$PORT/" 2>/dev/null || true)"
  case "$code" in 2*|3*) break ;; esac
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "with-dev-server.sh: serve command exited before answering on port $PORT -- log: $LOG" >&2
    tail -n 15 "$LOG" >&2
    exit 2
  fi
  if grep -q 'already in use' "$LOG" 2>/dev/null; then
    echo "with-dev-server.sh: ng serve reports port $PORT in use and is waiting on a prompt -- log: $LOG" >&2
    exit 2
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "with-dev-server.sh: no answer on http://[::1]:$PORT/ after ${TIMEOUT}s -- log: $LOG" >&2
    tail -n 15 "$LOG" >&2
    exit 2
  fi
  sleep 3
done

"$@"
exit $?
